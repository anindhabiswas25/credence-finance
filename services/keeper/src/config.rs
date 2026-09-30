//! Keeper configuration from env (§12.1 "keeper").

use crate::schedule::Tracked;
use alloy::primitives::{keccak256, Address};
use anyhow::{bail, Context, Result};
use credence_common::{calendar::Calendar, env};
use std::{collections::HashMap, path::PathBuf, sync::Arc};

pub struct Config {
    pub chain_id: u64,
    pub instance: String,
    pub database_url: String,
    pub rpc_urls: Vec<String>,
    pub clock: Address,
    /// `shared.riskEngine` (Stylus) for J12, if deployed.
    pub risk_engine: Option<Address>,
    pub assets: Vec<Tracked>,
    pub alert_webhook: Option<String>,
    /// (label, address) of wallets whose balance J12 watches; the keeper's own sender is added.
    pub watch_wallets: Vec<(String, Address)>,
    pub min_balance_wei: u128,
    pub lookback_s: u64,
}

/// Venue calendar for a listing MIC: all US equity listings share XNYS sessions; funds use USBANK.
pub fn venue_for(mic: &str) -> Result<&'static str> {
    Ok(match mic {
        "XNAS" | "XNYS" | "ARCX" | "XASE" | "BATS" => "XNYS",
        "USBANK" => "USBANK",
        _ => bail!("no venue calendar for {mic}"),
    })
}

/// The address book (`DEPLOYMENTS_FILE`, else `deployments/<chainId>.local.json`, else `<chainId>.json`).
pub fn address_book(chain_id: u64) -> Result<serde_json::Value> {
    let path = match env::optional("DEPLOYMENTS_FILE") {
        Some(p) => PathBuf::from(p),
        None => {
            let local = PathBuf::from(format!("deployments/{chain_id}.local.json"));
            if local.exists() {
                local
            } else {
                PathBuf::from(format!("deployments/{chain_id}.json"))
            }
        }
    };
    serde_json::from_str(
        &std::fs::read_to_string(&path).with_context(|| format!("{}", path.display()))?,
    )
    .with_context(|| format!("{}", path.display()))
}

/// `env_key` if set, else the book entry at `pointer` (§13.2 shape, e.g. `/shared/clock`).
pub fn book_address(chain_id: u64, env_key: &str, pointer: &str) -> Result<Option<Address>> {
    if let Some(a) = env::optional(env_key) {
        return Ok(Some(a.parse().with_context(|| env_key.to_owned())?));
    }
    let v = address_book(chain_id)?;
    v.pointer(pointer)
        .and_then(|x| x.as_str())
        .map(|s| s.parse().with_context(|| pointer.to_owned()))
        .transpose()
}

/// `CLOCK_ADDRESS`, else `shared.clock` (§13.2) from the address book.
pub fn clock_address(chain_id: u64) -> Result<Address> {
    book_address(chain_id, "CLOCK_ADDRESS", "/shared/clock")?
        .context("no clock address in the address book")
}

/// Lending-core jobs from the address book (`equity`/`nav` markets and vaults, `shared.registry`), or
/// `None` before a core stack is deployed or with `KEEPER_CORE=0`.
pub fn core_jobs(chain_id: u64) -> Result<Option<crate::core_jobs::CoreJobs>> {
    if env::or("KEEPER_CORE", "1") == "0" {
        return Ok(None);
    }
    let Ok(book) = address_book(chain_id) else {
        return Ok(None);
    };
    let (markets, vaults) = crate::core_jobs::from_book(&book);
    if markets.is_empty() {
        return Ok(None);
    }
    let mut c =
        crate::core_jobs::CoreJobs::new(markets, vaults, env::or("INDEXER_SCHEMA", "indexer"));
    c.j3_live = env::or("KEEPER_J3_LIVE", "0") == "1";
    c.j4_live = env::or("KEEPER_J4_LIVE", "0") == "1";
    c.j3_batch = env::parse_or("KEEPER_J3_BATCH", crate::core_jobs::BELL_BATCH)?;
    c.flag_batch = env::parse_or("KEEPER_FLAG_BATCH", crate::core_jobs::FLAG_BATCH)?;
    c.settle_batch = env::parse_or("KEEPER_SETTLE_BATCH", crate::auction_jobs::SETTLE_BATCH)?;
    if env::or("KEEPER_AUCTIONS", "1") == "1" {
        c.auction_stacks = crate::core_jobs::auction_stacks(&book);
    }
    if env::or("KEEPER_NAV", "1") == "1" {
        c.nav = crate::nav_jobs::NavStack::from_book(&book);
    }
    c.from_block = book.get("startBlock").and_then(|v| v.as_u64()).unwrap_or(0);
    // testnet self-service allowlist: never on Arbitrum One
    if chain_id != 42_161 {
        c.registry = book
            .pointer("/shared/registry")
            .and_then(|v| v.as_str())
            .and_then(|v| v.parse().ok());
    }
    Ok(Some(c))
}

/// J7 from env and the address book: `SIGMA_ORACLE_ADDRESS` (else `shared.sigmaOracle`), the engine,
/// `SIGMA_SNAPSHOT` (else the newest `calibration/out/sigma/sigma-*.json`) and the committee keys
/// `SIGMA_COMMITTEE_KEYS` (comma-separated; KMS signers replace them before testnet). `None` if any is
/// missing: J7 then stays off and says why.
pub fn sigma_runner(
    chain_id: u64,
    calendars: &HashMap<String, Arc<Calendar>>,
) -> Result<Option<crate::sigma_runner::SigmaRunner>> {
    let why = |m: &str| {
        tracing::info!(reason = m, "J7 disabled");
        Ok(None)
    };
    let Some(oracle) = book_address(chain_id, "SIGMA_ORACLE_ADDRESS", "/shared/sigmaOracle")
        .ok()
        .flatten()
    else {
        return why("no sigmaOracle in the address book");
    };
    let Some(engine) = risk_engine_address(chain_id)? else {
        return why("no riskEngine in the address book");
    };
    let keys = env::list("SIGMA_COMMITTEE_KEYS");
    if keys.is_empty() {
        return why("SIGMA_COMMITTEE_KEYS not set");
    }
    let committee = keys
        .iter()
        .map(|k| {
            k.parse::<alloy::signers::local::PrivateKeySigner>()
                .context("SIGMA_COMMITTEE_KEYS")
        })
        .collect::<Result<Vec<_>>>()?;
    let snap_path = match env::optional("SIGMA_SNAPSHOT") {
        Some(p) => PathBuf::from(p),
        None => {
            let mut files: Vec<PathBuf> = std::fs::read_dir("calibration/out/sigma")?
                .flatten()
                .map(|e| e.path())
                .filter(|p| {
                    p.file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| n.starts_with("sigma-") && n.ends_with(".json"))
                })
                .collect();
            files.sort_by_key(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok());
            files
                .pop()
                .context("no calibration/out/sigma/sigma-*.json")?
        }
    };
    let snapshot = crate::sigma::Snapshot::load(&snap_path)?;
    let xnys = calendars.get("XNYS").cloned().context("XNYS calendar")?;
    tracing::info!(snapshot = %snap_path.display(), grade = %snapshot.data_grade, assets = snapshot.assets.len(), committee = committee.len(), "J7 enabled");
    Ok(Some(crate::sigma_runner::SigmaRunner {
        oracle,
        engine,
        chain_id,
        snapshot,
        committee,
        xnys,
        indexer_schema: env::or("INDEXER_SCHEMA", "indexer"),
    }))
}

/// `RISK_ENGINE_ADDRESS`, else `shared.riskEngine`; `None` before the engine is deployed.
pub fn risk_engine_address(chain_id: u64) -> Result<Option<Address>> {
    match book_address(chain_id, "RISK_ENGINE_ADDRESS", "/shared/riskEngine") {
        Ok(a) => Ok(a),
        Err(e) if env::optional("CLOCK_ADDRESS").is_some() => {
            tracing::debug!(error = %e, "no address book: J12 watches no Stylus program");
            Ok(None)
        }
        Err(e) => Err(e),
    }
}

pub fn load_calendars() -> Result<HashMap<String, Arc<Calendar>>> {
    let files: Vec<PathBuf> = match env::optional("CALENDAR_FILES") {
        Some(_) => env::list("CALENDAR_FILES")
            .into_iter()
            .map(PathBuf::from)
            .collect(),
        None => vec![
            credence_common::calendar::find_latest("XNYS")?,
            credence_common::calendar::find_latest("USBANK")?,
        ],
    };
    let mut m: HashMap<String, Calendar> = HashMap::new();
    for f in files {
        let c = Calendar::load(&f)?;
        let merged = match m.remove(&c.venue) {
            Some(prev) => prev.merge(c)?,
            None => c,
        };
        m.insert(merged.venue.clone(), merged);
    }
    Ok(m.into_iter().map(|(k, v)| (k, Arc::new(v))).collect())
}

pub fn tracked(
    specs: &[String],
    calendars: &HashMap<String, Arc<Calendar>>,
) -> Result<Vec<Tracked>> {
    specs
        .iter()
        .map(|s| {
            let (t, mic) = s
                .split_once(':')
                .with_context(|| format!("asset {s} must be TICKER:MIC"))?;
            let (t, mic) = (t.trim().to_uppercase(), mic.trim().to_uppercase());
            let venue = venue_for(&mic)?;
            let calendar = calendars
                .get(venue)
                .cloned()
                .with_context(|| format!("no {venue} calendar loaded"))?;
            Ok(Tracked {
                id: keccak256(format!("{t}:{mic}")),
                label: format!("{t}:{mic}"),
                venue: venue.into(),
                calendar,
            })
        })
        .collect()
}

impl Config {
    pub fn from_env() -> Result<Self> {
        let chain_id = env::chain_id()?;
        let calendars = load_calendars()?;
        let mut specs = env::list("KEEPER_ASSETS");
        if specs.is_empty() {
            specs = env::list("ASSETS");
            specs.push("TBILL:USBANK".into());
        }
        let assets = tracked(&specs, &calendars)?;
        let rpc_urls = env::rpc_urls()?;
        let watch_wallets = env::list("WATCH_WALLETS")
            .into_iter()
            .map(|w| {
                let (label, addr) = w.split_once('=').unwrap_or(("wallet", w.as_str()));
                Ok((
                    label.to_owned(),
                    addr.parse::<Address>()
                        .with_context(|| format!("WATCH_WALLETS {w}"))?,
                ))
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Self {
            chain_id,
            instance: env::or("KEEPER_INSTANCE_ID", "keeper-local-1"),
            database_url: env::required("DATABASE_URL")?,
            rpc_urls,
            clock: clock_address(chain_id)?,
            risk_engine: risk_engine_address(chain_id)?,
            assets,
            alert_webhook: env::optional("ALERT_WEBHOOK_URL"),
            watch_wallets,
            min_balance_wei: env::parse_or("KEEPER_MIN_BALANCE_WEI", 50_000_000_000_000_000u128)?,
            lookback_s: env::parse_or("KEEPER_LOOKBACK_S", 900)?,
        })
    }
}
