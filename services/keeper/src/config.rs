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
        let mut rpc_urls = vec![env::optional("RPC_URL")
            .or_else(|| env::optional("ARB_SEPOLIA_RPC_URL"))
            .context("RPC_URL")?];
        if let Some(f) = env::optional("RPC_URL_FALLBACK")
            .or_else(|| env::optional("ARB_SEPOLIA_RPC_URL_FALLBACK"))
        {
            rpc_urls.push(f);
        }
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
