//! J10 NAV settlement (§8.8, §10.2), run by the leader when the address book has a NAV settlement adapter
//! (`nav.settlement`):
//!
//! * **open**: every `j4_every_s`, the NAV market's borrowers with `healthFactor < 1` and no lot yet, in
//!   batches of ≤ 128 → `SettlementAdapter.openSettlement(marketId, borrowers)`. The adapter itself enforces
//!   the clock rules (REGULAR, or REOPEN within the 120 s queue; CLOSED, HALTED and CORP_ACTION revert), so
//!   the `eth_call` pre-check is the gate. Key `J10:<adapter>:<settlementId>:open`, where the id is what the
//!   pre-check returned (the adapter's `nextSettlementId`): a race with another opener makes a new key.
//! * **finalize**: an OPEN settlement once chain time ≥ `endsAt` → `finalize(id)` (solver fill, or the pool's
//!   `fallbackAdvance`). While the fund gates redemptions the pre-check reverts `RedemptionsGated` and the
//!   step simply waits (no tx). Key `J10:<adapter>:<id>:finalize`.
//! * **claim**: an ADVANCED settlement whose fund redemption is claimable (`claimableRedeemRequest(req, pool)
//!   > 0`, the issuer fulfils at T+1 USBANK) and not yet claimed → `pool.claimRedemption(requestId)`. Key
//!   `J10:<adapter>:<id>:claim`.
//! * **completeReopen**: a NAV asset in REOPEN → `adapter.completeReopen(asset)` once the pre-check passes
//!   (queue over, every REOPEN settlement finalized). Key `J10:<asset>:<closureId>:completeReopen`.
//!
//! Every step is pre-checked with views and an `eth_call` of the exact calldata, and is restart-safe through
//! `tx_job` (`ops.keeper_job` / `ops.keeper_tx`), like J5. Interface: BE-chain's frozen v3 (`ISettlementAdapter`,
//! `IUnderwriterPool.claimRedemption`, `CredenceTreasuryFund`; ADR-0111) from `credence-bindings`.

use alloy::{
    network::TransactionBuilder,
    primitives::{Address, Bytes, B256, U256},
    providers::Provider,
    rpc::types::TransactionRequest,
    sol_types::SolCall,
};
use anyhow::Result;
use serde_json::json;
use sqlx::postgres::PgConnection;
use std::sync::Mutex;

use crate::{
    core::abi::ICredenceMarket,
    core_jobs::{CoreJobs, CoreMarket},
    tasks::{Keeper, TickReport},
};

// v3 (BE-chain READY A1, ADR-0111): the frozen interfaces from `credence-bindings`.
use credence_bindings::{
    CredenceTreasuryFund as INavFundV3, ISettlementAdapter as ISettlementAdapterV3,
    IUnderwriterPool as INavPoolV3,
};

/// SettlementStatus (Types.sol v3).
pub mod status {
    pub const NONE: u8 = 0;
    pub const OPEN: u8 = 1;
    pub const FILLED: u8 = 2;
    pub const ADVANCED: u8 = 3;
}

/// A lot holds at most 128 positions (the adapter's per-call limit).
pub const OPEN_BATCH: usize = 128;
/// Settlements looked at per tick (the oldest unfinished first).
pub const SCAN_PER_TICK: u64 = 64;
const WAD: u128 = 1_000_000_000_000_000_000;

/// The NAV stack J10 drives.
#[derive(Debug)]
pub struct NavStack {
    pub adapter: Address,
    pub market: Address,
    pub pool: Address,
    /// Lowest settlement id that may still need a step (every id below it is finalized and, if advanced,
    /// claimed). Starts at 1 and only moves forward.
    pub low: Mutex<u64>,
}

impl NavStack {
    pub fn from_book(book: &serde_json::Value) -> Option<Self> {
        let s = book.get("nav")?;
        let a = |k: &str| {
            s.get(k)
                .and_then(|v| v.as_str())
                .and_then(|v| v.parse::<Address>().ok())
        };
        Some(Self {
            adapter: a("settlement")?,
            market: a("market")?,
            pool: a("pool").unwrap_or(Address::ZERO),
            low: Mutex::new(1),
        })
    }
}

/// The J10 steps, keyed `(settlementId, step)`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NavStep {
    Open,
    Finalize,
    Claim,
}

impl NavStep {
    pub fn name(self) -> &'static str {
        match self {
            NavStep::Open => "open",
            NavStep::Finalize => "finalize",
            NavStep::Claim => "claim",
        }
    }
}

pub fn key(adapter: Address, id: u64, step: NavStep) -> String {
    format!("J10:{adapter:#x}:{id}:{}", step.name())
}

/// What one settlement needs now. `claim` = (already claimed, claimable shares) for an advanced one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SettlementView {
    pub id: u64,
    pub status: u8,
    pub ends_at: u64,
    pub request_id: U256,
    pub claim: Option<(bool, U256)>,
}

/// The next step of a settlement at chain time `now`, and whether it is finished for good.
pub fn next_step(s: &SettlementView, now: u64) -> (Option<NavStep>, bool) {
    match s.status {
        status::OPEN => ((now >= s.ends_at).then_some(NavStep::Finalize), false),
        status::FILLED => (None, true),
        status::ADVANCED if s.request_id.is_zero() => (None, true),
        status::ADVANCED => match s.claim {
            Some((true, _)) => (None, true),
            Some((false, shares)) if !shares.is_zero() => (Some(NavStep::Claim), false),
            _ => (None, false), // the issuer has not fulfilled the redemption yet (T+1)
        },
        _ => (None, false),
    }
}

/// The new `low` after a scan: the first id that is not finished.
pub fn advance_low(low: u64, finished: &[(u64, bool)]) -> u64 {
    let mut l = low;
    for (id, done) in finished {
        if *id == l && *done {
            l += 1;
        } else if *id >= l {
            break;
        }
    }
    l
}

/// Borrowers to settle: health factor < 1 (WAD) and not already in a lot, in batches of `batch`.
pub fn open_batches(candidates: &[(Address, U256, u64)], batch: usize) -> Vec<Vec<Address>> {
    let mut v: Vec<Address> = candidates
        .iter()
        .filter(|(_, hf, lot)| *lot == 0 && *hf < U256::from(WAD))
        .map(|(a, _, _)| *a)
        .collect();
    v.sort();
    v.chunks(batch.max(1)).map(|c| c.to_vec()).collect()
}

impl Keeper {
    pub(crate) async fn nav_tick(
        &self,
        conn: &mut PgConnection,
        core: &CoreJobs,
        rep: &mut TickReport,
    ) -> Result<()> {
        let Some(nav) = core.nav.as_ref() else {
            return Ok(());
        };
        let now = self.clock.now();
        for m in core.markets.iter().filter(|m| m.market == nav.market) {
            if let Err(e) = self.j10_open(conn, core, nav, m, rep).await {
                tracing::warn!(asset = %m.asset, error = %format!("{e:#}"), "J10 open failed");
                self.metrics.jobs.with_label_values(&["J10", "error"]).inc();
            }
            if let Err(e) = self.j10_complete_reopen(conn, nav, m, rep).await {
                tracing::warn!(asset = %m.asset, error = %format!("{e:#}"), "J10 completeReopen failed");
            }
        }
        if let Err(e) = self.j10_settlements(conn, nav, now, rep).await {
            tracing::warn!(error = %format!("{e:#}"), "J10 settlements failed");
            self.metrics.jobs.with_label_values(&["J10", "error"]).inc();
        }
        Ok(())
    }

    /// `eth_call` of the exact calldata from the keeper's sender: the return data, or `None` on a revert.
    async fn call_as_keeper(&self, to: Address, data: &Bytes) -> Option<Bytes> {
        let req = TransactionRequest::default()
            .with_from(self.tx.sender)
            .with_to(to)
            .with_input(data.clone());
        self.rpc.primary().call(req).await.ok()
    }

    async fn j10_open(
        &self,
        conn: &mut PgConnection,
        core: &CoreJobs,
        nav: &NavStack,
        m: &CoreMarket,
        rep: &mut TickReport,
    ) -> Result<()> {
        if !core.j4_due(m.id, self.clock.now()) {
            return Ok(());
        }
        let p = self.rpc.primary();
        let market = ICredenceMarket::new(m.market, p);
        let mut cands = Vec::new();
        for owner in self.borrowers(conn, core, m.id).await? {
            let pos = market.position(m.id, owner).call().await?;
            let hf = market.healthFactor(m.id, owner).call().await?;
            cands.push((owner, hf, pos.auctionId));
        }
        for batch in open_batches(&cands, OPEN_BATCH) {
            let data = Bytes::from(
                ISettlementAdapterV3::openSettlementCall {
                    marketId: m.id,
                    borrowers: batch.clone(),
                }
                .abi_encode(),
            );
            // the adapter's own rules (clock state, HF, already-flagged) decide; a revert means "not now"
            let Some(ret) = self.call_as_keeper(nav.adapter, &data).await else {
                tracing::debug!(asset = %m.asset, n = batch.len(), "J10 openSettlement pre-check reverted");
                continue;
            };
            let id = ISettlementAdapterV3::openSettlementCall::abi_decode_returns(&ret)?;
            let key = key(nav.adapter, id, NavStep::Open);
            let r = self
                .tx_job(
                    conn,
                    &key,
                    &json!({ "asset": m.asset, "marketId": m.id.to_string(), "borrowers": batch }),
                    nav.adapter,
                    || Ok(data.clone()),
                    rep,
                )
                .await?;
            tracing::info!(asset = %m.asset, settlement = id, positions = batch.len(), result = ?r, "J10 openSettlement");
        }
        Ok(())
    }

    async fn j10_settlements(
        &self,
        conn: &mut PgConnection,
        nav: &NavStack,
        now: u64,
        rep: &mut TickReport,
    ) -> Result<()> {
        let p = self.rpc.primary();
        let adapter = ISettlementAdapterV3::new(nav.adapter, p);
        let next = adapter.nextSettlementId().call().await?;
        let low = *nav.low.lock().expect("nav low");
        let pool = if nav.pool.is_zero() {
            adapter.pool().call().await?
        } else {
            nav.pool
        };
        let mut finished = Vec::new();
        for id in low..next.min(low + SCAN_PER_TICK) {
            let s = adapter.settlement(id).call().await?;
            let claim = if s.status == status::ADVANCED && !s.requestId.is_zero() {
                let c = INavPoolV3::new(pool, p)
                    .redemptionClaim(s.requestId)
                    .call()
                    .await?;
                let shares = if c.claimed {
                    U256::ZERO
                } else {
                    INavFundV3::new(s.token, p)
                        .claimableRedeemRequest(s.requestId, pool)
                        .call()
                        .await?
                };
                Some((c.claimed, shares))
            } else {
                None
            };
            let v = SettlementView {
                id,
                status: s.status,
                ends_at: s.endsAt.to::<u64>(),
                request_id: s.requestId,
                claim,
            };
            let (step, done) = next_step(&v, now);
            finished.push((id, done));
            let Some(step) = step else { continue };
            let (to, data) = match step {
                NavStep::Finalize => (
                    nav.adapter,
                    ISettlementAdapterV3::finalizeCall { settlementId: id }.abi_encode(),
                ),
                NavStep::Claim => (
                    pool,
                    INavPoolV3::claimRedemptionCall {
                        requestId: s.requestId,
                    }
                    .abi_encode(),
                ),
                NavStep::Open => continue,
            };
            let data = Bytes::from(data);
            if self.call_as_keeper(to, &data).await.is_none() {
                // e.g. RedemptionsGated at finalize: retry on a later tick, no tx
                tracing::debug!(
                    settlement = id,
                    step = step.name(),
                    "J10 pre-check reverted: waiting"
                );
                continue;
            }
            let key = key(nav.adapter, id, step);
            let r = self
                .tx_job(
                    conn,
                    &key,
                    &json!({ "settlement": id, "step": step.name(), "requestId": s.requestId.to_string() }),
                    to,
                    || Ok(data.clone()),
                    rep,
                )
                .await?;
            tracing::info!(settlement = id, step = step.name(), result = ?r, "J10");
        }
        let new_low = advance_low(low, &finished);
        *nav.low.lock().expect("nav low") = new_low;
        Ok(())
    }

    async fn j10_complete_reopen(
        &self,
        conn: &mut PgConnection,
        nav: &NavStack,
        m: &CoreMarket,
        rep: &mut TickReport,
    ) -> Result<()> {
        let p = self.rpc.primary();
        let asset: B256 = ICredenceMarket::new(m.market, p)
            .marketParams(m.id)
            .call()
            .await?
            .assetId;
        let clock = ICredenceMarket::new(m.market, p)
            .wiring()
            .call()
            .await?
            .clock;
        let c = crate::core::abi::IAssetClockV1::new(clock, p);
        if c.state(asset).call().await? != crate::auction_jobs::REOPEN_STATE {
            return Ok(());
        }
        let closure = c.closureInfo(asset).call().await?.closureId;
        let data =
            Bytes::from(ISettlementAdapterV3::completeReopenCall { assetId: asset }.abi_encode());
        if self.call_as_keeper(nav.adapter, &data).await.is_none() {
            return Ok(()); // queue not over, or a REOPEN settlement still open
        }
        let key = format!("J10:{asset}:{closure}:completeReopen");
        let r = self
            .tx_job(
                conn,
                &key,
                &json!({ "asset": m.asset }),
                nav.adapter,
                || Ok(data.clone()),
                rep,
            )
            .await?;
        tracing::info!(asset = %m.asset, closure, result = ?r, "J10 completeReopen");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn view(status: u8, ends_at: u64, req: u64, claim: Option<(bool, u64)>) -> SettlementView {
        SettlementView {
            id: 1,
            status,
            ends_at,
            request_id: U256::from(req),
            claim: claim.map(|(c, s)| (c, U256::from(s))),
        }
    }

    #[test]
    fn finalize_only_after_the_window() {
        let s = view(status::OPEN, 1_000, 0, None);
        assert_eq!(next_step(&s, 999), (None, false));
        assert_eq!(next_step(&s, 1_000), (Some(NavStep::Finalize), false));
    }

    #[test]
    fn a_solver_fill_is_finished_an_advance_waits_for_the_redemption() {
        assert_eq!(
            next_step(&view(status::FILLED, 0, 0, None), 5),
            (None, true)
        );
        // advanced, the issuer has not fulfilled yet (T+1): nothing to do, not finished
        let pending = view(status::ADVANCED, 0, 7, Some((false, 0)));
        assert_eq!(next_step(&pending, 5), (None, false));
        // fulfilled: claim
        let ready = view(status::ADVANCED, 0, 7, Some((false, 100)));
        assert_eq!(next_step(&ready, 5), (Some(NavStep::Claim), false));
        // claimed: finished
        let claimed = view(status::ADVANCED, 0, 7, Some((true, 0)));
        assert_eq!(next_step(&claimed, 5), (None, true));
    }

    #[test]
    fn low_moves_past_finished_ids_only() {
        assert_eq!(
            advance_low(1, &[(1, true), (2, true), (3, false), (4, true)]),
            3
        );
        assert_eq!(advance_low(3, &[(3, false), (4, true)]), 3);
        assert_eq!(advance_low(3, &[]), 3);
    }

    #[test]
    fn open_takes_hf_below_one_not_in_a_lot_in_batches() {
        let a = |b: u8| Address::repeat_byte(b);
        let wad = U256::from(WAD);
        let c = vec![
            (a(3), wad - U256::from(1), 0), // HF just below 1
            (a(1), wad, 0),                 // HF == 1: healthy
            (a(2), U256::from(WAD / 2), 9), // already in lot 9
            (a(4), U256::from(WAD / 2), 0),
            (a(5), U256::ZERO, 0),
        ];
        assert_eq!(open_batches(&c, 128), vec![vec![a(3), a(4), a(5)]]);
        assert_eq!(open_batches(&c, 2), vec![vec![a(3), a(4)], vec![a(5)]]);
        assert!(open_batches(&[], 128).is_empty());
    }

    #[test]
    fn keys_are_settlement_and_step() {
        let ad = Address::repeat_byte(0xab);
        assert_eq!(
            key(ad, 7, NavStep::Finalize),
            format!("J10:{ad:#x}:7:finalize")
        );
        assert_ne!(key(ad, 7, NavStep::Open), key(ad, 8, NavStep::Open));
    }

    #[test]
    fn the_stack_comes_from_the_book() {
        let book = json!({ "nav": { "market": format!("{:#x}", Address::repeat_byte(1)),
                                    "settlement": format!("{:#x}", Address::repeat_byte(2)),
                                    "pool": format!("{:#x}", Address::repeat_byte(3)) } });
        let s = NavStack::from_book(&book).unwrap();
        assert_eq!(
            (s.market, s.adapter, s.pool),
            (
                Address::repeat_byte(1),
                Address::repeat_byte(2),
                Address::repeat_byte(3)
            )
        );
        assert!(NavStack::from_book(&json!({ "nav": { "market": "0x01" } })).is_none());
    }
}
