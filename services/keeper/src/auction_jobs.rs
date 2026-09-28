//! The closure cycle's auction side (§10.2 J5, J6; §8.7.1 schedules):
//!
//! * **J5 flag**: while an asset is in REOPEN and within `openPrintAt + 120 s + ext`, every position with a
//!   native HF < 1 at the open print is flagged (`flagForAuction`, batches keyed by their borrowers).
//! * **Auction driver** (J5 for REOPEN, J6 for INTRADAY / EMERGENCY / PRECLOSE): every auction the house
//!   created (`AuctionCreated`) is stepped on its own deadlines: `fixLots` at `deadlines[0]`, `clear` at
//!   `deadlines[3]`, then `settlePositions` for every position its lot released.
//!
//! Idempotency keys: `J5:<asset>:<closureId>:<step>:<auctionId>` (REOPEN; §10.2's (asset, closureId,
//! step) plus the tranche's auction id) and `J6:<auctionId>:<step>`. Every step goes through `tx_job`, so
//! a restart between any two steps resumes at the next one and never repeats one. Deadlines are compared
//! with the chain's latest block time, not the wall clock.

use std::collections::{BTreeMap, BTreeSet};

use alloy::{
    eips::BlockNumberOrTag,
    primitives::{Address, Bytes, B256, U256},
    providers::Provider,
    rpc::types::Filter,
    sol_types::{SolCall, SolEvent},
};
use anyhow::Result;
use serde_json::json;
use sqlx::postgres::PgConnection;

use crate::{
    core::{
        abi::{IAuctionHouse, ICredenceMarket},
        health, read_position, RiskCtx,
    },
    core_jobs::{batch_hash, CoreJobs, CoreMarket},
    tasks::{Keeper, TickReport},
    txjob::TxJob,
};

/// ClockState.REOPEN.
pub const REOPEN_STATE: u8 = 3;
/// MarketLib.REOPEN_QUEUE: flags are accepted until openPrintAt + 120 s + ext.
pub const REOPEN_QUEUE_S: u64 = 120;
/// Settlement batch (positions per `settlePositions`).
pub const SETTLE_BATCH: usize = 50;
const WAD: u128 = 1_000_000_000_000_000_000;

/// AuctionKind codes.
pub const KIND_REOPEN: u8 = 0;
/// AuctionPhase codes.
pub mod phase {
    pub const NONE: u8 = 0;
    pub const QUEUE: u8 = 1;
    pub const COMMIT: u8 = 2;
    pub const REVEAL: u8 = 3;
    pub const OPEN_BIDDING: u8 = 4;
    pub const CLEARED: u8 = 5;
    pub const CANCELLED: u8 = 6;
}

pub fn kind_name(k: u8) -> &'static str {
    match k {
        0 => "REOPEN",
        1 => "INTRADAY",
        2 => "EMERGENCY",
        3 => "PRECLOSE",
        _ => "?",
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    FixLots,
    Clear,
    Settle,
}

impl Step {
    pub fn name(self) -> &'static str {
        match self {
            Step::FixLots => "fixLots",
            Step::Clear => "clear",
            Step::Settle => "settle",
        }
    }
}

/// What an auction needs next at chain time `now` (§8.7.1: deadlines = [lotFixAt, biddingStartAt,
/// commitEndOrBidEnd, clearAt]).
pub fn next_step(phase: u8, deadlines: [u64; 4], now: u64) -> Option<Step> {
    match phase {
        phase::QUEUE if now >= deadlines[0] => Some(Step::FixLots),
        phase::COMMIT | phase::REVEAL | phase::OPEN_BIDDING if now >= deadlines[3] => {
            Some(Step::Clear)
        }
        phase::CLEARED => Some(Step::Settle),
        _ => None,
    }
}

/// One stack's auction house and market, as the keeper tracks them.
#[derive(Debug, Clone)]
pub struct AuctionStack {
    pub stack: String,
    pub market: Address,
    pub house: Address,
    pub pool: Address,
}

/// Auctions seen per house (from `AuctionCreated`), the scanned block, and the finished ones.
#[derive(Debug, Default)]
pub struct AuctionBook {
    pub scanned_to: BTreeMap<Address, u64>,
    pub known: BTreeMap<Address, BTreeSet<u64>>,
    pub finished: BTreeSet<(Address, u64)>,
}

impl Keeper {
    /// J5 flag step for one market in REOPEN (called from the core tick with the market's context).
    pub(crate) async fn j5_flag(
        &self,
        conn: &mut PgConnection,
        core: &CoreJobs,
        m: &CoreMarket,
        ctx: &RiskCtx,
        rep: &mut TickReport,
    ) -> Result<()> {
        if ctx.clock_state != REOPEN_STATE
            || ctx.open_print_at == 0
            || ctx.timestamp >= ctx.open_print_at + REOPEN_QUEUE_S + ctx.phase_extension
        {
            return Ok(());
        }
        let mut due = Vec::new();
        for owner in self.borrowers(conn, core, m.id).await? {
            let (p, debt) = read_position(self.rpc.primary(), ctx, owner).await?;
            if p.auction_id != 0 {
                continue;
            }
            if health(ctx, p.collateral, debt) < U256::from(WAD) {
                due.push(owner);
            }
        }
        for batch in due.chunks(core.flag_batch) {
            let borrowers = batch.to_vec();
            let key = format!(
                "J5:{}:{}:flag:{}",
                m.asset,
                ctx.closure_id,
                batch_hash(&borrowers)
            );
            let r = self
                .tx_job(
                    conn,
                    &key,
                    &json!({ "borrowers": borrowers, "block": ctx.block, "openPrintAt": ctx.open_print_at }),
                    m.market,
                    || {
                        Ok(Bytes::from(
                            ICredenceMarket::flagForAuctionCall {
                                id: m.id,
                                borrowers: borrowers.clone(),
                            }
                            .abi_encode(),
                        ))
                    },
                    rep,
                )
                .await?;
            tracing::info!(asset = %m.asset, closure = ctx.closure_id, n = borrowers.len(), result = ?r, "J5 flag at the reopen");
        }
        Ok(())
    }

    /// Discover new auctions of every tracked house and step each unfinished one.
    pub(crate) async fn auctions_tick(
        &self,
        conn: &mut PgConnection,
        core: &CoreJobs,
        rep: &mut TickReport,
    ) -> Result<()> {
        let p = self.rpc.primary();
        let latest = p
            .get_block_by_number(BlockNumberOrTag::Latest)
            .await?
            .ok_or_else(|| anyhow::anyhow!("no latest block"))?;
        let (head, now) = (latest.header.number, latest.header.timestamp);
        for s in &core.auction_stacks {
            if s.house == Address::ZERO {
                continue;
            }
            let from = {
                let b = core.auctions.lock().expect("auction book");
                b.scanned_to
                    .get(&s.house)
                    .map_or(core.from_block, |x| x + 1)
            };
            if from <= head {
                let logs = p
                    .get_logs(
                        &Filter::new()
                            .address(s.house)
                            .event_signature(IAuctionHouse::AuctionCreated::SIGNATURE_HASH)
                            .from_block(from)
                            .to_block(head),
                    )
                    .await?;
                let mut b = core.auctions.lock().expect("auction book");
                for l in logs {
                    if let Ok(ev) = IAuctionHouse::AuctionCreated::decode_log_data(l.data()) {
                        b.known.entry(s.house).or_default().insert(ev.id);
                    }
                }
                b.scanned_to.insert(s.house, head);
            }
            let ids: Vec<u64> = {
                let b = core.auctions.lock().expect("auction book");
                b.known
                    .get(&s.house)
                    .map(|v| {
                        v.iter()
                            .copied()
                            .filter(|id| !b.finished.contains(&(s.house, *id)))
                            .collect()
                    })
                    .unwrap_or_default()
            };
            for id in ids {
                if let Err(e) = self.step_auction(conn, core, s, id, now, rep).await {
                    tracing::warn!(stack = %s.stack, auction = id, error = %e, "auction step failed");
                }
            }
        }
        Ok(())
    }

    async fn step_auction(
        &self,
        conn: &mut PgConnection,
        core: &CoreJobs,
        s: &AuctionStack,
        id: u64,
        now: u64,
        rep: &mut TickReport,
    ) -> Result<()> {
        let a = IAuctionHouse::new(s.house, self.rpc.primary())
            .auction(id)
            .call()
            .await?;
        if a.settled {
            core.auctions
                .lock()
                .expect("auction book")
                .finished
                .insert((s.house, id));
            return Ok(());
        }
        let deadlines = a.deadlines.map(|d| d.to::<u64>());
        let asset = core
            .markets
            .iter()
            .find(|m| m.id == a.marketId)
            .map_or_else(|| a.assetId.to_string(), |m| m.asset.clone());
        let prefix = if a.kind == KIND_REOPEN {
            format!("J5:{asset}:{}", a.closureId)
        } else {
            format!("J6:{id}")
        };
        let Some(step) = next_step(a.phase, deadlines, now) else {
            if a.phase == phase::CANCELLED {
                core.auctions
                    .lock()
                    .expect("auction book")
                    .finished
                    .insert((s.house, id));
            }
            return Ok(());
        };
        let key = if a.kind == KIND_REOPEN {
            format!("{prefix}:{}:{id}", step.name())
        } else {
            format!("{prefix}:{}", step.name())
        };
        let payload = json!({ "auction": id, "kind": kind_name(a.kind), "phase": a.phase, "deadlines": deadlines, "now": now });
        match step {
            Step::FixLots | Step::Clear => {
                let r = self
                    .tx_job(
                        conn,
                        &key,
                        &payload,
                        s.house,
                        || {
                            Ok(Bytes::from(match step {
                                Step::FixLots => {
                                    IAuctionHouse::fixLotsCall { auctionId: id }.abi_encode()
                                }
                                _ => IAuctionHouse::clearCall { auctionId: id }.abi_encode(),
                            }))
                        },
                        rep,
                    )
                    .await?;
                if r != TxJob::Skipped {
                    tracing::info!(auction = id, kind = kind_name(a.kind), step = step.name(), result = ?r, "auction step");
                }
            }
            Step::Settle => {
                let pending = self.unsettled(s, id).await?;
                if pending.is_empty() {
                    core.auctions
                        .lock()
                        .expect("auction book")
                        .finished
                        .insert((s.house, id));
                    return Ok(());
                }
                for batch in pending.chunks(core.settle_batch) {
                    let borrowers = batch.to_vec();
                    let k = format!("{key}:{}", batch_hash(&borrowers));
                    let r = self
                        .tx_job(
                            conn,
                            &k,
                            &json!({ "auction": id, "borrowers": borrowers }),
                            s.market,
                            || {
                                Ok(Bytes::from(
                                    ICredenceMarket::settlePositionsCall {
                                        auctionId: id,
                                        borrowers: borrowers.clone(),
                                    }
                                    .abi_encode(),
                                ))
                            },
                            rep,
                        )
                        .await?;
                    tracing::info!(auction = id, n = borrowers.len(), result = ?r, "settlePositions");
                }
            }
        }
        Ok(())
    }

    /// Positions the lot released (`LotReleased`) and the market has not settled (`PositionSettled`).
    pub async fn unsettled(&self, s: &AuctionStack, id: u64) -> Result<Vec<Address>> {
        let p = self.rpc.primary();
        let topic = B256::from(U256::from(id));
        let base = |sig: B256| {
            Filter::new()
                .address(s.market)
                .event_signature(sig)
                .from_block(0u64)
                .to_block(BlockNumberOrTag::Latest)
        };
        // LotReleased(uint64 indexed auctionId, …); v2 PositionSettled(marketId, borrower, uint64 indexed auctionId, …)
        let released = p
            .get_logs(&base(ICredenceMarket::LotReleased::SIGNATURE_HASH).topic1(topic))
            .await?;
        let settled = p
            .get_logs(&base(ICredenceMarket::PositionSettled::SIGNATURE_HASH).topic3(topic))
            .await?;
        let done: BTreeSet<Address> = settled
            .iter()
            .filter_map(|l| ICredenceMarket::PositionSettled::decode_log_data(l.data()).ok())
            .map(|e| e.borrower)
            .collect();
        let mut out: BTreeSet<Address> = BTreeSet::new();
        for l in released {
            if let Ok(e) = ICredenceMarket::LotReleased::decode_log_data(l.data()) {
                if !e.qty.is_zero() && !done.contains(&e.owner) {
                    out.insert(e.owner);
                }
            }
        }
        Ok(out.into_iter().collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reopen_schedule() {
        // REOPEN: [P+2:00, P+2:00, P+5:00, P+7:00]
        let p = 1_000_000;
        let d = [p + 120, p + 120, p + 300, p + 420];
        assert_eq!(next_step(phase::QUEUE, d, p + 119), None);
        assert_eq!(next_step(phase::QUEUE, d, p + 120), Some(Step::FixLots));
        assert_eq!(next_step(phase::COMMIT, d, p + 200), None);
        assert_eq!(next_step(phase::REVEAL, d, p + 419), None);
        assert_eq!(next_step(phase::REVEAL, d, p + 420), Some(Step::Clear));
        assert_eq!(next_step(phase::CLEARED, d, p + 421), Some(Step::Settle));
        assert_eq!(next_step(phase::CANCELLED, d, p + 999), None);
        assert_eq!(next_step(phase::NONE, d, p + 999), None);
    }

    #[test]
    fn open_auction_schedule() {
        // INTRADAY: fixed at +15 s, open bids until +60 s, cleared at +60 s
        let s = 2_000_000;
        let d = [s + 15, s + 15, s + 60, s + 60];
        assert_eq!(next_step(phase::QUEUE, d, s + 15), Some(Step::FixLots));
        assert_eq!(next_step(phase::OPEN_BIDDING, d, s + 59), None);
        assert_eq!(next_step(phase::OPEN_BIDDING, d, s + 60), Some(Step::Clear));
    }
}
