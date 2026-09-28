//! J7 σ methodology v1, exactly as `calibration/docs/sigma.md` (QE, ADR-0202) specifies.
//!
//! Every float operation is `f64`, evaluated left to right with the spec's parentheses, so the keeper
//! and the calibration pipeline agree bit for bit (`tests/sigma_vectors.rs` reproduces every vector).
//! The keeper never starts cold: it resumes from the calibration snapshot
//! (`calibration/out/sigma/sigma-<hash>.json`) and applies every gap after `state.asOf`.

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{bail, Context, Result};
use chrono::{Datelike, NaiveDate, Weekday};
use credence_risk_core::{elapsed_days, sigma_min_allowed, U256};
use serde::Deserialize;

pub const LAM: f64 = 0.94;
pub const W: f64 = 0.5;

pub const OVERNIGHT: u8 = 1;
pub const WEEKEND: u8 = 2;
pub const HOLIDAY_WEEKEND: u8 = 3;
pub const TYPES: [u8; 3] = [OVERNIGHT, WEEKEND, HOLIDAY_WEEKEND];

pub fn type_name(t: u8) -> &'static str {
    match t {
        OVERNIGHT => "OVERNIGHT",
        WEEKEND => "WEEKEND",
        HOLIDAY_WEEKEND => "HOLIDAY_WEEKEND",
        _ => "NONE",
    }
}

/// §2: `r = split * (open + dividend) / prevClose - 1.0`.
pub fn gap_return(prev_close: f64, open: f64, split: f64, dividend: f64) -> f64 {
    split * (open + dividend) / prev_close - 1.0
}

/// §1 closure type between two consecutive XNYS sessions: 1 if `session` is the next calendar day,
/// 2 if only Saturdays/Sundays lie in between, 3 if any weekday in between is closed.
/// Production code reads `closureTypeAfter` from the calendar; this is the same rule on dates.
pub fn classify(prev: NaiveDate, session: NaiveDate) -> Result<u8> {
    if session <= prev {
        bail!("session {session} is not after {prev}");
    }
    let mut d = prev.succ_opt().context("date overflow")?;
    if d == session {
        return Ok(OVERNIGHT);
    }
    while d < session {
        if !matches!(d.weekday(), Weekday::Sat | Weekday::Sun) {
            return Ok(HOLIDAY_WEEKEND);
        }
        d = d.succ_opt().context("date overflow")?;
    }
    Ok(WEEKEND)
}

/// §5 `toWad(x) = floor(x * 1e9 + 0.5) * 1e9`.
pub fn to_wad(x: f64) -> U256 {
    let n = (x * 1e9 + 0.5).floor();
    assert!(
        n >= 0.0 && n.is_finite(),
        "σ must be finite and ≥ 0, got {x}"
    );
    U256::from(n as u128) * U256::from(1_000_000_000u64)
}

/// Per-asset EWMA state (§3). `v[0..3]` = v[1..3]; `rho2[0..2]` = rho2[2], rho2[3].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SigmaState {
    pub v: [f64; 3],
    pub rho2: [f64; 2],
}

impl SigmaState {
    /// §3: a gap of type t updates only v[t].
    pub fn apply(&mut self, t: u8, r: f64) {
        let i = idx(t);
        self.v[i] = LAM * self.v[i] + (1.0 - LAM) * (r * r);
    }

    /// §4: σ before the floor.
    pub fn sigma(&self, t: u8) -> f64 {
        match t {
            OVERNIGHT => self.v[0].sqrt(),
            WEEKEND => (W * self.v[1] + ((1.0 - W) * self.rho2[0]) * self.v[0]).sqrt(),
            HOLIDAY_WEEKEND => (W * self.v[2] + ((1.0 - W) * self.rho2[1]) * self.v[0]).sqrt(),
            _ => panic!("closure type {t} has no σ"),
        }
    }

    pub fn model_wad(&self, t: u8) -> U256 {
        to_wad(self.sigma(t))
    }
}

fn idx(t: u8) -> usize {
    match t {
        OVERNIGHT => 0,
        WEEKEND => 1,
        HOLIDAY_WEEKEND => 2,
        _ => panic!("closure type {t} is not 1..=3"),
    }
}

/// §5 publish rule: `max(model, floor, sigma_min_allowed(cur, days))`; `max(model, floor)` if never set.
/// `days` is risk-core's `elapsed_days(sigmaAt, block.timestamp)`.
pub fn submit_wad(model: U256, floor: U256, current: U256, days: u64) -> Result<U256> {
    let base = model.max(floor);
    if current.is_zero() {
        return Ok(base);
    }
    let min_allowed = sigma_min_allowed(current, days)
        .map_err(|e| anyhow::anyhow!("sigma_min_allowed: {e:?}"))?;
    Ok(base.max(min_allowed))
}

/// `days` exactly as the engine computes it.
pub fn days_since(sigma_at: u64, now: u64) -> u64 {
    elapsed_days(sigma_at, now)
}

// ---------------------------------------------------------------- calibration snapshot (§7)

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotFile {
    kind: String,
    data_grade: String,
    end: String,
    assets: BTreeMap<String, SnapshotAsset>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotAsset {
    asset_id: String,
    floor_wad: BTreeMap<String, String>,
    sigma_wad: BTreeMap<String, String>,
    state: SnapshotState,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotState {
    as_of: String,
    rho2: BTreeMap<String, String>,
    v: BTreeMap<String, String>,
}

/// One listed asset's resume point.
#[derive(Debug, Clone)]
pub struct AssetSigma {
    pub symbol: String,
    pub asset_id: String,
    pub as_of: NaiveDate,
    pub state: SigmaState,
    /// Floors and the seeded (floored) σ, index = closure type − 1.
    pub floor_wad: [U256; 3],
    pub seed_wad: [U256; 3],
}

#[derive(Debug, Clone)]
pub struct Snapshot {
    pub data_grade: String,
    pub end: NaiveDate,
    pub assets: Vec<AssetSigma>,
}

fn f(s: &str) -> Result<f64> {
    s.parse::<f64>().with_context(|| format!("bad float {s:?}"))
}

fn wad(s: &str) -> Result<U256> {
    s.parse::<U256>().with_context(|| format!("bad WAD {s:?}"))
}

fn by_type(m: &BTreeMap<String, String>, what: &str) -> Result<[U256; 3]> {
    let get = |t: u8| -> Result<U256> {
        wad(m
            .get(type_name(t))
            .with_context(|| format!("{what}.{} missing", type_name(t)))?)
    };
    Ok([get(OVERNIGHT)?, get(WEEKEND)?, get(HOLIDAY_WEEKEND)?])
}

impl Snapshot {
    pub fn load(path: &Path) -> Result<Self> {
        let text =
            std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
        Self::parse(&text)
    }

    pub fn parse(text: &str) -> Result<Self> {
        let file: SnapshotFile = serde_json::from_str(text).context("σ snapshot JSON")?;
        if file.kind != "credence.sigma.v1" {
            bail!("unsupported σ snapshot kind {:?}", file.kind);
        }
        let mut assets = Vec::new();
        for (symbol, a) in file.assets {
            let key = |m: &BTreeMap<String, String>, k: &str| -> Result<f64> {
                f(m.get(k)
                    .with_context(|| format!("{symbol}: key {k} missing"))?)
            };
            let state = SigmaState {
                v: [
                    key(&a.state.v, "1")?,
                    key(&a.state.v, "2")?,
                    key(&a.state.v, "3")?,
                ],
                rho2: [key(&a.state.rho2, "2")?, key(&a.state.rho2, "3")?],
            };
            assets.push(AssetSigma {
                as_of: a
                    .state
                    .as_of
                    .parse()
                    .with_context(|| format!("{symbol}: asOf"))?,
                floor_wad: by_type(&a.floor_wad, "floorWad")?,
                seed_wad: by_type(&a.sigma_wad, "sigmaWad")?,
                asset_id: a.asset_id,
                symbol,
                state,
            });
        }
        Ok(Self {
            data_grade: file.data_grade,
            end: file.end.parse().context("end")?,
            assets,
        })
    }
}

/// One overnight/weekend/holiday gap as J7 learns it (at the official open of `session`).
#[derive(Debug, Clone, PartialEq)]
pub struct Gap {
    pub session: NaiveDate,
    pub closure_type: u8,
    pub r: f64,
}

impl AssetSigma {
    /// §6: apply every gap after `asOf`, in session order. Returns how many were applied.
    /// Gaps at or before `asOf` are already inside the snapshot and are ignored.
    pub fn resume(&mut self, gaps: &[Gap]) -> Result<usize> {
        let mut sorted: Vec<&Gap> = gaps.iter().filter(|g| g.session > self.as_of).collect();
        sorted.sort_by_key(|g| g.session);
        for w in sorted.windows(2) {
            if w[0].session == w[1].session {
                bail!("{}: two gaps into session {}", self.symbol, w[0].session);
            }
        }
        for g in &sorted {
            if !g.r.is_finite() {
                bail!("{}: non-finite gap return into {}", self.symbol, g.session);
            }
            self.state.apply(g.closure_type, g.r);
            self.as_of = g.session;
        }
        Ok(sorted.len())
    }

    /// σ to submit for type t given the engine's current σ and its age.
    pub fn submit(&self, t: u8, current: U256, days: u64) -> Result<U256> {
        submit_wad(
            self.state.model_wad(t),
            self.floor_wad[idx(t)],
            current,
            days,
        )
    }
}
