//! Polygon.io (rebranded Massive in 2026; the `api.polygon.io` endpoints are unchanged). Feed A's
//! vendor (ADR-0002). Real-time SIP trades and quotes need the Stocks Advanced plan; the free Basic plan
//! answers only reference, market-status and end-of-day endpoints, and this adapter reports
//! `NotEntitled` for the rest.
//!
//! Endpoints:
//! * `GET /v3/trades/{ticker}`: recent trades (LIVE), auction prints (OPEN/CLOSE)
//! * `GET /v2/last/nbbo/{ticker}`: NBBO for the mid cross-check
//! * `GET /v1/open-close/{ticker}/{date}?adjusted=false`: official open/close fallback
//! * `GET /v1/marketstatus/now`: market session
//! * `GET /v3/reference/conditions`: numeric condition id → CTA/UTP SIP code
//!
//! Halts come from the Nasdaq Trader halt feed ([`super::halts`]).

use super::{
    halts::HaltFeed, http_client, http_error, LiveInput, MarketDataVendor, OfficialPrint, PrintSource, Quote,
    RateLimit, StatusInput, Trade, VendorError, VendorMarket, VendorResult,
};
use crate::{
    asset::{Asset, Plan},
    conditions::classify,
    price::wad_from_f64,
};
use async_trait::async_trait;
use credence_common::calendar::Session;
use serde::Deserialize;
use std::{collections::HashMap, sync::Arc};
use tokio::sync::RwLock;

const V: &str = "polygon";

#[derive(Debug, Clone)]
pub struct PolygonConfig {
    pub api_key: String,
    pub base_url: String,
    /// Requests per minute allowed by the plan (Basic: 5; paid: effectively unlimited).
    pub max_rpm: u32,
}

pub struct Polygon {
    cfg: PolygonConfig,
    http: reqwest::Client,
    limit: RateLimit,
    /// Polygon condition id → (CTA code, UTP code).
    conditions: RwLock<HashMap<u32, SipCodes>>,
    halts: Arc<HaltFeed>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct SipCodes {
    #[serde(rename = "CTA")]
    pub cta: Option<String>,
    #[serde(rename = "UTP")]
    pub utp: Option<String>,
}

/// Polygon exchange id → MIC (from `/v3/reference/exchanges`).
pub fn exchange_mic(id: u32) -> &'static str {
    match id {
        1 => "XASE",
        2 => "XBOS",
        3 => "XCIS",
        4 => "FINR",
        6 => "XISE",
        7 => "EDGA",
        8 => "EDGX",
        9 => "XCHI",
        10 => "XNYS",
        11 => "ARCX",
        12 => "XNAS",
        14 => "LTSE",
        15 => "IEXG",
        16 => "CBSX",
        17 => "XPHL",
        18 => "BATY",
        19 => "BATS",
        20 => "EPRL",
        21 => "MEMX",
        _ => "OTHER",
    }
}

/// Reference snapshot of Polygon's stock trade conditions (ids → SIP codes). Loaded from the API at
/// start-up when the key allows; this table is the fallback. Ids whose meaning is uncertain map to "?"
/// so they classify as ineligible (fail closed).
pub fn builtin_conditions() -> HashMap<u32, SipCodes> {
    let both = |c: &str| SipCodes { cta: Some(c.into()), utp: Some(c.into()) };
    let cta = |c: &str| SipCodes { cta: Some(c.into()), utp: None };
    let utp = |c: &str| SipCodes { cta: None, utp: Some(c.into()) };
    HashMap::from([
        (0, both("@")),  // Regular Sale
        (1, utp("A")),   // Acquisition
        (2, SipCodes { cta: Some("B".into()), utp: Some("W".into()) }), // Average Price Trade
        (3, cta("E")),   // Automatic Execution
        (4, utp("B")),   // Bunched Trade
        (5, utp("G")),   // Bunched Sold Trade
        (6, cta("I")),   // CAP Election
        (7, both("C")),  // Cash Sale
        (8, utp("6")),   // Closing Prints
        (9, both("X")),  // Cross Trade
        (10, both("4")), // Derivatively Priced
        (11, utp("D")),  // Distribution
        (12, both("T")), // Form T (extended hours)
        (13, both("U")), // Extended Trading Hours (Sold Out of Sequence)
        (14, both("F")), // Intermarket Sweep
        (15, both("M")), // Market Center Official Close
        (16, both("Q")), // Market Center Official Open
        (17, cta("O")),  // Market Center Opening Trade
        (18, cta("5")),  // Market Center Reopening Trade
        (19, cta("6")),  // Market Center Closing Trade
        (20, both("N")), // Next Day
        (21, both("H")), // Price Variation Trade
        (22, both("P")), // Prior Reference Price
        (23, both("K")), // Rule 155 Trade (AMEX)
        (24, both("?")), // Rule 127 NYSE
        (25, utp("O")),  // Opening Prints
        (27, utp("1")),  // Stopped Stock (Regular Trade)
        (28, utp("5")),  // Re-Opening Prints
        (29, both("R")), // Seller
        (30, both("L")), // Sold Last
        (32, both("Z")), // Sold (Out of Sequence)
        (33, both("?")), // Sold + Stopped
        (34, utp("S")),  // Split Trade
        (35, both("?")), // Stock Option
        (36, utp("Y")),  // Yellow Flag Regular Trade
        (37, both("I")), // Odd Lot Trade
        (38, both("9")), // Corrected Consolidated Close
        (41, both("?")), // Trade Thru Exempt
        (52, both("V")), // Contingent Trade
        (53, both("7")), // Qualified Contingent Trade
    ])
}

// ── response shapes ──────────────────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct TradesResp {
    #[serde(default)]
    results: Vec<RawTrade>,
}

#[derive(Deserialize)]
pub(crate) struct RawTrade {
    #[serde(default)]
    conditions: Vec<u32>,
    exchange: u32,
    price: f64,
    #[serde(default)]
    size: f64,
    sip_timestamp: u64,
    participant_timestamp: Option<u64>,
    tape: Option<u8>,
}

#[derive(Deserialize)]
struct NbboResp {
    results: Option<RawNbbo>,
}

#[derive(Deserialize)]
struct RawNbbo {
    #[serde(rename = "p")]
    bid: f64,
    #[serde(rename = "P")]
    ask: f64,
    t: u64,
    y: Option<u64>,
}

#[derive(Deserialize)]
struct StatusResp {
    market: String,
}

#[derive(Deserialize)]
struct OpenCloseResp {
    status: String,
    open: Option<f64>,
    close: Option<f64>,
}

#[derive(Deserialize)]
struct ConditionsResp {
    #[serde(default)]
    results: Vec<RawCondition>,
}

#[derive(Deserialize)]
struct RawCondition {
    id: u32,
    #[serde(default)]
    sip_mapping: SipCodes,
    #[serde(default)]
    data_types: Vec<String>,
}

// ── parsing (pure, used by the recorded-response tests) ──────────────────────────────────────────

pub(crate) fn parse_conditions(body: &str) -> Result<HashMap<u32, SipCodes>, VendorError> {
    let r: ConditionsResp = serde_json::from_str(body).map_err(|e| parse_err("/v3/reference/conditions", e))?;
    Ok(r.results
        .into_iter()
        .filter(|c| c.data_types.is_empty() || c.data_types.iter().any(|d| d == "trade"))
        .map(|c| (c.id, c.sip_mapping))
        .collect())
}

pub(crate) fn to_trade(t: &RawTrade, conditions: &HashMap<u32, SipCodes>, listing_plan: Plan) -> Option<Trade> {
    let plan = t.tape.and_then(|x| Plan::from_tape(&x.to_string())).unwrap_or(listing_plan);
    let codes = t
        .conditions
        .iter()
        .map(|id| {
            let m = conditions.get(id);
            let code = match plan {
                Plan::Cta => m.and_then(|m| m.cta.clone().or_else(|| m.utp.clone())),
                Plan::Utp => m.and_then(|m| m.utp.clone().or_else(|| m.cta.clone())),
            };
            code.unwrap_or_else(|| "?".into()) // unknown id → ineligible
        })
        .collect();
    Some(Trade {
        price_wad: wad_from_f64(t.price).ok()?,
        size: t.size.max(0.0) as u64,
        ts_ns: t.participant_timestamp.unwrap_or(t.sip_timestamp),
        exchange: exchange_mic(t.exchange).into(),
        conditions: codes,
        plan,
    })
}

pub(crate) fn parse_trades(
    body: &str,
    conditions: &HashMap<u32, SipCodes>,
    listing_plan: Plan,
) -> Result<Vec<Trade>, VendorError> {
    let r: TradesResp = serde_json::from_str(body).map_err(|e| parse_err("/v3/trades", e))?;
    let mut v: Vec<Trade> = r.results.iter().filter_map(|t| to_trade(t, conditions, listing_plan)).collect();
    v.sort_by(|a, b| b.ts_ns.cmp(&a.ts_ns));
    Ok(v)
}

pub(crate) fn parse_nbbo(body: &str) -> Result<Option<Quote>, VendorError> {
    let r: NbboResp = serde_json::from_str(body).map_err(|e| parse_err("/v2/last/nbbo", e))?;
    let Some(q) = r.results else { return Ok(None) };
    Ok(Some(Quote {
        bid_wad: wad_from_f64(q.bid).map_err(|e| parse_err("/v2/last/nbbo", e))?,
        ask_wad: wad_from_f64(q.ask).map_err(|e| parse_err("/v2/last/nbbo", e))?,
        ts_ns: q.y.unwrap_or(q.t),
    }))
}

pub(crate) fn parse_market_status(body: &str) -> Result<VendorMarket, VendorError> {
    let r: StatusResp = serde_json::from_str(body).map_err(|e| parse_err("/v1/marketstatus/now", e))?;
    Ok(match r.market.as_str() {
        "open" => VendorMarket::Open,
        "extended-hours" => VendorMarket::Extended,
        "closed" => VendorMarket::Closed,
        _ => VendorMarket::Unknown,
    })
}

/// The first official print (condition Q or M) reported by the listing exchange.
pub(crate) fn find_official(trades: &[Trade], listing: &str, open: bool) -> Option<OfficialPrint> {
    trades
        .iter()
        .filter(|t| t.exchange == listing)
        .filter(|t| {
            let k = classify(t.plan, &t.conditions);
            if open {
                k.official_open
            } else {
                k.official_close
            }
        })
        .min_by_key(|t| t.ts_ns)
        .map(|t| OfficialPrint { price_wad: t.price_wad, at: t.ts_ns / 1_000_000_000, source: PrintSource::AuctionTrade })
}

pub(crate) fn parse_open_close(body: &str, session: &Session, open: bool) -> Result<Option<OfficialPrint>, VendorError> {
    let r: OpenCloseResp = serde_json::from_str(body).map_err(|e| parse_err("/v1/open-close", e))?;
    if r.status != "OK" {
        return Ok(None);
    }
    let (p, at) = if open { (r.open, session.open) } else { (r.close, session.close) };
    let Some(p) = p else { return Ok(None) };
    Ok(Some(OfficialPrint {
        price_wad: wad_from_f64(p).map_err(|e| parse_err("/v1/open-close", e))?,
        at,
        source: PrintSource::DailyBar,
    }))
}

fn parse_err(endpoint: &str, e: impl std::fmt::Display) -> VendorError {
    VendorError::Parse { vendor: V, endpoint: endpoint.into(), message: e.to_string() }
}

// ── client ───────────────────────────────────────────────────────────────────────────────────────

impl Polygon {
    pub fn new(cfg: PolygonConfig, halts: Arc<HaltFeed>) -> Self {
        let limit = RateLimit::new(cfg.max_rpm);
        Self { cfg, http: http_client(), limit, conditions: RwLock::new(builtin_conditions()), halts }
    }

    async fn get(&self, path: &str, query: &[(&str, String)]) -> VendorResult<String> {
        self.limit.acquire().await;
        let url = format!("{}{}", self.cfg.base_url.trim_end_matches('/'), path);
        let resp = self
            .http
            .get(&url)
            .bearer_auth(&self.cfg.api_key)
            .query(query)
            .send()
            .await
            .map_err(|e| VendorError::Http { vendor: V, endpoint: path.into(), message: e.to_string() })?;
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(http_error(V, path, status, &body));
        }
        Ok(body)
    }

    /// Refresh the condition table from the API (the fallback table stays if this fails).
    pub async fn load_conditions(&self) -> VendorResult<usize> {
        let body = self
            .get(
                "/v3/reference/conditions",
                &[("asset_class", "stocks".into()), ("data_type", "trade".into()), ("limit", "1000".into())],
            )
            .await?;
        let fresh = parse_conditions(&body)?;
        let n = fresh.len();
        if n > 0 {
            self.conditions.write().await.extend(fresh);
        }
        Ok(n)
    }

    async fn trades(&self, asset: &Asset, from_ns: u64, to_ns: Option<u64>, desc: bool) -> VendorResult<Vec<Trade>> {
        let mut q = vec![
            ("timestamp.gte", from_ns.to_string()),
            ("order", if desc { "desc" } else { "asc" }.to_string()),
            ("sort", "timestamp".to_string()),
            ("limit", "1000".to_string()),
        ];
        if let Some(to) = to_ns {
            q.push(("timestamp.lt", to.to_string()));
        }
        let body = self.get(&format!("/v3/trades/{}", asset.symbol), &q).await?;
        parse_trades(&body, &*self.conditions.read().await, asset.plan())
    }

    async fn official(&self, asset: &Asset, session: &Session, open: bool) -> VendorResult<Option<OfficialPrint>> {
        let (from, to) = if open {
            (session.open, session.open + 15 * 60)
        } else {
            (session.close, session.close + 30 * 60)
        };
        match self.trades(asset, from * 1_000_000_000, Some(to * 1_000_000_000), false).await {
            Ok(t) => {
                if let Some(p) = find_official(&t, &asset.listing, open) {
                    return Ok(Some(p));
                }
            }
            Err(VendorError::NotEntitled { .. }) => {} // fall through to the end-of-day endpoint
            Err(e) => return Err(e),
        }
        let date = chrono::DateTime::from_timestamp(session.open as i64, 0)
            .map(|d| d.with_timezone(&chrono_tz::America::New_York).format("%Y-%m-%d").to_string())
            .ok_or_else(|| VendorError::Other("bad session time".into()))?;
        let path = format!("/v1/open-close/{}/{}", asset.symbol, date);
        match self.get(&path, &[("adjusted", "false".into())]).await {
            Ok(body) => parse_open_close(&body, session, open),
            Err(VendorError::Http { message, .. }) if message.starts_with("404") => Ok(None),
            Err(e) => Err(e),
        }
    }
}

#[async_trait]
impl MarketDataVendor for Polygon {
    fn name(&self) -> &'static str {
        V
    }

    async fn live(&self, asset: &Asset, since_ns: u64) -> VendorResult<LiveInput> {
        let trades = self.trades(asset, since_ns, None, true).await?;
        let body = self.get(&format!("/v2/last/nbbo/{}", asset.symbol), &[]).await?;
        Ok(LiveInput { trades, nbbo: parse_nbbo(&body)? })
    }

    async fn official_open(&self, asset: &Asset, session: &Session) -> VendorResult<Option<OfficialPrint>> {
        self.official(asset, session, true).await
    }

    async fn official_close(&self, asset: &Asset, session: &Session) -> VendorResult<Option<OfficialPrint>> {
        self.official(asset, session, false).await
    }

    async fn status(&self, asset: &Asset) -> VendorResult<StatusInput> {
        let body = self.get("/v1/marketstatus/now", &[]).await?;
        Ok(StatusInput { market: parse_market_status(&body)?, halt: self.halts.halt(&asset.symbol).await })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        std::fs::read_to_string(format!("{}/tests/fixtures/polygon/{name}", env!("CARGO_MANIFEST_DIR"))).unwrap()
    }

    #[test]
    fn recorded_conditions_agree_with_builtin_table() {
        let api = parse_conditions(&fixture("conditions_stocks.json")).unwrap();
        assert!(api.len() >= 10);
        let builtin = builtin_conditions();
        for (id, codes) in &api {
            assert_eq!(builtin.get(id), Some(codes), "condition {id}");
        }
    }

    #[test]
    fn recorded_trades_map_to_form_t_odd_lots() {
        let t = parse_trades(&fixture("trades_AAPL.json"), &builtin_conditions(), Plan::Utp).unwrap();
        assert_eq!(t.len(), 2);
        assert_eq!(t[0].conditions, vec!["T", "I"]);
        assert_eq!(t[0].plan, Plan::Utp);
        assert_eq!(t[0].ts_ns, 1_651_181_822_461_636_600);
        assert!(t.iter().any(|x| x.exchange == "XNAS"));
        let k = classify(t[0].plan, &t[0].conditions);
        assert!(!k.regular && !k.extended, "Form T odd lot is never a LIVE print");
    }

    #[test]
    fn recorded_nbbo_and_status() {
        let q = parse_nbbo(&fixture("last_nbbo_AAPL.json")).unwrap().unwrap();
        assert_eq!(q.bid_wad, wad_from_f64(155.65).unwrap());
        assert_eq!(q.ask_wad, wad_from_f64(155.66).unwrap());
        assert_eq!(q.ts_ns, 1_652_192_754_171_619_000, "participant time preferred");
        assert_eq!(parse_market_status(&fixture("marketstatus_now.json")).unwrap(), VendorMarket::Extended);
    }

    #[test]
    fn recorded_open_close_fallback() {
        let s = Session { ext_open: 1, open: 100, close: 200, ext_close: 300, closure_type_after: credence_common::calendar::ClosureType::Overnight };
        let o = parse_open_close(&fixture("open_close_AAPL.json"), &s, true).unwrap().unwrap();
        assert_eq!((o.price_wad, o.at, o.source), (wad_from_f64(123.66).unwrap(), 100, PrintSource::DailyBar));
        let c = parse_open_close(&fixture("open_close_AAPL.json"), &s, false).unwrap().unwrap();
        assert_eq!((c.price_wad, c.at), (123 * crate::price::WAD, 200));
    }

    #[test]
    fn recorded_exchange_ids() {
        #[derive(Deserialize)]
        struct R {
            results: Vec<E>,
        }
        #[derive(Deserialize)]
        struct E {
            id: u32,
            mic: Option<String>,
            asset_class: String,
        }
        let r: R = serde_json::from_str(&fixture("exchanges.json")).unwrap();
        for e in r.results.iter().filter(|e| e.asset_class == "stocks" && e.id != 4) {
            if let Some(m) = &e.mic {
                assert_eq!(exchange_mic(e.id), m.as_str(), "exchange {}", e.id);
            }
        }
    }

    #[test]
    fn official_open_only_from_listing_exchange() {
        let mk = |ex: &str, cond: &str, ts: u64, p: u128| Trade {
            price_wad: p,
            size: 1,
            ts_ns: ts,
            exchange: ex.into(),
            conditions: vec![cond.into()],
            plan: Plan::Utp,
        };
        let t = vec![mk("ARCX", "Q", 1, 5), mk("XNAS", "@", 2, 6), mk("XNAS", "Q", 3_000_000_000, 7), mk("XNAS", "Q", 4_000_000_000, 8)];
        let p = find_official(&t, "XNAS", true).unwrap();
        assert_eq!((p.price_wad, p.at), (7, 3));
        assert!(find_official(&t, "XNAS", false).is_none());
    }
}
