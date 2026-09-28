//! Lending-core jobs (§10.2), run by the leader after J1/J12 when a core stack is configured:
//!
//! * **J2 Bell heads-up**: at T−26 h and T−2 h before the next close, if that closure is *binding*
//!   (safe LTV < effective max LTV), compute the Bell for every borrower natively (risk-core, at the engine's safe LTV) and enqueue a
//!   `bell_headsup` notification with exact amounts (dedupe `J2:<market>:<closure>:<borrower>:<stage>`).
//! * **J3 enforceBell** (dry-run unless `KEEPER_J3_LIVE=1`): from `bellAt` to the close, the NEEDS_ACTION
//!   borrowers in batches of ≤ 50 with each one's expected `BellOutcome` (CoverLogic._cure's branches).
//! * **J4 health watcher** (dry-run unless `KEEPER_J4_LIVE=1`): REGULAR HF < 1, EXTENDED uncovered
//!   HF < 0.92 → `flagForAuction`.
//! * **J8** (hourly): `claimFees` where fees are accrued, `SeniorVault.processQueue` where requests are queued.
//! * **Allowlist** (testnet only): `ComplianceRegistry.setAllowedBatch` for `app.allowlist_request`.
//!
//! Dry-run jobs record their plan in `ops.keeper_job.payload`, so an e2e can compare it with risk-cli.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use alloy::{
    primitives::{Address, Bytes, B256, U256},
    sol_types::SolCall,
};
use anyhow::{Context, Result};
use serde_json::json;
use sqlx::{postgres::PgConnection, Row};

use crate::{
    core::{
        abi, bell, bell_at, expected_outcome, health, preclose_qty, preview_cover, project,
        read_ctx, read_position, safe_ltv_for, targets, RiskCtx, Target, EXTENDED, NEEDS_ACTION,
        PRECLOSE_SALE, PRECLOSE_THEN_COVER, REGULAR,
    },
    jobs::{self, Claim},
    tasks::{Keeper, TickReport},
    txjob::TxJob,
};

pub const HEADSUP_EARLY_S: u64 = 26 * 3600;
pub const HEADSUP_LATE_S: u64 = 2 * 3600;
/// J3: BE-chain 04:40 (devnode, real pool): 10 auto-covers ≈ 22.9M gas, 11 ≈ 25.1M > 24M.
pub const BELL_BATCH: usize = 10;
/// Flag batches: a lot holds at most 128 positions (~90k gas each).
pub const FLAG_BATCH: usize = 128;
/// J3 pages ops if NEEDS_ACTION positions remain this long after bellAt (§10.2).
pub const BELL_PAGE_AFTER_S: u64 = 10 * 60;
/// 0.92 (§10.2 J4, EXTENDED uncovered).
pub const EXTENDED_HF_FLOOR: u128 = 920_000_000_000_000_000;
const WAD: u128 = 1_000_000_000_000_000_000;

#[derive(Clone, Debug)]
pub struct CoreMarket {
    /// Ticker, e.g. "NVDA" (notification copy).
    pub asset: String,
    /// Collateral token symbol, e.g. "tNVDA".
    pub token: String,
    pub market: Address,
    pub id: B256,
}

pub struct CoreJobs {
    pub markets: Vec<CoreMarket>,
    /// (stack, vault)
    pub vaults: Vec<(String, Address)>,
    /// Ponder's views schema (`indexer`).
    pub indexer_schema: String,
    pub j3_live: bool,
    pub j4_live: bool,
    pub registry: Option<Address>,
    pub j4_every_s: u64,
    /// J3 batch size: BE-chain's largest `enforceBell` batch within 24M gas (all auto-covered).
    pub j3_batch: usize,
    /// J5 flag / settlement batch sizes.
    pub flag_batch: usize,
    pub settle_batch: usize,
    /// Auction houses to drive (J5 / J6), and what the keeper has seen of them.
    pub auction_stacks: Vec<crate::auction_jobs::AuctionStack>,
    pub auctions: Mutex<crate::auction_jobs::AuctionBook>,
    /// First block to scan for auctions (the address book's startBlock).
    pub from_block: u64,
    last_j4: Mutex<HashMap<B256, u64>>,
}

impl CoreJobs {
    pub fn new(
        markets: Vec<CoreMarket>,
        vaults: Vec<(String, Address)>,
        indexer_schema: String,
    ) -> Self {
        assert!(
            !indexer_schema.is_empty()
                && indexer_schema
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_'),
            "INDEXER_SCHEMA must be a plain identifier"
        );
        Self {
            markets,
            vaults,
            indexer_schema,
            j3_live: false,
            j4_live: false,
            registry: None,
            j4_every_s: 10,
            j3_batch: BELL_BATCH,
            flag_batch: FLAG_BATCH,
            settle_batch: crate::auction_jobs::SETTLE_BATCH,
            auction_stacks: Vec::new(),
            auctions: Mutex::new(Default::default()),
            from_block: 0,
            last_j4: Mutex::new(HashMap::new()),
        }
    }
}

/// Which heads-up stage is due for a close at `close_at` (and a Bell deadline `bell_at`), if any.
pub fn headsup_stage(now: u64, close_at: u64, bell_at: u64) -> Option<&'static str> {
    if close_at <= now {
        return None;
    }
    if now + HEADSUP_LATE_S >= close_at {
        return (now < bell_at).then_some("T-2h");
    }
    (now + HEADSUP_EARLY_S >= close_at).then_some("T-26h")
}

/// Short content key of a batch of borrowers (order-independent).
pub fn batch_hash(borrowers: &[Address]) -> String {
    let mut v = borrowers.to_vec();
    v.sort();
    let h = alloy::primitives::keccak256(v.concat());
    alloy::hex::encode(&h[..8])
}

fn s(v: U256) -> String {
    v.to_string()
}

impl Keeper {
    pub(crate) async fn core_tick(
        &self,
        conn: &mut PgConnection,
        rep: &mut TickReport,
    ) -> Result<()> {
        let Some(core) = self.core.clone() else {
            return Ok(());
        };
        let now = self.clock.now();
        for m in &core.markets {
            let ctx = match read_ctx(self.rpc.primary(), m.market, m.id, None).await {
                Ok(c) => c,
                Err(e) => {
                    tracing::warn!(market = %m.id, error = %e, "core: market read failed");
                    continue;
                }
            };
            for (name, r) in [
                ("J2", self.j2(conn, &core, m, &ctx, now).await),
                ("J3", self.j3(conn, &core, m, &ctx, now, rep).await),
                ("J4", self.j4(conn, &core, m, &ctx, now, rep).await),
                ("J5", self.j5_flag(conn, &core, m, &ctx, rep).await),
                (
                    "J5",
                    self.j5_complete_reopen(conn, &core, &m.asset, &ctx, rep)
                        .await,
                ),
            ] {
                if let Err(e) = r {
                    tracing::warn!(job = name, market = %m.id, error = %e, "core job failed");
                    self.metrics.jobs.with_label_values(&[name, "error"]).inc();
                }
            }
        }
        if let Err(e) = self.auctions_tick(conn, &core, rep).await {
            tracing::warn!(error = %e, "auction driver failed");
        }
        if let Err(e) = self.pools_tick(conn, &core, rep).await {
            tracing::warn!(error = %e, "pool lifecycle failed");
        }
        if let Err(e) = self.j8(conn, &core, now).await {
            tracing::warn!(error = %e, "J8 failed");
        }
        if let Err(e) = self.allowlist(conn, &core, now).await {
            tracing::warn!(error = %e, "allowlist failed");
        }
        Ok(())
    }

    /// Borrowers with debt in a market, from the indexer.
    pub(crate) async fn borrowers(
        &self,
        conn: &mut PgConnection,
        core: &CoreJobs,
        id: B256,
    ) -> Result<Vec<Address>> {
        // the schema is an identifier checked in CoreJobs::new; the market id is bound
        let q = format!("select owner from {}.position where market_id = $1 and borrow_shares > 0 order by owner", core.indexer_schema);
        let rows = sqlx::query(sqlx::AssertSqlSafe(q))
            .bind(id.to_string())
            .fetch_all(&mut *conn)
            .await?;
        rows.iter()
            .map(|r| {
                r.try_get::<String, _>("owner")?
                    .parse::<Address>()
                    .context("owner")
            })
            .collect()
    }

    async fn j2(
        &self,
        conn: &mut PgConnection,
        core: &CoreJobs,
        m: &CoreMarket,
        ctx: &RiskCtx,
        now: u64,
    ) -> Result<()> {
        tracing::debug!(asset = %m.asset, state = ctx.clock_state, block = ctx.block, now, "J2 check");
        if ctx.clock_state != REGULAR {
            return Ok(());
        }
        // the venue calendar of this asset (the clock's own schedule): the next two closes
        let Some(cal) = self
            .assets
            .iter()
            .find(|a| a.id == ctx.asset_id)
            .map(|a| a.calendar.clone())
        else {
            return Ok(());
        };
        for t in targets(&cal, now) {
            let Some(stage) = headsup_stage(now, t.close_at, t.bell_at) else {
                continue;
            };
            tracing::debug!(asset = %m.asset, close = t.close_at, closure_type = t.closure_type, stage, "J2 target");
            if let Err(e) = self.j2_target(conn, core, m, ctx, &t, stage).await {
                tracing::warn!(asset = %m.asset, close = t.close_at, error = %e, "J2 failed");
                self.metrics.jobs.with_label_values(&["J2", "error"]).inc();
            }
        }
        Ok(())
    }

    /// J2 for one closure ahead: binding check at that closure's type, then one heads-up per
    /// NEEDS_ACTION borrower with the debt projected over that closure's days (R-08).
    async fn j2_target(
        &self,
        conn: &mut PgConnection,
        core: &CoreJobs,
        m: &CoreMarket,
        ctx: &RiskCtx,
        t: &Target,
        stage: &str,
    ) -> Result<()> {
        let closure_id = ctx.upcoming_closure_id + t.offset;
        let key = format!("J2:{}:{closure_id}:{stage}", m.id);
        let claim = jobs::claim(
            conn,
            &key,
            "J2",
            &json!({ "asset": m.asset, "closeAt": t.close_at, "closureType": t.closure_type }),
            &self.instance,
        )
        .await?;
        if !matches!(claim, Claim::Run { .. }) {
            return Ok(());
        }
        let Some(safe) = safe_ltv_for(self.rpc.primary(), ctx, t.closure_type).await else {
            jobs::mark(
                conn,
                &key,
                "failed",
                Some(&format!(
                    "engine has no set for {} type {}",
                    ctx.asset_id, t.closure_type
                )),
            )
            .await?;
            return Ok(());
        };
        if safe >= ctx.max_ltv_eff {
            jobs::set_payload(conn, &key, &json!({ "binding": false, "safeLtv": s(safe) })).await?;
            jobs::mark(conn, &key, "done", None).await?;
            return Ok(());
        }
        let mut sent = 0usize;
        for owner in self.borrowers(conn, core, m.id).await? {
            let (mut p, debt) = read_position(self.rpc.primary(), ctx, owner).await?;
            if p.covered && t.offset == 0 {
                continue;
            }
            p.covered = false;
            p.debt_projected = project(debt, ctx.borrow_rate, t.days)?;
            let b = bell_at(ctx, &p, safe)?;
            if b.status != NEEDS_ACTION {
                continue;
            }
            let ltv_now =
                credence_risk_core::fixed::ltv_up(debt, p.collateral_value).unwrap_or(U256::MAX);
            let outcome = expected_outcome(ctx, &p, ltv_now);
            let (prem, unavailable) = if ctx.cover_paused {
                (None, Some("Gap Cover is paused for this market"))
            } else {
                // the pool's own quote for this closure: what the borrower would actually be charged
                (
                    Some(preview_cover(self.rpc.primary(), ctx, &p, Some(t)).await?.0),
                    None,
                )
            };
            let default = match outcome {
                o if o == PRECLOSE_SALE || prem.is_none() => {
                    json!({ "kind": "precloseSale", "saleQty": s(preclose_qty(ctx, &p, b.safe_ltv)?) })
                }
                o if o == PRECLOSE_THEN_COVER => {
                    json!({ "kind": "autoCoverAfterSale", "saleQty": s(preclose_qty(ctx, &p, ctx.max_ltv_eff)?) })
                }
                _ => json!({ "kind": "autoCover" }),
            };
            let mut payload = json!({
                "marketId": m.id.to_string(),
                "asset": m.asset,
                "token": m.token,
                "closureId": closure_id.to_string(),
                "closureType": t.closure_type,
                "stage": stage,
                "bellAt": t.bell_at,
                "ltv": s(b.ltv),
                "safeLtv": s(b.safe_ltv),
                "cureRepay": s(b.cure_repay),
                "cureCollateral": s(b.cure_collateral),
                "premium": prem.map(s),
                "default": default,
                "loanDecimals": ctx.loan_dec,
                "collateralDecimals": ctx.coll_dec,
                "expiresAt": t.bell_at,
            });
            if let Some(u) = unavailable {
                payload["coverUnavailable"] = json!(u);
            }
            let dedupe = format!("J2:{}:{closure_id}:{owner:#x}:{stage}", m.id);
            let inserted = sqlx::query(
                "insert into app.notification_job (dedupe_key, address, event, payload) values ($1, $2, 'bell_headsup', $3)
                 on conflict (dedupe_key) do nothing",
            )
            .bind(&dedupe)
            .bind(owner.as_slice())
            .bind(&payload)
            .execute(&mut *conn)
            .await?
            .rows_affected();
            sent += inserted as usize;
        }
        jobs::set_payload(
            conn,
            &key,
            &json!({ "binding": true, "safeLtv": s(safe), "enqueued": sent, "block": ctx.block }),
        )
        .await?;
        jobs::mark(conn, &key, "done", None).await?;
        self.metrics.jobs.with_label_values(&["J2", "done"]).inc();
        tracing::info!(asset = %m.asset, stage, closure = closure_id, enqueued = sent, "J2 Bell heads-up");
        Ok(())
    }

    async fn j3(
        &self,
        conn: &mut PgConnection,
        core: &CoreJobs,
        m: &CoreMarket,
        ctx: &RiskCtx,
        now: u64,
        rep: &mut TickReport,
    ) -> Result<()> {
        if ctx.clock_state != REGULAR
            || ctx.bell_at == 0
            || now < ctx.bell_at
            || now >= ctx.close_at
        {
            return Ok(());
        }
        if ctx.safe_ltv.is_some() && core.j3_live {
            return self.j3_live(conn, core, m, ctx, now, rep).await;
        }
        let key = format!("J3:{}:{}", m.id, ctx.upcoming_closure_id);
        if !matches!(
            jobs::claim(
                conn,
                &key,
                "J3",
                &json!({ "asset": m.asset, "live": core.j3_live }),
                &self.instance
            )
            .await?,
            Claim::Run { .. }
        ) {
            return Ok(());
        }
        if ctx.safe_ltv.is_none() {
            jobs::mark(
                conn,
                &key,
                "failed",
                Some("engine has no set for this closure"),
            )
            .await?;
            return Ok(());
        }
        let plan = self.j3_plan(conn, core, m, ctx).await?;
        let batches: Vec<Vec<Address>> = plan
            .chunks(core.j3_batch)
            .map(|c| c.iter().map(|x| x.0).collect())
            .collect();
        let body = json!({
            "block": ctx.block,
            "calls": batches.iter().map(|b| json!({ "fn": "enforceBell", "id": m.id.to_string(), "borrowers": b })).collect::<Vec<_>>(),
            "expected": plan.iter().map(|(o, outcome, b)| json!({ "borrower": o, "outcome": outcome, "cureRepay": s(b.cure_repay), "safeLtv": s(b.safe_ltv) })).collect::<Vec<_>>(),
        });
        jobs::set_payload(conn, &key, &json!({ "plan": body })).await?;
        tracing::info!(asset = %m.asset, closure = ctx.upcoming_closure_id, borrowers = plan.len(), plan = %body, "J3 enforceBell (dry-run)");
        jobs::mark(conn, &key, "done", None).await?;
        self.metrics
            .jobs
            .with_label_values(&["J3", "dry_run"])
            .inc();
        Ok(())
    }

    /// J3 live: every tick in [bellAt, close) until no NEEDS_ACTION position is left. Batches are keyed
    /// by their borrowers (`J3:<market>:<closure>:<hash>`), so a restart that re-plans never skips a
    /// borrower or re-sends a batch; batches a previous run left `submitted` are reconciled first.
    async fn j3_live(
        &self,
        conn: &mut PgConnection,
        core: &CoreJobs,
        m: &CoreMarket,
        ctx: &RiskCtx,
        now: u64,
        rep: &mut TickReport,
    ) -> Result<()> {
        let prefix = format!("J3:{}:{}", m.id, ctx.upcoming_closure_id);
        let pending: Vec<String> = sqlx::query_scalar(
            "select key from ops.keeper_job where key like $1 and status = 'submitted'",
        )
        .bind(format!("{prefix}:%"))
        .fetch_all(&mut *conn)
        .await?;
        for k in &pending {
            if self.reconcile_key(conn, k, rep).await? == TxJob::Pending {
                return Ok(()); // wait for it before re-planning
            }
        }
        let plan = self.j3_plan(conn, core, m, ctx).await?;
        if plan.is_empty() {
            return Ok(());
        }
        if now >= ctx.bell_at + BELL_PAGE_AFTER_S {
            let k = format!("{prefix}:page");
            if !jobs::exists(conn, &k).await? {
                jobs::mark_covered(conn, &[k], "J3", "page", &self.instance).await?;
                self.page(
                    "J3",
                    format!(
                        "{} NEEDS_ACTION position(s) left in {} at bellAt + 10 min",
                        plan.len(),
                        m.asset
                    ),
                    rep,
                )
                .await;
            }
        }
        for batch in plan.chunks(core.j3_batch) {
            let borrowers: Vec<Address> = batch.iter().map(|x| x.0).collect();
            let k = format!("{prefix}:{}", batch_hash(&borrowers));
            let r = self
                .tx_job(
                    conn,
                    &k,
                    &json!({ "borrowers": borrowers, "block": ctx.block }),
                    m.market,
                    || {
                        Ok(Bytes::from(
                            abi::ICredenceMarket::enforceBellCall {
                                id: m.id,
                                borrowers: borrowers.clone(),
                            }
                            .abi_encode(),
                        ))
                    },
                    rep,
                )
                .await?;
            tracing::info!(asset = %m.asset, closure = ctx.upcoming_closure_id, n = borrowers.len(), result = ?r, "J3 enforceBell");
        }
        Ok(())
    }

    /// NEEDS_ACTION borrowers not yet enforced for the upcoming closure, with their expected outcomes.
    async fn j3_plan(
        &self,
        conn: &mut PgConnection,
        core: &CoreJobs,
        m: &CoreMarket,
        ctx: &RiskCtx,
    ) -> Result<Vec<(Address, u8, crate::core::Bell)>> {
        let mut plan = Vec::new();
        for owner in self.borrowers(conn, core, m.id).await? {
            let (p, debt) = read_position(self.rpc.primary(), ctx, owner).await?;
            if p.auction_id != 0 || p.covered || p.last_bell_closure_id >= ctx.upcoming_closure_id {
                continue;
            }
            let b = bell(ctx, &p)?;
            if b.status != NEEDS_ACTION {
                continue;
            }
            let ltv_now =
                credence_risk_core::fixed::ltv_up(debt, p.collateral_value).unwrap_or(U256::MAX);
            plan.push((owner, expected_outcome(ctx, &p, ltv_now), b));
        }
        Ok(plan)
    }

    async fn j4(
        &self,
        conn: &mut PgConnection,
        core: &CoreJobs,
        m: &CoreMarket,
        ctx: &RiskCtx,
        now: u64,
        rep: &mut TickReport,
    ) -> Result<()> {
        if ctx.clock_state != REGULAR && ctx.clock_state != EXTENDED {
            return Ok(());
        }
        {
            let mut last = core.last_j4.lock().expect("j4 lock");
            if last.get(&m.id).is_some_and(|t| now < t + core.j4_every_s) {
                return Ok(());
            }
            last.insert(m.id, now);
        }
        for owner in self.borrowers(conn, core, m.id).await? {
            let (p, debt) = read_position(self.rpc.primary(), ctx, owner).await?;
            if p.auction_id != 0 {
                continue;
            }
            let hf = health(ctx, p.collateral, debt);
            let floor = if ctx.clock_state == REGULAR {
                U256::from(WAD)
            } else if p.covered {
                continue; // covered positions are exempt from EXTENDED emergency liquidation (R-18)
            } else {
                U256::from(EXTENDED_HF_FLOOR)
            };
            if hf >= floor {
                continue;
            }
            let key = format!("J4:{}:{owner:#x}:{}", m.id, ctx.upcoming_closure_id);
            if !core.j4_live {
                if matches!(
                    jobs::claim(
                        conn,
                        &key,
                        "J4",
                        &json!({ "hf": s(hf), "state": ctx.clock_state, "live": false }),
                        &self.instance
                    )
                    .await?,
                    Claim::Run { .. }
                ) {
                    tracing::info!(asset = %m.asset, borrower = %owner, hf = %hf, state = ctx.clock_state, "J4 flagForAuction (dry-run)");
                    jobs::set_payload(conn, &key, &json!({ "plan": { "fn": "flagForAuction", "id": m.id.to_string(), "borrowers": [owner], "block": ctx.block } })).await?;
                    jobs::mark(conn, &key, "done", None).await?;
                }
                continue;
            }
            self.tx_job(
                conn,
                &key,
                &json!({ "hf": s(hf), "state": ctx.clock_state, "live": true }),
                m.market,
                || {
                    Ok(Bytes::from(
                        abi::ICredenceMarket::flagForAuctionCall {
                            id: m.id,
                            borrowers: vec![owner],
                        }
                        .abi_encode(),
                    ))
                },
                rep,
            )
            .await?;
        }
        Ok(())
    }

    async fn j8(&self, conn: &mut PgConnection, core: &CoreJobs, now: u64) -> Result<()> {
        let hour = now / 3600;
        let mut rep = TickReport::default();
        for m in &core.markets {
            let key = format!("J8:{hour}:claimFees:{}", m.id);
            if jobs::exists(conn, &key).await? {
                continue;
            }
            let ctx = read_ctx(self.rpc.primary(), m.market, m.id, None).await?;
            if !ctx.pending_fees {
                continue;
            }
            self.tx_job(
                conn,
                &key,
                &json!({}),
                m.market,
                || {
                    Ok(Bytes::from(
                        abi::ICredenceMarket::claimFeesCall { id: m.id }.abi_encode(),
                    ))
                },
                &mut rep,
            )
            .await?;
        }
        for (stack, vault) in &core.vaults {
            let key = format!("J8:{hour}:processQueue:{stack}");
            if jobs::exists(conn, &key).await? {
                continue;
            }
            let v = abi::ISeniorVault::new(*vault, self.rpc.primary());
            // processQueue pays from idle cash and market liquidity (`_available`), so any queued
            // request is worth a call; it stops by itself at the first request it cannot pay
            let len = v.queueLength().call().await?;
            if len.is_zero() {
                continue;
            }
            self.tx_job(
                conn,
                &key,
                &json!({ "queueLength": s(len) }),
                *vault,
                || {
                    Ok(Bytes::from(
                        abi::ISeniorVault::processQueueCall {
                            maxRequests: U256::from(50u64),
                        }
                        .abi_encode(),
                    ))
                },
                &mut rep,
            )
            .await?;
        }
        Ok(())
    }

    async fn allowlist(&self, conn: &mut PgConnection, core: &CoreJobs, now: u64) -> Result<()> {
        let Some(registry) = core.registry else {
            return Ok(());
        };
        let rows = sqlx::query("select address from app.allowlist_request where status = 'pending' order by requested_at limit 50")
            .fetch_all(&mut *conn)
            .await?;
        if rows.is_empty() {
            return Ok(());
        }
        let addrs: Vec<Address> = rows
            .iter()
            .map(|r| Address::from_slice(&r.get::<Vec<u8>, _>("address")))
            .collect();
        let key = format!("ALLOW:{:#x}:{}:{}", addrs[0], addrs.len(), now / 60);
        if !matches!(
            jobs::claim(
                conn,
                &key,
                "ALLOW",
                &json!({ "addresses": addrs }),
                &self.instance
            )
            .await?,
            Claim::Run { .. }
        ) {
            return Ok(());
        }
        let data = Bytes::from(
            abi::ComplianceRegistry::setAllowedBatchCall {
                accounts: addrs.clone(),
                allowed: true,
            }
            .abi_encode(),
        );
        let mut rep = TickReport::default();
        let res = self.tx.send(conn, &key, registry, data).await;
        let (status, hash, err) = match &res {
            Ok(m) if m.success => ("done", Some(m.hash), None),
            Ok(m) => (
                "failed",
                Some(m.hash),
                Some(format!("reverted in {}", m.hash)),
            ),
            Err(e) => ("failed", None, Some(e.to_string())),
        };
        for a in &addrs {
            sqlx::query("update app.allowlist_request set status = $2, tx_hash = $3, last_error = $4, updated_at = now() where address = $1")
                .bind(a.as_slice())
                .bind(status)
                .bind(hash.map(|h| h.to_vec()))
                .bind(&err)
                .execute(&mut *conn)
                .await?;
        }
        jobs::mark(
            conn,
            &key,
            if status == "done" { "done" } else { "failed" },
            err.as_deref(),
        )
        .await?;
        rep.failed += (status != "done") as usize;
        tracing::info!(count = addrs.len(), status, "allowlist batch");
        Ok(())
    }
}

/// Markets of the unified address book (`equity.markets` / `nav.markets`: ticker → marketId) with the
/// stack's market address, and the stacks' vaults.
pub fn auction_stacks(book: &serde_json::Value) -> Vec<crate::auction_jobs::AuctionStack> {
    let addr = |s: &serde_json::Value, k: &str| {
        s.get(k)
            .and_then(|v| v.as_str())
            .and_then(|v| v.parse::<Address>().ok())
    };
    ["equity", "nav"]
        .iter()
        .filter_map(|stack| {
            let s = book.get(*stack).filter(|v| v.is_object())?;
            Some(crate::auction_jobs::AuctionStack {
                stack: stack.to_string(),
                market: addr(s, "market")?,
                house: addr(s, "auctionHouse")?,
                pool: addr(s, "pool").unwrap_or(Address::ZERO),
            })
        })
        .collect()
}

pub fn from_book(book: &serde_json::Value) -> (Vec<CoreMarket>, Vec<(String, Address)>) {
    let mut markets = Vec::new();
    let mut vaults = Vec::new();
    for stack in ["equity", "nav"] {
        let Some(s) = book.get(stack).filter(|v| v.is_object()) else {
            continue;
        };
        let market = s
            .get("market")
            .and_then(|v| v.as_str())
            .and_then(|v| v.parse::<Address>().ok());
        if let (Some(market), Some(ms)) = (market, s.get("markets").and_then(|v| v.as_object())) {
            for (ticker, id) in ms {
                if let Some(id) = id.as_str().and_then(|v| v.parse::<B256>().ok()) {
                    markets.push(CoreMarket {
                        asset: ticker.clone(),
                        token: format!("t{ticker}"),
                        market,
                        id,
                    });
                }
            }
        }
        if let Some(v) = s
            .get("vault")
            .and_then(|v| v.as_str())
            .and_then(|v| v.parse::<Address>().ok())
        {
            vaults.push((stack.to_owned(), v));
        }
    }
    (markets, vaults)
}

pub type SharedCore = Arc<CoreJobs>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headsup_windows() {
        let close = 1_000_000u64;
        let bell_at = close - 900;
        assert_eq!(headsup_stage(close - 27 * 3600, close, bell_at), None);
        assert_eq!(
            headsup_stage(close - 26 * 3600, close, bell_at),
            Some("T-26h")
        );
        assert_eq!(
            headsup_stage(close - 3 * 3600, close, bell_at),
            Some("T-26h")
        );
        assert_eq!(
            headsup_stage(close - 2 * 3600, close, bell_at),
            Some("T-2h")
        );
        assert_eq!(headsup_stage(bell_at - 1, close, bell_at), Some("T-2h"));
        assert_eq!(headsup_stage(bell_at, close, bell_at), None);
        assert_eq!(headsup_stage(close, close, bell_at), None);
    }

    #[test]
    fn markets_from_the_unified_book() {
        let book = serde_json::json!({
            "equity": { "market": "0x00000000000000000000000000000000000000aa", "vault": "0x00000000000000000000000000000000000000bb",
                        "markets": { "NVDA": format!("0x{}", "11".repeat(32)), "TSLA": format!("0x{}", "22".repeat(32)) } },
            "nav": null
        });
        let (m, v) = from_book(&book);
        assert_eq!(m.len(), 2);
        assert_eq!(m[0].token, "tNVDA");
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].0, "equity");
    }
}
