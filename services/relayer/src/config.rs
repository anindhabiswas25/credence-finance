//! Relayer configuration from env (§12.1 "relayer (per feed: A or B)").

use crate::{
    asset::Asset,
    metrics::Metrics,
    vendor::{
        alpaca::{Alpaca, AlpacaConfig},
        alpaca_ws::AlpacaStream,
        halts::{HaltFeed, NASDAQ_HALTS_URL},
        polygon::{Polygon, PolygonConfig},
        polygon_ws::PolygonStream,
        redstone,
        replay::Replay,
        stream::{run_stream, StreamCache, StreamOptions, StreamProtocol, Streaming},
        DynVendor,
    },
};
use anyhow::{bail, Context, Result};
use credence_common::{calendar::Calendar, env};
use std::{path::PathBuf, sync::Arc, time::Duration};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VendorKind {
    Polygon,
    Alpaca,
    Replay,
}

impl VendorKind {
    pub fn from_env() -> Result<Self> {
        Ok(match env::or("VENDOR", "replay").to_lowercase().as_str() {
            "polygon" | "massive" => Self::Polygon,
            "alpaca" => Self::Alpaca,
            "replay" => Self::Replay,
            other => bail!("VENDOR={other} is not supported (polygon | alpaca | replay)"),
        })
    }
}

/// Everything shared by node, aggregator and all-in-one modes.
pub struct Common {
    pub chain_id: u64,
    pub feed_id: String,
    pub assets: Vec<Asset>,
    pub vendor_kind: VendorKind,
}

impl Common {
    pub fn from_env() -> Result<Self> {
        let chain_id = env::chain_id()?;
        let assets = Asset::parse_list(&env::list("ASSETS")).context("ASSETS")?;
        let feed_id = env::or("FEED_ID", "A");
        if !matches!(feed_id.as_str(), "A" | "B") {
            bail!("FEED_ID must be A or B");
        }
        Ok(Self {
            chain_id,
            feed_id,
            assets,
            vendor_kind: VendorKind::from_env()?,
        })
    }
}

/// Calendar files: `CALENDAR_FILES` (comma list, merged) or the newest XNYS file under
/// `calibration/out/calendars/` found from the working directory upwards.
pub fn load_calendar() -> Result<Calendar> {
    let files: Vec<PathBuf> = match env::optional("CALENDAR_FILES") {
        Some(_) => env::list("CALENDAR_FILES")
            .into_iter()
            .map(PathBuf::from)
            .collect(),
        None => vec![find_default_calendar()?],
    };
    let mut cal: Option<Calendar> = None;
    for f in files {
        let c = Calendar::load(&f)?;
        cal = Some(match cal {
            None => c,
            Some(prev) => prev.merge(c)?,
        });
    }
    cal.context("no calendar")
}

fn find_default_calendar() -> Result<PathBuf> {
    let mut dir = std::env::current_dir()?;
    loop {
        let d = dir.join("calibration/out/calendars");
        if d.is_dir() {
            let mut xs: Vec<PathBuf> = std::fs::read_dir(&d)?
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| {
                    p.file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| n.starts_with("XNYS-") && n.ends_with(".json"))
                })
                .collect();
            xs.sort();
            return xs.pop().context(
                "no XNYS calendar in calibration/out/calendars (run `make calendar-gen`)",
            );
        }
        if !dir.pop() {
            bail!("calibration/out/calendars not found; set CALENDAR_FILES");
        }
    }
}

pub fn halt_feed() -> Arc<HaltFeed> {
    HaltFeed::new(env::or("NASDAQ_HALTS_URL", NASDAQ_HALTS_URL))
}

pub fn polygon_config() -> Result<PolygonConfig> {
    let api_key = env::optional("POLYGON_API_KEY")
        .or_else(|| env::optional("VENDOR_API_KEY"))
        .context("POLYGON_API_KEY (or VENDOR_API_KEY) is required for VENDOR=polygon")?;
    Ok(PolygonConfig {
        api_key,
        base_url: env::or("POLYGON_BASE_URL", "https://api.polygon.io"),
        max_rpm: env::parse_or("POLYGON_MAX_RPM", 5)?,
    })
}

pub fn alpaca_config() -> Result<AlpacaConfig> {
    let (key_id, secret) = match (env::optional("ALPACA_API_KEY_ID"), env::optional("ALPACA_API_SECRET_KEY")) {
        (Some(k), Some(s)) => (k, s),
        _ => match env::optional("VENDOR_API_KEY").and_then(|v| v.split_once(':').map(|(a, b)| (a.to_owned(), b.to_owned()))) {
            Some(p) => p,
            None => bail!("ALPACA_API_KEY_ID + ALPACA_API_SECRET_KEY (or VENDOR_API_KEY=<id>:<secret>) are required for VENDOR=alpaca"),
        },
    };
    Ok(AlpacaConfig {
        key_id,
        secret,
        feed: env::or("ALPACA_FEED", "iex"),
        data_url: env::or("ALPACA_DATA_URL", "https://data.alpaca.markets"),
        trading_url: env::or("ALPACA_TRADING_URL", "https://paper-api.alpaca.markets"),
        max_rpm: env::parse_or("ALPACA_MAX_RPM", 200)?,
    })
}

/// Put a WebSocket stream in front of a REST vendor (`RELAYER_STREAM=1`, the default) and start it.
fn with_stream(
    rest: DynVendor,
    proto: Arc<dyn StreamProtocol>,
    common: &Common,
    metrics: Option<Metrics>,
) -> Result<DynVendor> {
    let cache = StreamCache::new(proto.vendor());
    let symbols = common.assets.iter().map(|a| a.symbol.clone()).collect();
    tokio::spawn(run_stream(
        proto,
        symbols,
        cache.clone(),
        StreamOptions::default(),
        metrics,
    ));
    let ttl = Duration::from_millis(env::parse_or("RELAYER_STATUS_TTL_MS", 5_000)?);
    Ok(Arc::new(Streaming::new(rest, cache, ttl)))
}

fn plans(common: &Common) -> std::collections::HashMap<String, crate::asset::Plan> {
    common
        .assets
        .iter()
        .map(|a| (a.symbol.clone(), a.plan()))
        .collect()
}

/// Build the vendor and the calendar the node should use (a replay carries its own warped calendar).
/// `stream` = `Some(metrics)` starts the vendor WebSocket (unless `RELAYER_STREAM=0`); `None` is
/// REST only (smoke tests, recording).
pub async fn build_vendor(
    common: &Common,
    stream: Option<Metrics>,
) -> Result<(DynVendor, Arc<Calendar>)> {
    let (v, cal) = build_data_vendor(common, stream).await?;
    Ok((with_print_source(v, common.chain_id)?, cal))
}

/// `PRINT_SOURCE=vendor` (default): OPEN/CLOSE are the vendor's official auction prints (§10.1).
/// `PRINT_SOURCE=redstone` (ADR-0009 D1, testnet only): OPEN/CLOSE are derived from RedStone packages,
/// from the gateway's history, or from recordings (`REDSTONE_RECORDING=<file>[,<file>…]`, shifted by
/// `REDSTONE_SHIFT_S` onto the calendar in use). LIVE and STATUS stay with `VENDOR`.
pub fn with_print_source(inner: DynVendor, chain_id: u64) -> Result<DynVendor> {
    match env::or("PRINT_SOURCE", "vendor").to_lowercase().as_str() {
        "vendor" => Ok(inner),
        "redstone" => {
            if chain_id == 42_161 {
                bail!("PRINT_SOURCE=redstone is a testnet-only print source (ADR-0009 D1)");
            }
            let recordings = env::list("REDSTONE_RECORDING");
            let shift: i64 = env::parse_or("REDSTONE_SHIFT_S", 0)?;
            let source: Arc<dyn redstone::PackageSource> = if recordings.is_empty() {
                let urls = match env::list("REDSTONE_GATEWAYS") {
                    v if v.is_empty() => redstone::HISTORY_GATEWAYS
                        .iter()
                        .map(|s| s.to_string())
                        .collect(),
                    v => v,
                };
                Arc::new(redstone::Gateway::new(urls))
            } else {
                let paths: Vec<PathBuf> = recordings.iter().map(PathBuf::from).collect();
                let refs: Vec<&std::path::Path> = paths.iter().map(|p| p.as_path()).collect();
                Arc::new(redstone::Recorded::load(&refs, shift)?)
            };
            let mut v = redstone::RedStonePrints::new(inner, source);
            v.shift_s = shift;
            tracing::info!(
                recordings = recordings.len(),
                shift,
                "OPEN/CLOSE from RedStone packages (OracleFirstRegular)"
            );
            Ok(Arc::new(v))
        }
        other => bail!("PRINT_SOURCE={other} is not supported (vendor | redstone)"),
    }
}

async fn build_data_vendor(
    common: &Common,
    stream: Option<Metrics>,
) -> Result<(DynVendor, Arc<Calendar>)> {
    let stream = stream.filter(|_| env::or("RELAYER_STREAM", "1") != "0");
    match common.vendor_kind {
        VendorKind::Replay => {
            let path = PathBuf::from(env::required("REPLAY_FILE")?);
            let speed: f64 = env::parse_or("REPLAY_SPEED", 1.0)?;
            let offset: u64 = env::parse_or("REPLAY_START_OFFSET_S", 0)?;
            let r = Replay::load(&path, speed, common.chain_id, offset)?;
            let cal = Arc::new(r.calendar().clone());
            Ok((Arc::new(r), cal))
        }
        VendorKind::Polygon => {
            let halts = halt_feed();
            if let Err(e) = halts.refresh().await {
                tracing::warn!(error = %e, "halt feed: first refresh failed (halts unknown until it succeeds)");
            }
            tokio::spawn(halts.clone().run(Duration::from_secs(10)));
            let cfg = polygon_config()?;
            let p = Polygon::new(cfg.clone(), halts);
            match p.load_conditions().await {
                Ok(n) => tracing::info!(n, "polygon condition table loaded"),
                Err(e) => {
                    tracing::warn!(error = %e, "polygon conditions: using the built-in table")
                }
            }
            let conditions = p.conditions_snapshot().await;
            let mut v: DynVendor = Arc::new(p);
            if let Some(m) = stream {
                let proto = PolygonStream {
                    url: env::or("POLYGON_WS_URL", "wss://socket.polygon.io/stocks"),
                    api_key: cfg.api_key,
                    conditions,
                    plans: plans(common),
                };
                v = with_stream(v, Arc::new(proto), common, Some(m))?;
            }
            Ok((v, Arc::new(load_calendar()?)))
        }
        VendorKind::Alpaca => {
            let halts = halt_feed();
            if let Err(e) = halts.refresh().await {
                tracing::warn!(error = %e, "halt feed: first refresh failed (halts unknown until it succeeds)");
            }
            tokio::spawn(halts.clone().run(Duration::from_secs(10)));
            let cfg = alpaca_config()?;
            let mut v: DynVendor = Arc::new(Alpaca::new(cfg.clone(), halts));
            if let Some(m) = stream {
                let proto = AlpacaStream::new(
                    &env::or("ALPACA_STREAM_URL", "wss://stream.data.alpaca.markets/v2"),
                    &cfg.feed,
                    cfg.key_id,
                    cfg.secret,
                    plans(common),
                );
                v = with_stream(v, Arc::new(proto), common, Some(m))?;
            }
            Ok((v, Arc::new(load_calendar()?)))
        }
    }
}
