//! A signer node (§10.1): polls its vendor, keeps its own observation of every asset, serves it to the
//! aggregator, and signs a proposed batch only if every report agrees with its own view (ocr::verify).
//! The node derives the EIP-712 domain from its own config, never from the aggregator.

use crate::{
    asset::Asset,
    filter::{live_observation, FilterConfig},
    metrics::{kind_label, Metrics},
    ocr::{
        verify, AssetObservation, Draft, NodeSnapshot, Refusal, SessionPrint, StatusObservation,
    },
    report::{digest, Kind, MarketStatus, Report, ReportDto},
    vendor::{DynVendor, StatusInput, VendorMarket},
};
use alloy::{
    primitives::{Address, Bytes, B256},
    sol_types::Eip712Domain,
};
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    routing::{get, post},
    Json, Router,
};
use credence_common::{
    calendar::{Calendar, Session, Window},
    signer::CredenceSigner,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::sync::RwLock;

#[derive(Debug, Clone)]
pub struct NodeConfig {
    pub id: String,
    pub assets: Vec<Asset>,
    pub poll_interval: Duration,
    /// Official open/close prints are polled at most this often.
    pub print_poll_interval: Duration,
    pub filter: FilterConfig,
    /// Shared secret the aggregator presents as `Authorization: Bearer …`.
    pub auth_token: Option<String>,
}

pub struct Node {
    pub cfg: NodeConfig,
    vendor: DynVendor,
    calendar: Arc<Calendar>,
    signer: CredenceSigner,
    domain: Eip712Domain,
    state: RwLock<HashMap<B256, AssetObservation>>,
    last_print_poll: RwLock<HashMap<(B256, Kind), u64>>,
    metrics: Metrics,
    clock: fn() -> u64,
}

pub fn now_s() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The node's market status: the calendar window, overridden toward "less open" by the vendor and the
/// halt feed (fail closed, P8).
pub fn market_status(window: Window, vendor: &StatusInput) -> MarketStatus {
    if vendor.halt.as_ref().is_some_and(|h| h.halted) {
        return MarketStatus::Halted;
    }
    match window {
        // the calendar says open but the vendor says the market is closed: closed
        Window::Regular if vendor.market == VendorMarket::Closed => MarketStatus::Closed,
        Window::Regular => MarketStatus::Regular,
        Window::Pre => MarketStatus::Pre,
        Window::Post => MarketStatus::Post,
        Window::Overnight => MarketStatus::Overnight,
        Window::Closed => MarketStatus::Closed,
    }
}

/// The session a timestamp belongs to for `sessionDate`: the one containing it, else the next one.
fn session_for(cal: &Calendar, t: u64) -> Option<Session> {
    cal.session_at(t).or_else(|| cal.next_session(t)).copied()
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SignRequest {
    pub reports: Vec<ReportDto>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignResponse {
    pub node: String,
    pub signer: Address,
    /// 65-byte r‖s‖v, present only if every report was accepted.
    pub signature: Option<Bytes>,
    /// (index, reason) for each refused report.
    pub refused: Vec<(usize, String)>,
}

impl Node {
    pub fn new(
        cfg: NodeConfig,
        vendor: DynVendor,
        calendar: Arc<Calendar>,
        signer: CredenceSigner,
        domain: Eip712Domain,
        metrics: Metrics,
    ) -> Self {
        Self {
            cfg,
            vendor,
            calendar,
            signer,
            domain,
            state: Default::default(),
            last_print_poll: Default::default(),
            metrics,
            clock: now_s,
        }
    }

    pub fn with_clock(mut self, clock: fn() -> u64) -> Self {
        self.clock = clock;
        self
    }

    pub fn signer_address(&self) -> Address {
        self.signer.address()
    }

    /// Poll the vendor once for every asset and refresh the node's observations.
    pub async fn poll_once(&self) {
        for asset in &self.cfg.assets {
            let obs = self.observe(asset).await;
            self.state.write().await.insert(asset.id, obs);
        }
    }

    async fn observe(&self, asset: &Asset) -> AssetObservation {
        let now = (self.clock)();
        let prev = self.state.read().await.get(&asset.id).cloned();
        let window = self.calendar.window_at(now);
        let status = match self.vendor.status(asset).await {
            Ok(v) => Some(market_status(window, &v)),
            Err(e) => {
                self.metrics
                    .vendor_errors
                    .with_label_values(&[self.vendor.name(), kind_label(&e)])
                    .inc();
                tracing::warn!(node = %self.cfg.id, asset = %asset.symbol, error = %e, "status failed");
                None
            }
        };
        let session = session_for(&self.calendar, now);
        let status_obs = status.zip(session).map(|(s, sess)| StatusObservation {
            status: s,
            at: now,
            session_date: Calendar::session_date(&sess),
        });

        let mut live = None;
        let mut live_session_date = None;
        if let Some(s) = status {
            if s == MarketStatus::Regular || s.is_extended() {
                let lookback = if s == MarketStatus::Regular {
                    self.cfg.filter.regular_max_age_s
                } else {
                    self.cfg.filter.extended_max_age_s
                };
                match self
                    .vendor
                    .live(asset, now.saturating_sub(lookback) * 1_000_000_000)
                    .await
                {
                    Ok(input) => match live_observation(s, &input, now, &self.cfg.filter) {
                        Ok(o) => {
                            live_session_date = session_for(&self.calendar, o.observed_at)
                                .map(|x| Calendar::session_date(&x));
                            live = Some(o);
                        }
                        Err(r) => {
                            let reason = format!("{r:?}");
                            let reason = reason
                                .split([' ', '{', '('])
                                .next()
                                .unwrap_or("other")
                                .to_owned();
                            self.metrics
                                .rejections
                                .with_label_values(&[&self.cfg.id, &reason])
                                .inc();
                            tracing::debug!(node = %self.cfg.id, asset = %asset.symbol, %r, "no LIVE observation");
                        }
                    },
                    Err(e) => {
                        self.metrics
                            .vendor_errors
                            .with_label_values(&[self.vendor.name(), kind_label(&e)])
                            .inc();
                        tracing::warn!(node = %self.cfg.id, asset = %asset.symbol, error = %e, "live failed");
                    }
                }
            }
        }

        let (open, close) = self.poll_prints(asset, now, prev.as_ref()).await;
        AssetObservation {
            asset_id: asset.id,
            status: status_obs,
            live,
            live_session_date,
            open,
            close,
        }
    }

    /// OPEN from the current session's open until found; CLOSE from the close until found.
    async fn poll_prints(
        &self,
        asset: &Asset,
        now: u64,
        prev: Option<&AssetObservation>,
    ) -> (Option<SessionPrint>, Option<SessionPrint>) {
        let Some(session) = self.calendar.current_or_last_session(now).copied() else {
            return (
                prev.and_then(|p| p.open.clone()),
                prev.and_then(|p| p.close.clone()),
            );
        };
        let sd = Calendar::session_date(&session);
        let mut open = prev.and_then(|p| p.open.clone());
        let mut close = prev.and_then(|p| p.close.clone());
        let have = |p: &Option<SessionPrint>| p.as_ref().is_some_and(|p| p.session_date == sd);

        for kind in [Kind::Open, Kind::Close] {
            let (slot, due) = match kind {
                Kind::Open => (&mut open, now >= session.open),
                _ => (&mut close, now >= session.close),
            };
            if !due || have(slot) || !self.print_poll_due(asset.id, kind, now).await {
                continue;
            }
            let r = match kind {
                Kind::Open => self.vendor.official_open(asset, &session).await,
                _ => self.vendor.official_close(asset, &session).await,
            };
            match r {
                Ok(Some(p)) => {
                    *slot = Some(SessionPrint {
                        session_date: sd,
                        price_wad: p.price_wad,
                        at: p.at,
                        source: p.source,
                    });
                }
                Ok(None) => {}
                Err(e) => {
                    self.metrics
                        .vendor_errors
                        .with_label_values(&[self.vendor.name(), kind_label(&e)])
                        .inc();
                    tracing::warn!(node = %self.cfg.id, asset = %asset.symbol, kind = kind.label(), error = %e, "official print failed");
                }
            }
        }
        (open, close)
    }

    async fn print_poll_due(&self, asset: B256, kind: Kind, now: u64) -> bool {
        let mut m = self.last_print_poll.write().await;
        let last = m.get(&(asset, kind)).copied().unwrap_or(0);
        if now.saturating_sub(last) < self.cfg.print_poll_interval.as_secs() {
            return false;
        }
        m.insert((asset, kind), now);
        true
    }

    /// Current observations, with LIVE observations older than the filter limits dropped.
    pub async fn snapshot(&self) -> NodeSnapshot {
        let now = (self.clock)();
        let assets = self
            .state
            .read()
            .await
            .values()
            .cloned()
            .map(|mut a| {
                if let Some(l) = &a.live {
                    let max = if l.status == MarketStatus::Regular {
                        self.cfg.filter.regular_max_age_s
                    } else {
                        self.cfg.filter.extended_max_age_s
                    };
                    if now.saturating_sub(l.observed_at) > max {
                        a.live = None;
                        a.live_session_date = None;
                    }
                }
                a
            })
            .collect();
        NodeSnapshot {
            node: self.cfg.id.clone(),
            signer: self.signer.address(),
            taken_at: now,
            assets,
        }
    }

    /// Verify every report against this node's own observations; sign the batch digest only if all pass.
    pub async fn sign(&self, dtos: &[ReportDto]) -> SignResponse {
        let now = (self.clock)();
        let snap = self.snapshot().await;
        let mut refused = Vec::new();
        let mut reports = Vec::with_capacity(dtos.len());
        for (i, d) in dtos.iter().enumerate() {
            let r = match Report::try_from(d) {
                Ok(r) => r,
                Err(e) => {
                    refused.push((i, format!("malformed: {e}")));
                    continue;
                }
            };
            let draft = Draft {
                asset_id: r.assetId,
                kind: Kind::from_u8(r.kind).unwrap_or(Kind::Nav),
                price_wad: r.price,
                observed_at: d.observed_at,
                session_date: d.session_date,
                status: MarketStatus::from_u8(r.marketStatus).unwrap_or(MarketStatus::Closed),
            };
            let own = snap.assets.iter().find(|a| a.asset_id == r.assetId);
            if let Err(why) = verify(&draft, own, now) {
                let label = match &why {
                    Refusal::OutOfTolerance { .. } => "out_of_tolerance",
                    Refusal::StatusMismatch { .. } => "status_mismatch",
                    Refusal::SessionMismatch { .. } => "session_mismatch",
                    Refusal::NoObservation => "no_observation",
                    Refusal::FromFuture => "from_future",
                    Refusal::UnsupportedKind => "unsupported_kind",
                };
                self.metrics
                    .refusals
                    .with_label_values(&[&self.cfg.id, label])
                    .inc();
                refused.push((i, why.to_string()));
            }
            reports.push(r);
        }
        let signature = if refused.is_empty() && !reports.is_empty() {
            match self.signer.sign_hash(&digest(&self.domain, &reports)).await {
                Ok(sig) => Some(Bytes::from(sig.as_bytes().to_vec())),
                Err(e) => {
                    refused.push((usize::MAX, format!("signer error: {e}")));
                    None
                }
            }
        } else {
            None
        };
        SignResponse {
            node: self.cfg.id.clone(),
            signer: self.signer.address(),
            signature,
            refused,
        }
    }

    /// Poll forever.
    pub async fn run(self: Arc<Self>) {
        let mut tick = tokio::time::interval(self.cfg.poll_interval);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tick.tick().await;
            self.poll_once().await;
        }
    }

    /// HTTP API for the aggregator: `GET /v1/observations`, `POST /v1/sign`.
    pub fn router(self: Arc<Self>) -> Router {
        Router::new()
            .route("/v1/observations", get(http_observations))
            .route("/v1/sign", post(http_sign))
            .with_state(self)
    }

    fn authorised(&self, headers: &HeaderMap) -> bool {
        let Some(expected) = &self.cfg.auth_token else {
            return true;
        };
        let got = headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .unwrap_or("");
        constant_time_eq(got.as_bytes(), expected.as_bytes())
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

async fn http_observations(
    State(node): State<Arc<Node>>,
    headers: HeaderMap,
) -> Result<Json<NodeSnapshot>, StatusCode> {
    if !node.authorised(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(Json(node.snapshot().await))
}

async fn http_sign(
    State(node): State<Arc<Node>>,
    headers: HeaderMap,
    Json(req): Json<SignRequest>,
) -> Result<Json<SignResponse>, StatusCode> {
    if !node.authorised(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if req.reports.len() > 256 {
        return Err(StatusCode::PAYLOAD_TOO_LARGE);
    }
    Ok(Json(node.sign(&req.reports).await))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vendor::HaltInfo;

    fn st(market: VendorMarket, halted: bool) -> StatusInput {
        StatusInput {
            market,
            halt: Some(HaltInfo {
                halted,
                reason: None,
            }),
        }
    }

    #[test]
    fn status_fails_closed() {
        assert_eq!(
            market_status(Window::Regular, &st(VendorMarket::Open, false)),
            MarketStatus::Regular
        );
        assert_eq!(
            market_status(Window::Regular, &st(VendorMarket::Closed, false)),
            MarketStatus::Closed
        );
        assert_eq!(
            market_status(Window::Regular, &st(VendorMarket::Open, true)),
            MarketStatus::Halted
        );
        assert_eq!(
            market_status(Window::Closed, &st(VendorMarket::Open, false)),
            MarketStatus::Closed
        );
        assert_eq!(
            market_status(Window::Overnight, &st(VendorMarket::Closed, false)),
            MarketStatus::Overnight
        );
        assert_eq!(
            market_status(Window::Pre, &st(VendorMarket::Extended, false)),
            MarketStatus::Pre
        );
        assert_eq!(
            market_status(
                Window::Regular,
                &StatusInput {
                    market: VendorMarket::Unknown,
                    halt: None
                }
            ),
            MarketStatus::Regular
        );
    }

    #[test]
    fn token_compare() {
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"ab"));
    }
}
