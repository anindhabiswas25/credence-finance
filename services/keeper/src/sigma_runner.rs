//! J7 σ update on the chain (§10.2; the math is `sigma`, the planning and signing `sigma_job`):
//! daily, 30 min after the XNYS close, per listed asset:
//!
//! 1. resume from the calibration snapshot and apply every gap after its `asOf`, built from the
//!    on-chain OPEN/CLOSE prints the indexer holds (`price_point` kinds 1 and 2, feed A preferred);
//! 2. read the engine's current σ and its last update time (`IRiskEngine.sigmaAt`),
//!    and the oracle's `lastAsOfDay` per closure type;
//! 3. plan with the §5 publish rule (never below the engine's 10 %/day limit or the floor), have the
//!    committee sign, and `SigmaOracle.submit` each update (idempotency key `J7:<asset>:<type>:<day>`).
//!
//! Corporate actions: none are listed on testnet in S2, so split = 1 and dividend = 0 (an ops table
//! joins with the S4 NAV/corporate-action work).

use std::collections::{BTreeMap, BTreeSet};

use alloy::{
    primitives::{Address, Bytes, B256, U256},
    providers::DynProvider,
    signers::local::PrivateKeySigner,
    sol_types::SolCall,
};
use anyhow::{Context, Result};
use chrono::{DateTime, NaiveDate};
use credence_common::calendar::Calendar;
use serde_json::json;
use sqlx::{postgres::PgConnection, Row};

use crate::{
    core::abi::{IRiskEngine, ISigmaOracle},
    jobs::{self, Claim},
    sigma::{AssetSigma, Snapshot, TYPES},
    sigma_job::{
        build_gaps, domain, plan, sign_committee, wad_to_f64, OnChainSigma, SessionPrints,
    },
    tasks::{Keeper, TickReport},
};

/// J7 runs this long after the regular close (§10.2).
pub const AFTER_CLOSE_S: u64 = 30 * 60;

pub struct SigmaRunner {
    pub oracle: Address,
    pub engine: Address,
    pub chain_id: u64,
    pub snapshot: Snapshot,
    pub committee: Vec<PrivateKeySigner>,
    pub xnys: std::sync::Arc<Calendar>,
    pub indexer_schema: String,
}

pub fn utc_date(t: u64) -> NaiveDate {
    DateTime::from_timestamp(t as i64, 0)
        .expect("timestamp")
        .date_naive()
}

/// The last XNYS session whose close + 30 min has passed.
pub fn due_session(cal: &Calendar, now: u64) -> Option<&credence_common::calendar::Session> {
    cal.sessions
        .iter()
        .rev()
        .find(|s| s.close + AFTER_CLOSE_S <= now)
}

/// (current σ, time of the last accepted update, lastAsOfDay) per closure type. The update time is
/// the engine's own `sigmaAt` view (0 = never written).
pub async fn chain_state(
    p: &DynProvider,
    engine: Address,
    oracle: Address,
    asset: B256,
) -> Result<[OnChainSigma; 3]> {
    let e = IRiskEngine::new(engine, p);
    let o = ISigmaOracle::new(oracle, p);
    let mut out = [OnChainSigma::default(); 3];
    for t in TYPES {
        let i = t as usize - 1;
        out[i].current = e.sigma(asset, t).call().await?;
        out[i].last_as_of_day = if oracle == Address::ZERO {
            0
        } else {
            o.lastAsOfDay(asset, t).call().await?
        };
        let at = e.sigmaAt(asset, t).call().await?;
        out[i].sigma_at = (at != 0).then_some(at);
    }
    Ok(out)
}

impl SigmaRunner {
    /// OPEN/CLOSE prints per session date from the indexer (feed A, else B).
    pub async fn prints(
        &self,
        conn: &mut PgConnection,
        asset: B256,
        since: u64,
    ) -> Result<BTreeMap<NaiveDate, SessionPrints>> {
        let q = format!(
            "select kind, price::text as price, observed_at, feed from {}.price_point
              where asset_id = $1 and kind in (1, 2) and observed_at >= $2 order by feed desc, observed_at",
            self.indexer_schema
        );
        let rows = sqlx::query(sqlx::AssertSqlSafe(q))
            .bind(asset.to_string())
            .bind(since as i64)
            .fetch_all(&mut *conn)
            .await?;
        let mut m: BTreeMap<NaiveDate, SessionPrints> = BTreeMap::new();
        // `feed desc` puts B first, so A (read last) wins where both exist
        for r in rows {
            let kind: i32 = r.try_get("kind")?;
            let price: U256 = r.try_get::<String, _>("price")?.parse()?;
            let at: i64 = r.try_get("observed_at")?;
            let Some(s) = self
                .xnys
                .current_or_last_session(at as u64)
                .or_else(|| self.xnys.session_at(at as u64))
            else {
                // before calendar coverage: the print's own UTC date (09:30 and 16:00 ET are the same UTC date)
                let e = m.entry(utc_date(at as u64)).or_default();
                if kind == 1 {
                    e.open = Some(wad_to_f64(price))
                } else {
                    e.close = Some(wad_to_f64(price))
                }
                continue;
            };
            let e = m.entry(utc_date(s.open)).or_default();
            if kind == 1 {
                e.open = Some(wad_to_f64(price));
            } else {
                e.close = Some(wad_to_f64(price));
            }
        }
        Ok(m)
    }

    /// Session dates from `from` to `to`: the calendar's, plus print dates before its coverage.
    pub fn sessions(
        &self,
        prints: &BTreeMap<NaiveDate, SessionPrints>,
        from: NaiveDate,
        to: NaiveDate,
    ) -> Vec<NaiveDate> {
        let mut d: BTreeSet<NaiveDate> = self
            .xnys
            .sessions
            .iter()
            .map(|s| utc_date(s.open))
            .filter(|x| *x >= from && *x <= to)
            .collect();
        let cal_start = self.xnys.sessions.first().map(|s| utc_date(s.open));
        d.extend(
            prints
                .keys()
                .copied()
                .filter(|x| *x >= from && *x <= to && cal_start.is_none_or(|c| *x < c)),
        );
        d.insert(from);
        d.into_iter().collect()
    }
}

impl Keeper {
    pub(crate) async fn j7(&self, conn: &mut PgConnection, rep: &mut TickReport) -> Result<()> {
        let Some(r) = self.sigma.clone() else {
            return Ok(());
        };
        let now = self.clock.now();
        let Some(session) = due_session(&r.xnys, now) else {
            return Ok(());
        };
        let day = utc_date(session.open);
        let dom = domain(r.chain_id, r.oracle);
        let threshold = ISigmaOracle::new(r.oracle, self.rpc.primary())
            .threshold()
            .call()
            .await? as usize;
        for base in &r.snapshot.assets {
            let asset: B256 = base.asset_id.parse()?;
            let key = format!("J7:{asset}:{day}");
            if !matches!(
                jobs::claim(
                    conn,
                    &key,
                    "J7",
                    &json!({ "asset": base.symbol, "day": day.to_string() }),
                    &self.instance
                )
                .await?,
                Claim::Run { .. }
            ) {
                continue;
            }
            let res: Result<serde_json::Value> = async {
                let since = base.as_of.and_hms_opt(0, 0, 0).context("asOf")?.and_utc().timestamp() as u64;
                let prints = r.prints(conn, asset, since).await?;
                let sessions = r.sessions(&prints, base.as_of, day);
                let gaps = build_gaps(&sessions, &prints, None)?;
                let chain = chain_state(self.rpc.primary(), r.engine, r.oracle, asset).await?;
                let mut a: AssetSigma = base.clone();
                let planned = plan(&mut a, &gaps, &chain, day, now, now)?;
                let mut out = Vec::new();
                for pl in planned {
                    let sub_key = format!("J7:{asset}:{}:{}", pl.update.closureType, pl.update.asOfDay);
                    if !matches!(jobs::claim(conn, &sub_key, "J7", &json!({ "sigma": pl.update.sigma.to_string() }), &self.instance).await?, Claim::Run { .. }) {
                        continue;
                    }
                    let sigs = sign_committee(&pl.update, &dom, &r.committee, threshold).await?;
                    let u = &pl.update;
                    let abi_u = ISigmaOracle::SigmaUpdate { assetId: u.assetId, closureType: u.closureType, sigma: u.sigma, asOfDay: u.asOfDay, nonce: u.nonce };
                    let data = Bytes::from(ISigmaOracle::submitCall { u: abi_u, signatures: sigs }.abi_encode());
                    match self.tx.send(conn, &sub_key, r.oracle, data).await {
                        Ok(m) if m.success => jobs::mark(conn, &sub_key, "done", None).await?,
                        Ok(m) => {
                            rep.failed += 1;
                            jobs::mark(conn, &sub_key, "failed", Some(&format!("reverted in {}", m.hash))).await?
                        }
                        Err(e) => {
                            rep.failed += 1;
                            jobs::mark(conn, &sub_key, "failed", Some(&e.to_string())).await?
                        }
                    }
                    out.push(json!({ "type": pl.update.closureType, "sigma": pl.update.sigma.to_string(), "model": pl.model.to_string(), "floor": pl.floor.to_string(), "days": pl.days }));
                }
                Ok(json!({ "gaps": gaps.len(), "asOf": a.as_of.to_string(), "submitted": out }))
            }
            .await;
            match res {
                Ok(v) => {
                    jobs::set_payload(conn, &key, &v).await?;
                    jobs::mark(conn, &key, "done", None).await?;
                    tracing::info!(asset = %base.symbol, %day, result = %v, "J7 σ update");
                }
                Err(e) => {
                    jobs::mark(conn, &key, "failed", Some(&e.to_string())).await?;
                    tracing::warn!(asset = %base.symbol, error = %e, "J7 failed");
                }
            }
        }
        Ok(())
    }
}
