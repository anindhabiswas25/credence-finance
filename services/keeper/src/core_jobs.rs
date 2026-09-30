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
        read_ctx, read_position, safe_ltv_for, targets, RiskCtx, Target, AUTO_COVERED, EXTENDED,
        NEEDS_ACTION, PRECLOSE_SALE, PRECLOSE_THEN_COVER, REGULAR, SALE_TOO_LATE,
    },
    jobs::{self, Claim},
    tasks::{Keeper, TickReport},
    txjob::TxJob,
};

pub const HEADSUP_EARLY_S: u64 = 26 * 3600;
pub const HEADSUP_LATE_S: u64 = 2 * 3600;
/// J3: BE-chain 04:40 (devnode, real pool): 10 auto-covers ≈ 22.9M gas, 11 ≈ 25.1M > 24M. After the ADR-0114
/// revert (no Bell-batch bracket) `writeCover` costs 3.23M against S3's 3.16M: 9, provisional until BE-chain's
/// re-measure (board 15:06). Override with `KEEPER_J3_BATCH`.
pub const BELL_BATCH: usize = 9;
/// Flag batches: a lot holds at most 128 positions (~90k gas each).
pub const FLAG_BATCH: usize = 128;
/// J3 pages ops if NEEDS_ACTION positions remain this long after bellAt (§10.2).
pub const BELL_PAGE_AFTER_S: u64 = 10 * 60;
/// The PRECLOSE lot is fixed at `close − timings[PRECLOSE][0]` (AuctionHouse default 5 min, §8.4.3).
pub const PRECLOSE_FIX_S: u64 = 5 * 60;
/// J3 stops sending pre-close candidates this long before the fixing, so a batch sent just before it is not mined
/// after it (QA-10 guard, kept as defence in depth after ADR-0115).
pub const J3_PRECLOSE_MARGIN_S: u64 = 60;

/// True once a pre-close sale can no longer be joined by a tx sent at `now` (the fixing, less J3's margin).
pub fn preclose_too_late(now: u64, close_at: u64) -> bool {
    now + PRECLOSE_FIX_S + J3_PRECLOSE_MARGIN_S >= close_at
}

/// Splits a J3 plan into what may be sent now and the pre-close candidates held back after the guard time: past it,
/// a batch carries auto-covers only, so no position needing a sale can make it revert (old contract) or end as a
/// wasted SALE_TOO_LATE (ADR-0115). The held ones stay NEEDS_ACTION and are paged.
pub fn j3_split<T: Clone>(
    plan: &[(Address, u8, T)],
    now: u64,
    close_at: u64,
) -> (Vec<(Address, u8, T)>, Vec<Address>) {
    if !preclose_too_late(now, close_at) {
        return (plan.to_vec(), Vec::new());
    }
    let (send, held): (Vec<_>, Vec<_>) = plan.iter().cloned().partition(|x| x.1 == AUTO_COVERED);
    (send, held.into_iter().map(|x| x.0).collect())
}

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
    /// Last read outcome per market, so a market is logged once per change, not every tick (S4 A).
    read_state: Mutex<HashMap<B256, ReadState>>,
    /// §16.1 shortfall alert: next block to scan for `Shortfall`, and the escalations seen (reserve, senior).
    pub shortfall_scan: Mutex<(u64, u64, u64)>,
    /// J10: the NAV stack's settlement adapter (`nav.settlement`), if deployed. Its markets are settled by
    /// J10, not flagged by J4 (a direct `flagForAuction` on a NAV market reverts in v3).
    pub nav: Option<crate::nav_jobs::NavStack>,
}

/// `NoReferencePrice(bytes32)` / `NoPrice(bytes32)`: the oracle has never priced the asset (S4 A: "not live";
/// the S4 run showed TBILL reverting `NoPrice` before its NAV feed publishes).
pub const NO_REFERENCE_PRICE_SELECTOR: &str = "2da33f4c";
pub const NO_PRICE_SELECTOR: &str = "caf0b5a1";

/// Outcome of a core market read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReadState {
    Live,
    /// No reference price yet: skipped, counted in `keeper_markets_unpriced`.
    Unpriced,
    /// Any other failure (message kept to log only when it changes).
    Failed(String),
}

impl ReadState {
    pub fn of_error(e: &anyhow::Error) -> Self {
        let msg = format!("{e:#}");
        if [
            NO_REFERENCE_PRICE_SELECTOR,
            NO_PRICE_SELECTOR,
            "NoReferencePrice",
            "NoPrice(",
        ]
        .iter()
        .any(|x| msg.contains(x))
        {
            Self::Unpriced
        } else {
            Self::Failed(msg)
        }
    }
}

impl CoreJobs {
    /// Record a market's read outcome; returns the previous one if it changed (the caller logs it).
    pub fn note_read(&self, id: B256, now: ReadState) -> Option<Option<ReadState>> {
        let mut m = self.read_state.lock().expect("read_state");
        let prev = m.insert(id, now.clone());
        (prev.as_ref() != Some(&now)).then_some(prev)
    }

    /// Health scans (J4, J10 open) run at most every `j4_every_s` per market; true when one is due now.
    pub fn j4_due(&self, id: B256, now: u64) -> bool {
        let mut last = self.last_j4.lock().expect("j4 lock");
        if last.get(&id).is_some_and(|t| now < t + self.j4_every_s) {
            return false;
        }
        last.insert(id, now);
        true
    }

    /// True for a market J10 settles (the NAV stack's market, once its adapter is deployed).
    pub fn is_nav_settled(&self, m: &CoreMarket) -> bool {
        self.nav.as_ref().is_some_and(|n| n.market == m.market)
    }

    /// Markets whose last read had no reference price.
    pub fn unpriced(&self) -> usize {
        self.read_state
            .lock()
            .expect("read_state")
            .values()
            .filter(|s| **s == ReadState::Unpriced)
            .count()
    }
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
            read_state: Mutex::new(HashMap::new()),
            shortfall_scan: Mutex::new((0, 0, 0)),
            nav: None,
        }
    }
}

/// Which loss layers beyond the pool a `Shortfall` reached: (reserve, senior) as 0/1.
pub fn shortfall_layers(paid_reserve: U256, senior_loss: U256) -> (u64, u64) {
    (
        u64::from(!paid_reserve.is_zero()),
        u64::from(!senior_loss.is_zero()),
    )
}

/// §16.1 "Reopen stuck": seconds since the open print (net of the R-20 phase extension) while REOPEN.
pub fn reopen_pending_s(ctx: &RiskCtx, now: u64) -> u64 {
    if ctx.clock_state != crate::auction_jobs::REOPEN_STATE || ctx.open_print_at == 0 {
        return 0;
    }
    now.saturating_sub(ctx.open_print_at + ctx.phase_extension)
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
            let read = read_ctx(self.rpc.primary(), m.market, m.id, None).await;
            let state = match &read {
                Ok(_) => ReadState::Live,
                Err(e) => ReadState::of_error(e),
            };
            if let ReadState::Failed(_) = state {
                self.metrics
                    .market_read_errors
                    .with_label_values(&[&m.asset])
                    .inc();
            }
            // log once per change of state, not every tick (the S3 run logged 28,979 of these)
            if let Some(prev) = core.note_read(m.id, state.clone()) {
                match &state {
                    ReadState::Live if prev.is_some() => {
                        tracing::info!(asset = %m.asset, market = %m.id, "core: market is live again")
                    }
                    ReadState::Live => {}
                    ReadState::Unpriced => tracing::info!(
                        asset = %m.asset, market = %m.id,
                        "core: market has no reference price (NoReferencePrice): not live, skipped until priced"
                    ),
                    ReadState::Failed(e) => {
                        tracing::warn!(asset = %m.asset, market = %m.id, error = %e, "core: market read failed")
                    }
                }
            }
            self.metrics.markets_unpriced.set(core.unpriced() as i64);
            let Ok(ctx) = read else {
                continue;
            };
            self.metrics
                .reopen_pending_seconds
                .with_label_values(&[&m.asset])
                .set(reopen_pending_s(&ctx, now) as i64);
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
        if let Err(e) = self.shortfall_scan(&core).await {
            tracing::debug!(error = %e, "shortfall scan failed");
        }
        if let Err(e) = self.nav_tick(conn, &core, rep).await {
            tracing::warn!(error = %e, "J10 NAV settlement failed");
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
        for t in targets(&cal, now, self.bell) {
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
        // §10.2 "binding (safe LTV < max LTV) for any live position": with the safe LTV capped at the max
        // LTV, a position above it (after a price move) still NEEDS_ACTION, so every position is checked
        let binding = safe < ctx.max_ltv_eff;
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
            &json!({ "binding": binding, "safeLtv": s(safe), "enqueued": sent, "block": ctx.block }),
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
            "select key from ops.keeper_job where chain_id = ops.chain() and key like $1 and status = 'submitted'",
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
        let (send, held) = j3_split(&plan, now, ctx.close_at);
        if !held.is_empty() {
            let k = format!("{prefix}:late");
            if !jobs::exists(conn, &k).await? {
                jobs::mark_covered(conn, &[k], "J3", "page", &self.instance).await?;
                self.page(
                    "J3",
                    format!(
                        "{} pre-close sale candidate(s) in {} held out of J3 after close − {} s (QA-10 guard): {:?}",
                        held.len(),
                        m.asset,
                        PRECLOSE_FIX_S + J3_PRECLOSE_MARGIN_S,
                        held
                    ),
                    rep,
                )
                .await;
            }
        }
        self.metrics
            .bell_unenforced
            .with_label_values(&[&m.asset])
            .set(if now >= ctx.bell_at + BELL_PAGE_AFTER_S {
                plan.len() as i64
            } else {
                0
            });
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
        for batch in send.chunks(core.j3_batch) {
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
            let mut outcome = expected_outcome(ctx, &p, ltv_now);
            // the chain's QA-10 rule (ADR-0115): past the PRECLOSE fixing a needed sale is skipped
            if outcome != AUTO_COVERED && ctx.timestamp + PRECLOSE_FIX_S >= ctx.close_at {
                outcome = SALE_TOO_LATE;
            }
            plan.push((owner, outcome, b));
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
        if core.is_nav_settled(m) {
            return Ok(()); // J10 settles the NAV market (openSettlement), not flagForAuction
        }
        if ctx.clock_state != REGULAR && ctx.clock_state != EXTENDED {
            return Ok(());
        }
        if !core.j4_due(m.id, now) {
            return Ok(());
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
            let Ok(ctx) = read_ctx(self.rpc.primary(), m.market, m.id, None).await else {
                continue; // e.g. no price yet for this asset: the other markets still run
            };
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

    /// §16.1 "Shortfall reached the reserve or senior": scan the markets' `Shortfall` events (≤ 10,000
    /// blocks per tick) and publish how many paid from the reserve (`paidReserve > 0`) or hit the senior
    /// vault (`seniorLoss > 0`). A gauge recounted from the start block and published only once the scan
    /// reached the head, so a restart never looks like a new escalation to the alert.
    pub(crate) async fn shortfall_scan(&self, core: &CoreJobs) -> Result<()> {
        use alloy::{providers::Provider, rpc::types::Filter, sol_types::SolEvent};
        let p = self.rpc.primary();
        let head = p.get_block_number().await?;
        let (from, mut reserve, mut senior) = {
            let g = core.shortfall_scan.lock().expect("shortfall");
            (g.0.max(core.from_block), g.1, g.2)
        };
        if from > head {
            return Ok(());
        }
        let to = head.min(from + 9_999);
        let mut markets: Vec<Address> = core.markets.iter().map(|m| m.market).collect();
        markets.sort();
        markets.dedup();
        let logs = p
            .get_logs(
                &Filter::new()
                    .address(markets)
                    .event_signature(abi::ICredenceMarket::Shortfall::SIGNATURE_HASH)
                    .from_block(from)
                    .to_block(to),
            )
            .await?;
        for l in logs {
            if let Ok(e) = abi::ICredenceMarket::Shortfall::decode_log_data(l.data()) {
                let (r, sn) = shortfall_layers(e.paidReserve, e.seniorLoss);
                reserve += r;
                senior += sn;
                if r + sn > 0 {
                    tracing::warn!(market = %e.id, owner = %e.owner, shortfall = %e.s, paid_reserve = %e.paidReserve, senior_loss = %e.seniorLoss, "shortfall reached the reserve or the senior vault");
                }
            }
        }
        *core.shortfall_scan.lock().expect("shortfall") = (to + 1, reserve, senior);
        if to < head {
            return Ok(()); // still catching up: publishing a partial count would look like new escalations
        }
        self.metrics
            .shortfall_escalations
            .with_label_values(&["reserve"])
            .set(reserve as i64);
        self.metrics
            .shortfall_escalations
            .with_label_values(&["senior"])
            .set(senior as i64);
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

    /// K-07 / QA-10 guard: from `close − 5 min − 60 s` a J3 batch carries auto-covers only; to the second.
    #[test]
    fn edge_k07_no_preclose_candidate_in_a_j3_batch_after_the_guard() {
        let close = 1_791_576_000;
        let (a, b, c) = (
            Address::repeat_byte(1),
            Address::repeat_byte(2),
            Address::repeat_byte(3),
        );
        let plan = vec![
            (a, AUTO_COVERED, ()),
            (b, PRECLOSE_SALE, ()),
            (c, PRECLOSE_THEN_COVER, ()),
        ];
        let guard = close - PRECLOSE_FIX_S - J3_PRECLOSE_MARGIN_S;
        let (send, held) = j3_split(&plan, guard - 1, close);
        assert_eq!(send.len(), 3, "1 s before the guard every candidate goes");
        assert!(held.is_empty());
        for now in [guard, close - PRECLOSE_FIX_S, close - 1] {
            let (send, held) = j3_split(&plan, now, close);
            assert_eq!(
                send.iter().map(|x| x.0).collect::<Vec<_>>(),
                vec![a],
                "at {now}"
            );
            assert_eq!(held, vec![b, c]);
        }
        let late = vec![(b, SALE_TOO_LATE, ())];
        assert_eq!(
            j3_split(&late, guard, close).1,
            vec![b],
            "a SALE_TOO_LATE is never sent"
        );
        assert!(
            j3_split::<()>(&[], guard, close).0.is_empty(),
            "a Bell with 0 positions sends nothing"
        );
    }

    #[test]
    fn alert_inputs() {
        assert_eq!(shortfall_layers(U256::ZERO, U256::ZERO), (0, 0));
        assert_eq!(shortfall_layers(U256::from(5), U256::ZERO), (1, 0));
        assert_eq!(shortfall_layers(U256::from(5), U256::from(1)), (1, 1));
    }

    #[test]
    fn unpriced_markets_are_logged_once_per_change() {
        let core = CoreJobs::new(vec![], vec![], "indexer".into());
        let (a, b) = (B256::repeat_byte(1), B256::repeat_byte(2));
        // the revert as alloy renders it for a market with no price (selector 0x2da33f4c)
        let e = anyhow::anyhow!("server returned an error response: error code 3: execution reverted, data: \"0x2da33f4c0000000000000000000000000000000000000000000000000000000000000001\"");
        assert_eq!(ReadState::of_error(&e), ReadState::Unpriced);
        assert_eq!(core.note_read(a, ReadState::Unpriced), Some(None));
        assert_eq!(
            core.note_read(a, ReadState::Unpriced),
            None,
            "no log on the next tick"
        );
        assert_eq!(core.note_read(b, ReadState::Live), Some(None));
        assert_eq!(core.unpriced(), 1);
        assert_eq!(
            core.note_read(a, ReadState::Live),
            Some(Some(ReadState::Unpriced))
        );
        assert_eq!(core.unpriced(), 0);
        let no_price = anyhow::anyhow!("execution reverted, data: \"0xcaf0b5a15264b60e27ff3d5f95d3aaa26e44d735125be863529f81767f41a4148c9f2586\"");
        assert_eq!(ReadState::of_error(&no_price), ReadState::Unpriced);
        let other = ReadState::of_error(&anyhow::anyhow!("connection refused"));
        assert!(matches!(other, ReadState::Failed(_)));
        assert_eq!(
            core.note_read(b, other.clone()),
            Some(Some(ReadState::Live))
        );
        assert_eq!(core.note_read(b, other), None);
    }

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
