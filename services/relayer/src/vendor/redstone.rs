//! RedStone print derivation (`PRINT_SOURCE=redstone`, ADR-0009 D1, **testnet only**, PM ruling S2).
//!
//! No free on-chain feed publishes the official auction prints, so on the public testnet OPEN and CLOSE
//! come from RedStone `redstone-primary-prod` packages of the regular-session feed (`<TICKER>`):
//!
//! * **OPEN** = the first package at or after `open + 5 s` whose value differs from the prior close;
//! * **CLOSE** = the last package before `close + 60 s`;
//!
//! both timestamped with the package time and flagged [`PrintSource::OracleFirstRegular`]. The prior
//! close is the value the feed holds just before the open: the regular feed does not move while the
//! venue is closed (checked on recorded data, `tests/fixtures/redstone`), so this equals the CLOSE the
//! same rule derived for the previous session even when that session is older than the gateway's
//! 24 h history.
//!
//! Packages are verified like RedStone's EVM connector: secp256k1 over `keccak256(package)` (no
//! EIP-191 prefix), authorised signers of `redstone-primary-prod`, one package per signer, all at one
//! timestamp, at least 3 of 5, median (the mean of the two middle values for an even count), 8
//! decimals → WAD. The byte layout is the one `packages/feeds/src/redstone.ts` documents and tests.
//!
//! LIVE and STATUS still come from the wrapped vendor; this module only replaces OPEN and CLOSE.

use super::{
    DynVendor, LiveInput, MarketDataVendor, OfficialPrint, PrintSource, StatusInput, VendorError,
    VendorResult,
};
use crate::asset::Asset;
use alloy::primitives::{address, keccak256, Address, Signature};
use async_trait::async_trait;
use base64::Engine as _;
use credence_common::calendar::Session;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, path::Path, sync::Arc};

/// Authorised signers of `redstone-primary-prod` (`PrimaryProdDataServiceConsumerBase.sol`, checked 2026-09-28).
pub const PRIMARY_PROD_SIGNERS: [Address; 5] = [
    address!("8BB8F32Df04c8b654987DAaeD53D6B6091e3B774"),
    address!("dEB22f54738d54976C4c0fe5ce6d408E40d88499"),
    address!("51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202"),
    address!("DD682daEC5A90dD295d14DA4b0bec9281017b5bE"),
    address!("9c5AE89C4Af6aA32cE58588DBaF90d18a855B6de"),
];
pub const PRIMARY_PROD_THRESHOLD: usize = 3;
/// OPEN: packages before `open + 5 s` are ignored.
pub const OPEN_DELAY_S: u64 = 5;
/// CLOSE: the last package before `close + 60 s`.
pub const CLOSE_WINDOW_S: u64 = 60;
/// RedStone packages are produced on a 10 s grid.
pub const GRID_S: u64 = 10;
/// How far after the open the OPEN search goes before giving up for this poll.
pub const OPEN_SEARCH_S: u64 = 15 * 60;
const VALUE_DECIMALS: u32 = 8;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DataPoint {
    pub data_feed_id: String,
    pub value: serde_json::Number,
}

/// One signed package as the gateway serves it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewayPackage {
    pub timestamp_milliseconds: u64,
    /// base64, 65 bytes r‖s‖v.
    pub signature: String,
    pub data_points: Vec<DataPoint>,
    pub signer_address: String,
}

/// Decimal number → integer with 8 decimals (the connector's value), rounded like JS `toFixed(8)`.
pub fn to_value8(n: &serde_json::Number) -> Option<u128> {
    let s = if let Some(u) = n.as_u64() {
        format!("{u}.0")
    } else {
        format!("{:.8}", n.as_f64()?)
    };
    if s.starts_with('-') {
        return None;
    }
    let (int, frac) = s.split_once('.').unwrap_or((&s, ""));
    let frac = format!("{frac:0<8}");
    int.parse::<u128>()
        .ok()?
        .checked_mul(10u128.pow(VALUE_DECIMALS))?
        .checked_add(frac[..8].parse::<u128>().ok()?)
}

fn feed_id_bytes32(id: &str) -> [u8; 32] {
    let mut b = [0u8; 32];
    let s = id.as_bytes();
    b[..s.len().min(32)].copy_from_slice(&s[..s.len().min(32)]);
    b
}

/// The exact bytes a RedStone node signs: points (feedId ‖ value) sorted by feed id, then
/// timestampMs (6 B) ‖ valueByteSize = 32 (4 B) ‖ count (3 B).
pub fn package_bytes(p: &GatewayPackage) -> Option<Vec<u8>> {
    let mut points: Vec<([u8; 32], u128)> = p
        .data_points
        .iter()
        .map(|d| Some((feed_id_bytes32(&d.data_feed_id), to_value8(&d.value)?)))
        .collect::<Option<_>>()?;
    points.sort_by_key(|p| p.0);
    let mut out = Vec::with_capacity(points.len() * 64 + 13);
    for (id, v) in &points {
        out.extend_from_slice(id);
        out.extend_from_slice(&[0u8; 16]);
        out.extend_from_slice(&v.to_be_bytes());
    }
    out.extend_from_slice(&p.timestamp_milliseconds.to_be_bytes()[2..]);
    out.extend_from_slice(&32u32.to_be_bytes());
    out.extend_from_slice(&(points.len() as u32).to_be_bytes()[1..]);
    Some(out)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Verified {
    pub feed_id: String,
    pub value8: u128,
    pub timestamp_ms: u64,
    pub signer: Address,
    pub authorised: bool,
}

/// Recover the signer of one package (no EIP-191 prefix, like the connector).
pub fn verify(p: &GatewayPackage, signers: &[Address]) -> Option<Verified> {
    let point = p.data_points.first()?;
    let sig = base64::engine::general_purpose::STANDARD
        .decode(&p.signature)
        .ok()?;
    if sig.len() != 65 {
        return None;
    }
    let sig = Signature::from_raw(&sig).ok()?;
    let signer = sig
        .recover_address_from_prehash(&keccak256(package_bytes(p)?))
        .ok()?;
    Some(Verified {
        feed_id: point.data_feed_id.clone(),
        value8: to_value8(&point.value)?,
        timestamp_ms: p.timestamp_milliseconds,
        signer,
        authorised: signers.contains(&signer),
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Aggregated {
    /// Median, 8 decimals.
    pub value8: u128,
    pub timestamp_ms: u64,
    pub signers: Vec<Address>,
}

impl Aggregated {
    pub fn value_wad(&self) -> u128 {
        self.value8 * 10u128.pow(18 - VALUE_DECIMALS)
    }
    pub fn at(&self) -> u64 {
        self.timestamp_ms / 1000
    }
}

/// The connector's aggregation for one feed: unique authorised signers, one timestamp, ≥ threshold, median.
pub fn aggregate(
    feed: &str,
    pkgs: &[GatewayPackage],
    signers: &[Address],
    threshold: usize,
) -> Option<Aggregated> {
    let mut good: Vec<Verified> = Vec::new();
    for p in pkgs {
        let Some(v) = verify(p, signers) else {
            continue;
        };
        if !v.authorised || v.feed_id != feed || good.iter().any(|g| g.signer == v.signer) {
            continue;
        }
        good.push(v);
    }
    let ts = good.first()?.timestamp_ms;
    if good.len() < threshold || good.iter().any(|g| g.timestamp_ms != ts) {
        return None;
    }
    let mut values: Vec<u128> = good.iter().map(|g| g.value8).collect();
    values.sort_unstable();
    let mid = values.len() / 2;
    let value8 = if values.len() % 2 == 1 {
        values[mid]
    } else {
        (values[mid - 1] + values[mid]) / 2
    };
    Some(Aggregated {
        value8,
        timestamp_ms: ts,
        signers: good.into_iter().map(|g| g.signer).collect(),
    })
}

/// OPEN (D1): the first package at or after `open + 5 s` whose value differs from `prior_close`.
/// `series` is ascending by time.
pub fn derive_open(series: &[Aggregated], open: u64, prior_close8: u128) -> Option<&Aggregated> {
    series
        .iter()
        .find(|a| a.at() >= open + OPEN_DELAY_S && a.value8 != prior_close8)
}

/// CLOSE (D1): the last package before `close + 60 s` (and not before the session's open).
pub fn derive_close(series: &[Aggregated], open: u64, close: u64) -> Option<&Aggregated> {
    series
        .iter()
        .rev()
        .find(|a| a.at() < close + CLOSE_WINDOW_S && a.at() >= open)
}

/// Every feed's packages at one timestamp.
pub type Snapshot = HashMap<String, Vec<GatewayPackage>>;

/// Where packages come from: the gateway's history, or a recording.
#[async_trait]
pub trait PackageSource: Send + Sync {
    /// The packages of `feed` signed at `ts` (unix seconds on the 10 s grid); `None` if there are none
    /// (yet).
    async fn at(&self, feed: &str, ts: u64) -> VendorResult<Option<Vec<GatewayPackage>>>;
}

/// `GET <gateway>/data-packages/historical/redstone-primary-prod/<ms>` (about 24 h of history).
pub struct Gateway {
    pub urls: Vec<String>,
    http: reqwest::Client,
    cache: tokio::sync::Mutex<HashMap<u64, Arc<Snapshot>>>,
}

pub const HISTORY_GATEWAYS: [&str; 2] = [
    "https://oracle-gateway-2.a.redstone.finance",
    "https://oracle-gateway-1.a.redstone.finance",
];

impl Gateway {
    pub fn new(urls: Vec<String>) -> Self {
        Self {
            urls,
            http: super::http_client(),
            cache: Default::default(),
        }
    }
}

impl Gateway {
    /// Every feed's packages signed at `ts` (unix seconds, 10 s grid); `None` outside the history.
    pub async fn snapshot(&self, ts: u64) -> VendorResult<Option<Arc<Snapshot>>> {
        if let Some(m) = self.cache.lock().await.get(&ts) {
            return Ok(Some(m.clone()));
        }
        let mut last = None;
        for u in &self.urls {
            let url = format!(
                "{u}/data-packages/historical/redstone-primary-prod/{}",
                ts * 1000
            );
            let res = match self.http.get(&url).send().await {
                Ok(r) => r,
                Err(e) => {
                    last = Some(e.to_string());
                    continue;
                }
            };
            if !res.status().is_success() {
                last = Some(format!("HTTP {}", res.status()));
                continue;
            }
            let body = res.text().await.map_err(|e| VendorError::Http {
                vendor: "redstone",
                endpoint: "historical".into(),
                message: e.to_string(),
            })?;
            // gateway-1 answers "Hello! I am working correctly" for history it does not serve
            let Ok(m) = serde_json::from_str::<HashMap<String, Vec<GatewayPackage>>>(&body) else {
                last = Some(format!("{u}: not a package map"));
                continue;
            };
            let m = Arc::new(m);
            let mut c = self.cache.lock().await;
            if c.len() > 256 {
                c.clear();
            }
            c.insert(ts, m.clone());
            return Ok(Some(m));
        }
        tracing::debug!(ts, error = ?last, "redstone: no history at this timestamp");
        Ok(None)
    }

    /// A recording of `feeds` from `from` to `to` (inclusive, 10 s grid), in the `Recorded` format.
    pub async fn record(&self, feeds: &[String], from: u64, to: u64) -> serde_json::Value {
        let mut snapshots = serde_json::Map::new();
        let mut t = grid_up(from);
        while t <= to {
            let v = match self.snapshot(t).await {
                Ok(Some(m)) => serde_json::json!(feeds
                    .iter()
                    .map(|f| (f.clone(), m.get(f).cloned().unwrap_or_default()))
                    .collect::<HashMap<_, _>>()),
                Ok(None) => serde_json::json!({ "error": "not in the gateway history" }),
                Err(e) => serde_json::json!({ "error": e.to_string() }),
            };
            snapshots.insert(t.to_string(), v);
            t += GRID_S;
        }
        serde_json::json!({
            "source": "oracle-gateway historical, redstone-primary-prod",
            "from": from, "to": to, "feeds": feeds, "snapshots": snapshots,
        })
    }
}

#[async_trait]
impl PackageSource for Gateway {
    async fn at(&self, feed: &str, ts: u64) -> VendorResult<Option<Vec<GatewayPackage>>> {
        Ok(self.snapshot(ts).await?.and_then(|m| m.get(feed).cloned()))
    }
}

/// A recording (`tests/fixtures/redstone/*.json`): `{ snapshots: { "<ts>": { "<feed>": [package] } } }`.
/// `shift_s` maps the recorded times onto another calendar (a warped replay or a synthetic devnode
/// calendar): a request for `ts` reads the recording at `ts − shift_s`.
pub struct Recorded {
    snapshots: HashMap<u64, HashMap<String, Vec<GatewayPackage>>>,
    pub shift_s: i64,
}

#[derive(Deserialize)]
struct RecordingFile {
    snapshots: HashMap<String, serde_json::Value>,
}

impl Recorded {
    pub fn load(paths: &[&Path], shift_s: i64) -> anyhow::Result<Self> {
        let mut snapshots = HashMap::new();
        for p in paths {
            let f: RecordingFile = serde_json::from_str(&std::fs::read_to_string(p)?)?;
            for (ts, v) in f.snapshots {
                // a snapshot the recorder could not fetch is stored as { "error": … }
                if let Ok(m) = serde_json::from_value::<HashMap<String, Vec<GatewayPackage>>>(v) {
                    snapshots.insert(ts.parse()?, m);
                }
            }
        }
        Ok(Self { snapshots, shift_s })
    }

    pub fn timestamps(&self) -> Vec<u64> {
        let mut v: Vec<u64> = self.snapshots.keys().copied().collect();
        v.sort_unstable();
        v
    }
}

#[async_trait]
impl PackageSource for Recorded {
    async fn at(&self, feed: &str, ts: u64) -> VendorResult<Option<Vec<GatewayPackage>>> {
        let Some(t) = (ts as i64).checked_sub(self.shift_s) else {
            return Ok(None);
        };
        Ok(self
            .snapshots
            .get(&(t as u64))
            .and_then(|m| m.get(feed))
            .filter(|v| !v.is_empty())
            .cloned())
    }
}

/// Derives OPEN / CLOSE from RedStone; LIVE and STATUS from `inner`.
pub struct RedStonePrints {
    pub inner: DynVendor,
    pub source: Arc<dyn PackageSource>,
    pub signers: Vec<Address>,
    pub threshold: usize,
    /// Shift between the recording and the calendar (0 for the live gateway).
    pub shift_s: i64,
    /// Wall clock (unix s), for "not available yet".
    pub now: Arc<dyn Fn() -> u64 + Send + Sync>,
}

fn grid_up(t: u64) -> u64 {
    t.div_ceil(GRID_S) * GRID_S
}
fn grid_down(t: u64) -> u64 {
    t / GRID_S * GRID_S
}

impl RedStonePrints {
    pub fn new(inner: DynVendor, source: Arc<dyn PackageSource>) -> Self {
        Self {
            inner,
            source,
            signers: PRIMARY_PROD_SIGNERS.to_vec(),
            threshold: PRIMARY_PROD_THRESHOLD,
            shift_s: 0,
            now: Arc::new(crate::node::now_s),
        }
    }

    async fn agg(&self, feed: &str, ts: u64) -> VendorResult<Option<Aggregated>> {
        Ok(self
            .source
            .at(feed, ts)
            .await?
            .and_then(|p| aggregate(feed, &p, &self.signers, self.threshold))
            .map(|mut a| {
                // shifted recordings: report the print on the calendar's time line
                a.timestamp_ms = (a.timestamp_ms as i64 + self.shift_s * 1000) as u64;
                a
            }))
    }

    /// The value the feed holds just before `open` (the prior close; see the module docs).
    pub async fn prior_close(&self, feed: &str, open: u64) -> VendorResult<Option<Aggregated>> {
        let mut t = grid_down(open.saturating_sub(1));
        for _ in 0..6 {
            if let Some(a) = self.agg(feed, t).await? {
                return Ok(Some(a));
            }
            t = t.saturating_sub(GRID_S);
        }
        Ok(None)
    }

    pub async fn open_print(
        &self,
        feed: &str,
        session: &Session,
    ) -> VendorResult<Option<Aggregated>> {
        let Some(prior) = self.prior_close(feed, session.open).await? else {
            return Ok(None);
        };
        let now = (self.now)();
        let mut series = Vec::new();
        let mut t = grid_up(session.open + OPEN_DELAY_S);
        while t <= (session.open + OPEN_SEARCH_S).min(now) {
            if let Some(a) = self.agg(feed, t).await? {
                let differs = a.value8 != prior.value8;
                series.push(a);
                if differs {
                    break;
                }
            }
            t += GRID_S;
        }
        Ok(derive_open(&series, session.open, prior.value8).cloned())
    }

    pub async fn close_print(
        &self,
        feed: &str,
        session: &Session,
    ) -> VendorResult<Option<Aggregated>> {
        // only once the window is over, so "the last package" is final
        if (self.now)() < session.close + CLOSE_WINDOW_S {
            return Ok(None);
        }
        let mut t = grid_down(session.close + CLOSE_WINDOW_S - 1);
        let mut series = Vec::new();
        while t + 5 * 60 >= session.close + CLOSE_WINDOW_S && t >= session.open {
            if let Some(a) = self.agg(feed, t).await? {
                series.push(a);
                break;
            }
            t -= GRID_S;
        }
        Ok(derive_close(&series, session.open, session.close).cloned())
    }

    fn print(a: Aggregated) -> OfficialPrint {
        OfficialPrint {
            price_wad: a.value_wad(),
            at: a.at(),
            source: PrintSource::OracleFirstRegular,
        }
    }
}

#[async_trait]
impl MarketDataVendor for RedStonePrints {
    fn name(&self) -> &'static str {
        self.inner.name()
    }

    async fn live(&self, asset: &Asset, since_ns: u64) -> VendorResult<LiveInput> {
        self.inner.live(asset, since_ns).await
    }

    async fn official_open(
        &self,
        asset: &Asset,
        session: &Session,
    ) -> VendorResult<Option<OfficialPrint>> {
        Ok(self
            .open_print(&asset.symbol, session)
            .await?
            .map(Self::print))
    }

    async fn official_close(
        &self,
        asset: &Asset,
        session: &Session,
    ) -> VendorResult<Option<OfficialPrint>> {
        Ok(self
            .close_print(&asset.symbol, session)
            .await?
            .map(Self::print))
    }

    async fn status(&self, asset: &Asset) -> VendorResult<StatusInput> {
        self.inner.status(asset).await
    }

    fn updates(&self) -> Option<tokio::sync::broadcast::Receiver<String>> {
        self.inner.updates()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn n(s: &str) -> serde_json::Number {
        serde_json::from_str(s).unwrap()
    }

    #[test]
    fn values_to_8_decimals_like_to_fixed() {
        assert_eq!(to_value8(&n("225.04013925")), Some(22_504_013_925));
        assert_eq!(to_value8(&n("341")), Some(34_100_000_000));
        assert_eq!(to_value8(&n("0.1")), Some(10_000_000));
        assert_eq!(to_value8(&n("-1.5")), None);
    }

    fn agg(at: u64, v: u128) -> Aggregated {
        Aggregated {
            value8: v,
            timestamp_ms: at * 1000,
            signers: vec![],
        }
    }

    #[test]
    fn open_skips_the_first_5_s_and_stale_values() {
        let open = 1_000_000;
        let s = [
            agg(open, 200),      // before open + 5 s
            agg(open + 10, 100), // still the prior close
            agg(open + 20, 101),
            agg(open + 30, 102),
        ];
        assert_eq!(derive_open(&s, open, 100).unwrap().at(), open + 20);
        assert_eq!(derive_open(&s[..2], open, 100), None);
        assert_eq!(derive_open(&s, open, 999).unwrap().at(), open + 10);
    }

    #[test]
    fn close_is_the_last_package_before_close_plus_60() {
        let (open, close) = (1_000_000, 1_023_400);
        let s = [
            agg(close - 10, 1),
            agg(close + 50, 2),
            agg(close + 60, 3),
            agg(close + 70, 4),
        ];
        assert_eq!(derive_close(&s, open, close).unwrap().value8, 2);
        assert_eq!(derive_close(&s[2..], open, close), None);
    }
}
