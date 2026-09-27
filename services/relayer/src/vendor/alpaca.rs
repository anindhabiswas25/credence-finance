//! Alpaca Market Data API v2. Feed B's vendor (ADR-0002). `ALPACA_FEED=sip` needs Algo Trader Plus
//! (full consolidated tape); the free Basic plan serves `iex` in real time and SIP history older than
//! 15 minutes.
//!
//! Endpoints (`https://data.alpaca.markets`, headers `APCA-API-KEY-ID` / `APCA-API-SECRET-KEY`):
//! * `GET /v2/stocks/trades?symbols=…&start=…&sort=desc`: recent trades (LIVE), auction prints
//! * `GET /v2/stocks/quotes/latest?symbols=…`: NBBO
//! * `GET /v2/stocks/bars?timeframe=1Day&adjustment=raw`: official open/close fallback
//! * Trading API `GET /v2/clock`: regular session open or not
//!
//! Halts come from the Nasdaq Trader halt feed ([`super::halts`]).

use super::{
    halts::HaltFeed, http_client, http_error, LiveInput, MarketDataVendor, OfficialPrint,
    PrintSource, Quote, RateLimit, StatusInput, Trade, VendorError, VendorMarket, VendorResult,
};
use crate::{
    asset::{Asset, Plan},
    price::wad_from_f64,
};
use async_trait::async_trait;
use credence_common::calendar::Session;
use serde::Deserialize;
use std::{collections::HashMap, sync::Arc};

const V: &str = "alpaca";

#[derive(Debug, Clone)]
pub struct AlpacaConfig {
    pub key_id: String,
    pub secret: String,
    /// `sip` (Algo Trader Plus) or `iex` (free).
    pub feed: String,
    pub data_url: String,
    pub trading_url: String,
    pub max_rpm: u32,
}

pub struct Alpaca {
    cfg: AlpacaConfig,
    http: reqwest::Client,
    limit: RateLimit,
    halts: Arc<HaltFeed>,
}

/// Alpaca exchange code → MIC.
pub fn exchange_mic(x: &str) -> &'static str {
    match x {
        "A" => "XASE",
        "B" => "XBOS",
        "C" => "XCIS",
        "D" => "FINR",
        "H" => "EPRL",
        "I" => "XISE",
        "J" => "EDGA",
        "K" => "EDGX",
        "L" => "LTSE",
        "M" => "XCHI",
        "N" => "XNYS",
        "P" => "ARCX",
        "Q" | "S" | "T" => "XNAS",
        "U" => "MEMX",
        "V" => "IEXG",
        "W" => "CBSX",
        "X" => "XPHL",
        "Y" => "BATY",
        "Z" => "BATS",
        _ => "OTHER",
    }
}

#[derive(Deserialize)]
pub(crate) struct RawTrade {
    t: String,
    x: String,
    p: f64,
    #[serde(default)]
    s: f64,
    #[serde(default)]
    c: Vec<String>,
    z: Option<String>,
}

#[derive(Deserialize)]
struct TradesResp {
    #[serde(default)]
    trades: HashMap<String, Vec<RawTrade>>,
}

#[derive(Deserialize)]
struct LatestTradeResp {
    #[serde(default)]
    trades: HashMap<String, RawTrade>,
}

#[derive(Deserialize)]
struct RawQuote {
    t: String,
    ap: f64,
    bp: f64,
}

#[derive(Deserialize)]
struct QuotesResp {
    #[serde(default)]
    quotes: HashMap<String, RawQuote>,
}

#[derive(Deserialize)]
struct RawBar {
    o: f64,
    c: f64,
    t: String,
}

#[derive(Deserialize)]
struct BarsResp {
    #[serde(default)]
    bars: HashMap<String, Vec<RawBar>>,
}

#[derive(Deserialize)]
struct ClockResp {
    is_open: bool,
}

fn parse_err(endpoint: &str, e: impl std::fmt::Display) -> VendorError {
    VendorError::Parse {
        vendor: V,
        endpoint: endpoint.into(),
        message: e.to_string(),
    }
}

pub(crate) fn ts_ns(s: &str) -> Option<u64> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()?
        .timestamp_nanos_opt()
        .map(|n| n as u64)
}

fn to_trade(t: &RawTrade, listing_plan: Plan) -> Option<Trade> {
    Some(Trade {
        price_wad: wad_from_f64(t.p).ok()?,
        size: t.s.max(0.0) as u64,
        ts_ns: ts_ns(&t.t)?,
        exchange: exchange_mic(&t.x).into(),
        conditions: t.c.clone(),
        plan: t
            .z
            .as_deref()
            .and_then(Plan::from_tape)
            .unwrap_or(listing_plan),
    })
}

pub(crate) fn parse_trades(
    body: &str,
    symbol: &str,
    listing_plan: Plan,
) -> Result<Vec<Trade>, VendorError> {
    let r: TradesResp =
        serde_json::from_str(body).map_err(|e| parse_err("/v2/stocks/trades", e))?;
    let mut v: Vec<Trade> = r
        .trades
        .get(symbol)
        .map(|ts| {
            ts.iter()
                .filter_map(|t| to_trade(t, listing_plan))
                .collect()
        })
        .unwrap_or_default();
    v.sort_by_key(|t| std::cmp::Reverse(t.ts_ns));
    Ok(v)
}

pub(crate) fn parse_latest_trade(
    body: &str,
    symbol: &str,
    listing_plan: Plan,
) -> Result<Option<Trade>, VendorError> {
    let r: LatestTradeResp =
        serde_json::from_str(body).map_err(|e| parse_err("/v2/stocks/trades/latest", e))?;
    Ok(r.trades.get(symbol).and_then(|t| to_trade(t, listing_plan)))
}

pub(crate) fn parse_quote(body: &str, symbol: &str) -> Result<Option<Quote>, VendorError> {
    let r: QuotesResp =
        serde_json::from_str(body).map_err(|e| parse_err("/v2/stocks/quotes/latest", e))?;
    let Some(q) = r.quotes.get(symbol) else {
        return Ok(None);
    };
    Ok(Some(Quote {
        bid_wad: wad_from_f64(q.bp).map_err(|e| parse_err("quote", e))?,
        ask_wad: wad_from_f64(q.ap).map_err(|e| parse_err("quote", e))?,
        ts_ns: ts_ns(&q.t).ok_or_else(|| parse_err("quote", "bad timestamp"))?,
    }))
}

/// The daily bar for the session's ET date (Alpaca stamps daily bars at 00:00 ET of that day).
pub(crate) fn parse_daily_bar(
    body: &str,
    symbol: &str,
    session: &Session,
    open: bool,
) -> Result<Option<OfficialPrint>, VendorError> {
    let r: BarsResp = serde_json::from_str(body).map_err(|e| parse_err("/v2/stocks/bars", e))?;
    let day = et_date(session.open);
    let Some(bar) = r.bars.get(symbol).and_then(|bars| {
        bars.iter()
            .find(|b| ts_ns(&b.t).map(|n| et_date(n / 1_000_000_000)) == Some(day.clone()))
    }) else {
        return Ok(None);
    };
    let (p, at) = if open {
        (bar.o, session.open)
    } else {
        (bar.c, session.close)
    };
    Ok(Some(OfficialPrint {
        price_wad: wad_from_f64(p).map_err(|e| parse_err("bar", e))?,
        at,
        source: PrintSource::DailyBar,
    }))
}

pub(crate) fn parse_clock(body: &str) -> Result<VendorMarket, VendorError> {
    let r: ClockResp = serde_json::from_str(body).map_err(|e| parse_err("/v2/clock", e))?;
    // `is_open` covers the regular session only; outside it Alpaca does not distinguish extended hours.
    Ok(if r.is_open {
        VendorMarket::Open
    } else {
        VendorMarket::Closed
    })
}

fn et_date(unix_s: u64) -> String {
    chrono::DateTime::from_timestamp(unix_s as i64, 0)
        .map(|d| {
            d.with_timezone(&chrono_tz::America::New_York)
                .format("%Y-%m-%d")
                .to_string()
        })
        .unwrap_or_default()
}

fn rfc3339(unix_ns: u64) -> String {
    chrono::DateTime::from_timestamp(
        (unix_ns / 1_000_000_000) as i64,
        (unix_ns % 1_000_000_000) as u32,
    )
    .map(|d| d.to_rfc3339_opts(chrono::SecondsFormat::Nanos, true))
    .unwrap_or_default()
}

impl Alpaca {
    pub fn new(cfg: AlpacaConfig, halts: Arc<HaltFeed>) -> Self {
        let limit = RateLimit::new(cfg.max_rpm);
        Self {
            cfg,
            http: http_client(),
            limit,
            halts,
        }
    }

    async fn get(&self, base: &str, path: &str, query: &[(&str, String)]) -> VendorResult<String> {
        self.limit.acquire().await;
        let resp = self
            .http
            .get(format!("{}{}", base.trim_end_matches('/'), path))
            .header("APCA-API-KEY-ID", &self.cfg.key_id)
            .header("APCA-API-SECRET-KEY", &self.cfg.secret)
            .query(query)
            .send()
            .await
            .map_err(|e| VendorError::Http {
                vendor: V,
                endpoint: path.into(),
                message: e.to_string(),
            })?;
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        tracing::trace!(vendor = V, path, %status, body = %body.chars().take(300).collect::<String>(), "vendor response");
        if !status.is_success() {
            return Err(http_error(V, path, status, &body));
        }
        Ok(body)
    }

    async fn trades(
        &self,
        asset: &Asset,
        start_ns: u64,
        end_ns: Option<u64>,
        desc: bool,
    ) -> VendorResult<Vec<Trade>> {
        let mut q = vec![
            ("symbols", asset.symbol.clone()),
            ("start", rfc3339(start_ns)),
            ("limit", "1000".into()),
            ("sort", if desc { "desc" } else { "asc" }.into()),
            ("feed", self.cfg.feed.clone()),
        ];
        if let Some(e) = end_ns {
            q.push(("end", rfc3339(e)));
        }
        let body = self
            .get(&self.cfg.data_url, "/v2/stocks/trades", &q)
            .await?;
        parse_trades(&body, &asset.symbol, asset.plan())
    }

    async fn official(
        &self,
        asset: &Asset,
        session: &Session,
        open: bool,
    ) -> VendorResult<Option<OfficialPrint>> {
        let (from, to) = if open {
            (session.open, session.open + 15 * 60)
        } else {
            (session.close, session.close + 30 * 60)
        };
        match self
            .trades(asset, from * 1_000_000_000, Some(to * 1_000_000_000), false)
            .await
        {
            Ok(t) => {
                if let Some(p) = super::polygon::find_official(&t, &asset.listing, open) {
                    return Ok(Some(p));
                }
            }
            Err(VendorError::NotEntitled { .. }) => {}
            Err(e) => return Err(e),
        }
        let day = et_date(session.open);
        let body = self
            .get(
                &self.cfg.data_url,
                "/v2/stocks/bars",
                &[
                    ("symbols", asset.symbol.clone()),
                    ("timeframe", "1Day".into()),
                    ("start", day.clone()),
                    ("end", day),
                    ("adjustment", "raw".into()),
                    ("feed", self.cfg.feed.clone()),
                ],
            )
            .await?;
        parse_daily_bar(&body, &asset.symbol, session, open)
    }
}

// ── historical recording (credence-relayer record) ─────────────────────────────────────────────

#[derive(Deserialize)]
struct HistTradesPage {
    #[serde(default)]
    trades: HashMap<String, Vec<RawTrade>>,
    next_page_token: Option<String>,
}

#[derive(Deserialize)]
struct HistQuotesPage {
    #[serde(default)]
    quotes: HashMap<String, Vec<RawQuote>>,
    next_page_token: Option<String>,
}

/// One recorded event, in replay-file shape.
pub enum Recorded {
    Trade {
        t: u64,
        p: f64,
        s: u64,
        x: String,
        c: Vec<String>,
        z: Option<String>,
    },
    Quote {
        t: u64,
        bp: f64,
        ap: f64,
    },
}

impl Alpaca {
    /// All trades and quotes of `asset` in `[start_ns, end_ns)`, paginated, capped at `max_pages` per kind.
    pub async fn history(
        &self,
        asset: &Asset,
        start_ns: u64,
        end_ns: u64,
        max_pages: usize,
    ) -> VendorResult<Vec<(u64, Recorded)>> {
        let mut out = Vec::new();
        for kind in ["trades", "quotes"] {
            let mut token: Option<String> = None;
            for _ in 0..max_pages {
                let mut q = vec![
                    ("symbols", asset.symbol.clone()),
                    ("start", rfc3339(start_ns)),
                    ("end", rfc3339(end_ns)),
                    ("limit", "10000".to_string()),
                    ("sort", "asc".to_string()),
                    ("feed", self.cfg.feed.clone()),
                ];
                if let Some(t) = &token {
                    q.push(("page_token", t.clone()));
                }
                let path = format!("/v2/stocks/{kind}");
                let body = self.get(&self.cfg.data_url, &path, &q).await?;
                token = if kind == "trades" {
                    let page: HistTradesPage =
                        serde_json::from_str(&body).map_err(|e| parse_err(&path, e))?;
                    for r in page.trades.get(&asset.symbol).into_iter().flatten() {
                        if let Some(t) = ts_ns(&r.t) {
                            out.push((
                                t,
                                Recorded::Trade {
                                    t,
                                    p: r.p,
                                    s: r.s.max(0.0) as u64,
                                    x: exchange_mic(&r.x).into(),
                                    c: r.c.clone(),
                                    z: r.z.clone(),
                                },
                            ));
                        }
                    }
                    page.next_page_token
                } else {
                    let page: HistQuotesPage =
                        serde_json::from_str(&body).map_err(|e| parse_err(&path, e))?;
                    for r in page.quotes.get(&asset.symbol).into_iter().flatten() {
                        if let Some(t) = ts_ns(&r.t) {
                            out.push((
                                t,
                                Recorded::Quote {
                                    t,
                                    bp: r.bp,
                                    ap: r.ap,
                                },
                            ));
                        }
                    }
                    page.next_page_token
                };
                if token.is_none() {
                    break;
                }
            }
        }
        out.sort_by_key(|(t, _)| *t);
        Ok(out)
    }
}

#[async_trait]
impl MarketDataVendor for Alpaca {
    fn name(&self) -> &'static str {
        V
    }

    async fn live(&self, asset: &Asset, since_ns: u64) -> VendorResult<LiveInput> {
        let mut trades = self.trades(asset, since_ns, None, true).await?;
        if trades.is_empty() {
            // quiet symbol on the IEX feed: the latest trade (the filter still applies its age limit)
            let body = self
                .get(
                    &self.cfg.data_url,
                    "/v2/stocks/trades/latest",
                    &[
                        ("symbols", asset.symbol.clone()),
                        ("feed", self.cfg.feed.clone()),
                    ],
                )
                .await?;
            trades.extend(parse_latest_trade(&body, &asset.symbol, asset.plan())?);
        }
        let body = self
            .get(
                &self.cfg.data_url,
                "/v2/stocks/quotes/latest",
                &[
                    ("symbols", asset.symbol.clone()),
                    ("feed", self.cfg.feed.clone()),
                ],
            )
            .await?;
        Ok(LiveInput {
            trades,
            nbbo: parse_quote(&body, &asset.symbol)?,
        })
    }

    async fn official_open(
        &self,
        asset: &Asset,
        session: &Session,
    ) -> VendorResult<Option<OfficialPrint>> {
        self.official(asset, session, true).await
    }

    async fn official_close(
        &self,
        asset: &Asset,
        session: &Session,
    ) -> VendorResult<Option<OfficialPrint>> {
        self.official(asset, session, false).await
    }

    async fn status(&self, asset: &Asset) -> VendorResult<StatusInput> {
        let body = self.get(&self.cfg.trading_url, "/v2/clock", &[]).await?;
        Ok(StatusInput {
            market: parse_clock(&body)?,
            halt: self.halts.halt(&asset.symbol).await,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{conditions::classify, price::WAD};

    fn fixture(name: &str) -> String {
        std::fs::read_to_string(format!(
            "{}/tests/fixtures/alpaca/{name}",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap()
    }

    #[test]
    fn recorded_latest_trade_and_quote() {
        let t = parse_latest_trade(&fixture("trades_latest_AAPL.json"), "AAPL", Plan::Utp)
            .unwrap()
            .unwrap();
        assert_eq!(t.price_wad, 161_295_800_000_000_000_000);
        assert_eq!(t.ts_ns, 1_647_612_129_722_539_521);
        assert_eq!(t.exchange, "FINR");
        assert!(classify(t.plan, &t.conditions).regular);
        let q = parse_quote(&fixture("quotes_latest_AAPL.json"), "AAPL")
            .unwrap()
            .unwrap();
        assert_eq!((q.bid_wad, q.ask_wad), (1611 * WAD / 10, 16111 * WAD / 100));
        assert!(parse_quote(&fixture("quotes_latest_AAPL.json"), "MSFT")
            .unwrap()
            .is_none());
    }

    #[test]
    fn recorded_trades_newest_first_and_odd_lot_form_t() {
        let t = parse_trades(&fixture("trades_AAPL.json"), "AAPL", Plan::Utp).unwrap();
        assert_eq!(t.len(), 2);
        assert!(t[0].ts_ns > t[1].ts_ns);
        assert_eq!(t[0].conditions, vec!["@", "T", "I"]);
        let k = classify(t[0].plan, &t[0].conditions);
        assert!(!k.regular && !k.extended);
    }

    #[test]
    fn recorded_daily_bar_fallback() {
        // TSLA 2023-09-27 session: 09:30 ET = 13:30Z, 16:00 ET = 20:00Z
        let open = 1_695_821_400;
        let s = Session {
            ext_open: open - 1,
            open,
            close: open + 23_400,
            ext_close: open + 30_000,
            closure_type_after: credence_common::calendar::ClosureType::Overnight,
        };
        let o = parse_daily_bar(&fixture("bars_day_TSLA.json"), "TSLA", &s, true)
            .unwrap()
            .unwrap();
        assert_eq!(
            (o.price_wad, o.at, o.source),
            (244_262 * WAD / 1000, open, PrintSource::DailyBar)
        );
        let c = parse_daily_bar(&fixture("bars_day_TSLA.json"), "TSLA", &s, false)
            .unwrap()
            .unwrap();
        assert_eq!(c.price_wad, 2405 * WAD / 10);
        let other_day = Session {
            open: open + 86_400,
            close: open + 86_400 + 23_400,
            ext_open: open + 86_000,
            ext_close: open + 120_000,
            ..s
        };
        assert!(
            parse_daily_bar(&fixture("bars_day_TSLA.json"), "TSLA", &other_day, true)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn recorded_clock() {
        assert_eq!(
            parse_clock(&fixture("clock_open.json")).unwrap(),
            VendorMarket::Open
        );
        assert_eq!(
            parse_clock(&fixture("clock_closed.json")).unwrap(),
            VendorMarket::Closed
        );
    }

    #[test]
    fn exchange_codes() {
        assert_eq!(exchange_mic("Q"), "XNAS");
        assert_eq!(exchange_mic("N"), "XNYS");
        assert_eq!(exchange_mic("P"), "ARCX");
        assert_eq!(exchange_mic("?"), "OTHER");
    }
}
