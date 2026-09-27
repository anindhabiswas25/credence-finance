//! WebSocket streaming for the licensed vendors (S2): trades, quotes and LULD / trading-status events
//! pushed by the vendor instead of polled, with REST as the fallback.
//!
//! * [`StreamCache`] keeps, per symbol, the recent trades, the latest NBBO and the stream's halt state,
//!   and broadcasts the symbol on every event so a node re-observes it at once (sub-second reaction to
//!   the 0.10% move rule instead of the 2 s REST poll).
//! * [`run_stream`] owns one connection: connect → auth → subscribe → read, with ping keep-alive and
//!   exponential reconnect. Vendor wire formats live in [`StreamProtocol`] impls
//!   ([`super::alpaca_ws`], [`super::polygon_ws`]).
//! * [`Streaming`] wraps the REST vendor: `live` reads the cache while the stream is healthy and has
//!   data for the symbol, else REST; `status` is REST (cached briefly) with the stream's halt state
//!   merged in, failing closed (halted if either source says so); official prints come from auction
//!   trades seen on the stream when present, else REST.

use super::{
    polygon::find_official, DynVendor, HaltInfo, LiveInput, MarketDataVendor, OfficialPrint, Quote,
    StatusInput, Trade, VendorResult,
};
use crate::{asset::Asset, metrics::Metrics};
use async_trait::async_trait;
use credence_common::calendar::Session;
use futures::{SinkExt, StreamExt};
use std::{
    collections::{HashMap, VecDeque},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tokio::sync::broadcast;
use tokio_tungstenite::tungstenite::Message;

/// One normalised stream event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StreamMsg {
    Trade(String, Trade),
    Quote(String, Quote),
    /// Trading status for a symbol: halted (halt, LULD pause) or trading again.
    Status {
        symbol: String,
        halted: bool,
        reason: Option<String>,
    },
    /// LULD price band (WAD), informational.
    Luld {
        symbol: String,
        up_wad: u128,
        down_wad: u128,
    },
    Control(Control),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Control {
    Connected,
    Authenticated,
    Subscribed,
    /// Fatal for this connection (bad key, plan not entitled, connection limit): back off long.
    Rejected(String),
    /// Anything else the vendor reports.
    Info(String),
}

/// A vendor's WebSocket wire format.
pub trait StreamProtocol: Send + Sync + 'static {
    fn vendor(&self) -> &'static str;
    fn url(&self) -> String;
    /// Auth frame. `None` when the vendor authenticates in the URL or headers.
    fn auth(&self) -> Option<String>;
    fn subscribe(&self, symbols: &[String]) -> String;
    /// Parse one text frame (vendors batch several events per frame).
    fn parse(&self, text: &str) -> Vec<StreamMsg>;
    /// True once the vendor has confirmed the subscription (some vendors never send an explicit ack).
    fn implicit_subscribe_ack(&self) -> bool {
        false
    }
}

/// Normalise a vendor timestamp of unknown unit (s, ms, µs or ns since the epoch) to ns.
pub fn to_ns(t: u64) -> u64 {
    match t {
        t if t >= 100_000_000_000_000_000 => t,     // ns
        t if t >= 100_000_000_000_000 => t * 1_000, // µs
        t if t >= 100_000_000_000 => t * 1_000_000, // ms
        t => t * 1_000_000_000,                     // s
    }
}

#[derive(Debug, Default, Clone)]
struct SymbolState {
    trades: VecDeque<Trade>, // oldest first
    quote: Option<Quote>,
    halt: Option<HaltInfo>,
    luld: Option<(u128, u128)>,
}

/// Shared state filled by the stream task and read by [`Streaming`].
pub struct StreamCache {
    vendor: &'static str,
    symbols: Mutex<HashMap<String, SymbolState>>,
    authenticated: AtomicBool,
    subscribed: AtomicBool,
    last_frame: Mutex<Option<Instant>>,
    updates: broadcast::Sender<String>,
    /// Trades older than this (relative to the newest one) are dropped.
    keep_ns: u64,
    max_trades: usize,
    /// No frame (data or pong) for this long → unhealthy (REST fallback).
    idle: Duration,
}

impl StreamCache {
    pub fn new(vendor: &'static str) -> Arc<Self> {
        Arc::new(Self {
            vendor,
            symbols: Mutex::new(HashMap::new()),
            authenticated: AtomicBool::new(false),
            subscribed: AtomicBool::new(false),
            last_frame: Mutex::new(None),
            updates: broadcast::channel(4096).0,
            keep_ns: 600 * 1_000_000_000,
            max_trades: 5_000,
            idle: Duration::from_secs(45),
        })
    }

    pub fn vendor(&self) -> &'static str {
        self.vendor
    }

    /// Symbols with a new event, as they arrive.
    pub fn subscribe(&self) -> broadcast::Receiver<String> {
        self.updates.subscribe()
    }

    /// Connected, authenticated, subscribed, and a frame seen recently.
    pub fn healthy(&self) -> bool {
        self.authenticated.load(Ordering::Relaxed)
            && self.subscribed.load(Ordering::Relaxed)
            && self
                .last_frame
                .lock()
                .expect("lock")
                .is_some_and(|t| t.elapsed() < self.idle)
    }

    fn touch(&self) {
        *self.last_frame.lock().expect("lock") = Some(Instant::now());
    }

    fn disconnected(&self) {
        self.authenticated.store(false, Ordering::Relaxed);
        self.subscribed.store(false, Ordering::Relaxed);
    }

    /// Apply one event. Returns the symbol it concerns, if any.
    pub fn apply(&self, msg: StreamMsg) -> Option<String> {
        let mut g = self.symbols.lock().expect("lock");
        let sym = match msg {
            StreamMsg::Trade(sym, t) => {
                let s = g.entry(sym.clone()).or_default();
                // keep time order; vendors deliver in order per symbol, but be safe for late prints
                let pos = s.trades.partition_point(|x| x.ts_ns <= t.ts_ns);
                s.trades.insert(pos, t);
                let newest = s.trades.back().map(|x| x.ts_ns).unwrap_or(0);
                while s.trades.len() > self.max_trades
                    || s.trades
                        .front()
                        .is_some_and(|x| newest.saturating_sub(x.ts_ns) > self.keep_ns)
                {
                    s.trades.pop_front();
                }
                sym
            }
            StreamMsg::Quote(sym, q) => {
                let s = g.entry(sym.clone()).or_default();
                if s.quote.as_ref().is_none_or(|old| old.ts_ns <= q.ts_ns) {
                    s.quote = Some(q);
                }
                sym
            }
            StreamMsg::Status {
                symbol,
                halted,
                reason,
            } => {
                g.entry(symbol.clone()).or_default().halt = Some(HaltInfo { halted, reason });
                symbol
            }
            StreamMsg::Luld {
                symbol,
                up_wad,
                down_wad,
            } => {
                g.entry(symbol.clone()).or_default().luld = Some((up_wad, down_wad));
                symbol
            }
            StreamMsg::Control(c) => {
                drop(g);
                match c {
                    Control::Authenticated => self.authenticated.store(true, Ordering::Relaxed),
                    Control::Subscribed => self.subscribed.store(true, Ordering::Relaxed),
                    Control::Rejected(_) => self.disconnected(),
                    Control::Connected | Control::Info(_) => {}
                }
                return None;
            }
        };
        drop(g);
        let _ = self.updates.send(sym.clone());
        Some(sym)
    }

    /// Trades at or after `since_ns` (newest first) and the NBBO, if the stream has any data for it.
    pub fn live(&self, symbol: &str, since_ns: u64) -> Option<LiveInput> {
        let g = self.symbols.lock().expect("lock");
        let s = g.get(symbol)?;
        if s.trades.is_empty() && s.quote.is_none() {
            return None;
        }
        Some(LiveInput {
            trades: s
                .trades
                .iter()
                .rev()
                .take_while(|t| t.ts_ns >= since_ns)
                .cloned()
                .collect(),
            nbbo: s.quote.clone(),
        })
    }

    /// The stream's halt state for `symbol`, if it has reported one.
    pub fn halt(&self, symbol: &str) -> Option<HaltInfo> {
        self.symbols
            .lock()
            .expect("lock")
            .get(symbol)
            .and_then(|s| s.halt.clone())
    }

    pub fn luld(&self, symbol: &str) -> Option<(u128, u128)> {
        self.symbols
            .lock()
            .expect("lock")
            .get(symbol)
            .and_then(|s| s.luld)
    }

    /// Official auction print from the listing exchange seen on the stream in `[from, to)` (unix s).
    pub fn official(&self, asset: &Asset, from: u64, to: u64, open: bool) -> Option<OfficialPrint> {
        let g = self.symbols.lock().expect("lock");
        let s = g.get(&asset.symbol)?;
        let window: Vec<Trade> = s
            .trades
            .iter()
            .filter(|t| t.ts_ns >= from * 1_000_000_000 && t.ts_ns < to * 1_000_000_000)
            .cloned()
            .collect();
        find_official(&window, &asset.listing, open)
    }
}

/// Reconnect policy.
#[derive(Debug, Clone, Copy)]
pub struct StreamOptions {
    pub ping_every: Duration,
    pub backoff_min: Duration,
    pub backoff_max: Duration,
    /// Back-off after the vendor rejected us (bad key, plan, connection limit).
    pub backoff_rejected: Duration,
}

impl Default for StreamOptions {
    fn default() -> Self {
        Self {
            ping_every: Duration::from_secs(15),
            backoff_min: Duration::from_millis(500),
            backoff_max: Duration::from_secs(30),
            backoff_rejected: Duration::from_secs(300),
        }
    }
}

/// Keep one stream connection alive forever, feeding `cache`.
pub async fn run_stream(
    proto: Arc<dyn StreamProtocol>,
    symbols: Vec<String>,
    cache: Arc<StreamCache>,
    opts: StreamOptions,
    metrics: Option<Metrics>,
) {
    let vendor = proto.vendor();
    let mut backoff = opts.backoff_min;
    loop {
        let started = Instant::now();
        let r = connect_once(proto.as_ref(), &symbols, &cache, opts, metrics.as_ref()).await;
        cache.disconnected();
        if let Some(m) = &metrics {
            m.stream_connected.with_label_values(&[vendor]).set(0);
            m.stream_reconnects.with_label_values(&[vendor]).inc();
        }
        let wait = match &r {
            Ok(never) => match *never {},
            Err(StreamEnd::Rejected(why)) => {
                tracing::error!(vendor, %why, "stream rejected by the vendor; REST fallback in use");
                opts.backoff_rejected
            }
            Err(StreamEnd::Io(why)) => {
                tracing::warn!(vendor, %why, "stream disconnected; REST fallback until it is back");
                // a connection that lived a while resets the back-off
                if started.elapsed() > Duration::from_secs(60) {
                    backoff = opts.backoff_min;
                }
                let w = backoff;
                backoff = (backoff * 2).min(opts.backoff_max);
                w
            }
        };
        tokio::time::sleep(wait).await;
    }
}

enum StreamEnd {
    Rejected(String),
    Io(String),
}

async fn connect_once(
    proto: &dyn StreamProtocol,
    symbols: &[String],
    cache: &StreamCache,
    opts: StreamOptions,
    metrics: Option<&Metrics>,
) -> Result<std::convert::Infallible, StreamEnd> {
    let vendor = proto.vendor();
    let (ws, _) = tokio::time::timeout(
        Duration::from_secs(10),
        tokio_tungstenite::connect_async(proto.url()),
    )
    .await
    .map_err(|_| StreamEnd::Io("connect timed out".into()))?
    .map_err(|e| StreamEnd::Io(format!("connect: {e}")))?;
    let (mut tx, mut rx) = ws.split();
    if let Some(auth) = proto.auth() {
        tx.send(Message::text(auth))
            .await
            .map_err(|e| StreamEnd::Io(e.to_string()))?;
    } else {
        cache.apply(StreamMsg::Control(Control::Authenticated));
    }
    let mut subscribed_sent = false;
    let mut ping = tokio::time::interval(opts.ping_every);
    ping.tick().await;
    loop {
        tokio::select! {
            _ = ping.tick() => {
                tx.send(Message::Ping(Vec::new().into())).await.map_err(|e| StreamEnd::Io(e.to_string()))?;
            }
            frame = rx.next() => {
                let frame = match frame {
                    None => return Err(StreamEnd::Io("closed by the vendor".into())),
                    Some(Err(e)) => return Err(StreamEnd::Io(e.to_string())),
                    Some(Ok(f)) => f,
                };
                cache.touch();
                let text = match frame {
                    Message::Text(t) => t.to_string(),
                    Message::Binary(b) => String::from_utf8_lossy(&b).into_owned(),
                    Message::Ping(p) => {
                        tx.send(Message::Pong(p)).await.map_err(|e| StreamEnd::Io(e.to_string()))?;
                        continue;
                    }
                    Message::Close(c) => return Err(StreamEnd::Io(format!("close frame {c:?}"))),
                    _ => continue,
                };
                for msg in proto.parse(&text) {
                    if let Some(m) = metrics {
                        let kind = match &msg {
                            StreamMsg::Trade(..) => "trade",
                            StreamMsg::Quote(..) => "quote",
                            StreamMsg::Status { .. } => "status",
                            StreamMsg::Luld { .. } => "luld",
                            StreamMsg::Control(_) => "control",
                        };
                        m.stream_messages.with_label_values(&[vendor, kind]).inc();
                    }
                    match &msg {
                        StreamMsg::Control(Control::Rejected(why)) => {
                            return Err(StreamEnd::Rejected(why.clone()));
                        }
                        StreamMsg::Control(Control::Authenticated) if !subscribed_sent => {
                            tx.send(Message::text(proto.subscribe(symbols)))
                                .await
                                .map_err(|e| StreamEnd::Io(e.to_string()))?;
                            subscribed_sent = true;
                            tracing::info!(vendor, n = symbols.len(), "stream authenticated; subscribed");
                            if proto.implicit_subscribe_ack() {
                                cache.apply(StreamMsg::Control(Control::Subscribed));
                            }
                        }
                        StreamMsg::Control(Control::Subscribed) => {
                            if let Some(m) = metrics {
                                m.stream_connected.with_label_values(&[vendor]).set(1);
                            }
                        }
                        StreamMsg::Control(Control::Info(i)) => tracing::debug!(vendor, info = %i, "stream"),
                        _ => {}
                    }
                    cache.apply(msg);
                }
            }
        }
    }
}

/// A REST vendor with a stream in front of it.
pub struct Streaming {
    inner: DynVendor,
    cache: Arc<StreamCache>,
    status_ttl: Duration,
    status_cache: tokio::sync::Mutex<HashMap<String, (Instant, StatusInput)>>,
}

impl Streaming {
    pub fn new(inner: DynVendor, cache: Arc<StreamCache>, status_ttl: Duration) -> Self {
        Self {
            inner,
            cache,
            status_ttl,
            status_cache: Default::default(),
        }
    }

    pub fn cache(&self) -> &Arc<StreamCache> {
        &self.cache
    }
}

/// Fail closed: halted if the stream or the REST/halt-feed source says so.
pub fn merge_halt(rest: Option<HaltInfo>, stream: Option<HaltInfo>) -> Option<HaltInfo> {
    match (rest, stream) {
        (None, s) => s,
        (r, None) => r,
        (Some(r), Some(s)) => Some(if r.halted { r } else { s }),
    }
}

#[async_trait]
impl MarketDataVendor for Streaming {
    fn name(&self) -> &'static str {
        self.inner.name()
    }

    async fn live(&self, asset: &Asset, since_ns: u64) -> VendorResult<LiveInput> {
        if self.cache.healthy() {
            if let Some(l) = self.cache.live(&asset.symbol, since_ns) {
                return Ok(l);
            }
        }
        self.inner.live(asset, since_ns).await
    }

    async fn official_open(
        &self,
        asset: &Asset,
        session: &Session,
    ) -> VendorResult<Option<OfficialPrint>> {
        if let Some(p) = self
            .cache
            .official(asset, session.open, session.open + 15 * 60, true)
        {
            return Ok(Some(p));
        }
        self.inner.official_open(asset, session).await
    }

    async fn official_close(
        &self,
        asset: &Asset,
        session: &Session,
    ) -> VendorResult<Option<OfficialPrint>> {
        if let Some(p) = self
            .cache
            .official(asset, session.close, session.close + 30 * 60, false)
        {
            return Ok(Some(p));
        }
        self.inner.official_close(asset, session).await
    }

    async fn status(&self, asset: &Asset) -> VendorResult<StatusInput> {
        let cached = {
            let g = self.status_cache.lock().await;
            g.get(&asset.symbol)
                .filter(|(at, _)| at.elapsed() < self.status_ttl)
                .map(|(_, s)| s.clone())
        };
        let mut s = match cached {
            Some(s) => s,
            None => {
                let s = self.inner.status(asset).await?;
                self.status_cache
                    .lock()
                    .await
                    .insert(asset.symbol.clone(), (Instant::now(), s.clone()));
                s
            }
        };
        s.halt = merge_halt(s.halt, self.cache.halt(&asset.symbol));
        Ok(s)
    }

    fn updates(&self) -> Option<broadcast::Receiver<String>> {
        Some(self.cache.subscribe())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{asset::Plan, price::WAD};

    fn trade(p: u128, ts_s: u64) -> Trade {
        Trade {
            price_wad: p,
            size: 100,
            ts_ns: ts_s * 1_000_000_000,
            exchange: "XNAS".into(),
            conditions: vec!["@".into()],
            plan: Plan::Utp,
        }
    }

    #[test]
    fn timestamps_normalise() {
        assert_eq!(to_ns(1_536_036_818), 1_536_036_818_000_000_000);
        assert_eq!(to_ns(1_536_036_818_784), 1_536_036_818_784_000_000);
        assert_eq!(to_ns(1_601_316_752_683_746), 1_601_316_752_683_746_000);
        assert_eq!(to_ns(1_764_086_430_905_642_800), 1_764_086_430_905_642_800);
    }

    #[test]
    fn cache_orders_trims_and_broadcasts() {
        let c = StreamCache::new("t");
        let mut rx = c.subscribe();
        assert!(c.live("NVDA", 0).is_none());
        c.apply(StreamMsg::Trade("NVDA".into(), trade(100 * WAD, 1_000)));
        c.apply(StreamMsg::Trade("NVDA".into(), trade(102 * WAD, 1_002)));
        c.apply(StreamMsg::Trade("NVDA".into(), trade(101 * WAD, 1_001))); // late
        assert_eq!(rx.try_recv().unwrap(), "NVDA");
        let l = c.live("NVDA", 1_001 * 1_000_000_000).unwrap();
        assert_eq!(
            l.trades.iter().map(|t| t.price_wad).collect::<Vec<_>>(),
            vec![102 * WAD, 101 * WAD],
            "newest first, since filter"
        );
        // 10+ minutes later the old trades are dropped
        c.apply(StreamMsg::Trade("NVDA".into(), trade(103 * WAD, 1_700)));
        assert_eq!(c.live("NVDA", 0).unwrap().trades.len(), 1);
    }

    #[test]
    fn health_needs_auth_subscription_and_recent_frames() {
        let c = StreamCache::new("t");
        assert!(!c.healthy());
        c.apply(StreamMsg::Control(Control::Authenticated));
        c.touch();
        assert!(!c.healthy(), "not subscribed yet");
        c.apply(StreamMsg::Control(Control::Subscribed));
        assert!(c.healthy());
        c.apply(StreamMsg::Control(Control::Rejected("406".into())));
        assert!(!c.healthy());
    }

    #[test]
    fn halt_merge_fails_closed() {
        let h = |x| {
            Some(HaltInfo {
                halted: x,
                reason: None,
            })
        };
        assert_eq!(merge_halt(h(false), h(true)), h(true));
        assert_eq!(merge_halt(h(true), h(false)), h(true));
        assert_eq!(merge_halt(None, h(true)), h(true));
        assert_eq!(merge_halt(h(false), None), h(false));
        assert_eq!(merge_halt(None, None), None);
    }
}
