//! Pool lifecycle and resale (§10.2 J9, J11) and the REOPEN completion (J5):
//!
//! * **J9** per pool (one venue each): `openEpoch(venue)` once the venue's Bell window for the next close
//!   has opened and no epoch is unsettled; `snapshotEpoch(e)` at the epoch's Bell deadline;
//!   `settleEpoch(e)` after the reopen once `auctionHouse.allReopenLotsSettled(venue, e)`. Keys
//!   `J9:<venue>:<epoch>:<step>`.
//! * **J11**: `resellInventory(asset)` whenever the pool holds backstop inventory not yet in a GDA. Key
//!   `J11:<asset>:<unlisted qty>:<cost>` (a new purchase makes a new key).
//! * **J5 completeReopen**: once an asset's REOPEN queue window is over, `completeReopen(asset)` (the
//!   auction house ends the REOPEN when every tranche cleared, or when there was none).
//!
//! Every step is pre-checked with the contract's own views and an `eth_call` of the exact calldata, so a
//! send can only fail on a race (and then it is counted and alerted, `keeper_failed_txs_total`).

use alloy::{
    eips::BlockNumberOrTag,
    network::TransactionBuilder,
    primitives::{Address, Bytes, B256},
    providers::Provider,
    rpc::types::TransactionRequest,
    sol_types::SolCall,
};
use anyhow::Result;
use serde_json::json;
use sqlx::postgres::PgConnection;

use crate::{
    auction_jobs::{AuctionStack, REOPEN_QUEUE_S, REOPEN_STATE},
    core::{
        abi::{IAuctionHouse, IUnderwriterPool},
        read_ctx, RiskCtx,
    },
    core_jobs::CoreJobs,
    tasks::{Keeper, TickReport},
};

/// EpochPhase codes (Types.sol v2).
pub mod epoch_phase {
    pub const NONE: u8 = 0;
    pub const OPEN: u8 = 1;
    pub const SNAPSHOT: u8 = 2;
    pub const SETTLED: u8 = 3;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PoolStep {
    Open,
    Snapshot,
    Settle,
}

/// What the pool's lifecycle needs at chain time `now`. `active` = the unsettled epoch (id, phase,
/// bellAt, reopenAt), if any; the venue's next Bell window and close come from the clock.
pub fn pool_step(
    active: Option<(u64, u8, u64, u64)>,
    bell_window_at: u64,
    next_close_at: u64,
    lots_settled: bool,
    now: u64,
) -> Option<PoolStep> {
    match active {
        None => (bell_window_at > 0 && now >= bell_window_at && now < next_close_at)
            .then_some(PoolStep::Open),
        Some((_, epoch_phase::OPEN, bell_at, _)) => (now >= bell_at).then_some(PoolStep::Snapshot),
        Some((_, epoch_phase::SNAPSHOT, _, reopen_at)) => {
            (reopen_at > 0 && now >= reopen_at && lots_settled).then_some(PoolStep::Settle)
        }
        _ => None,
    }
}

impl Keeper {
    /// `eth_call` of the exact calldata from the keeper's sender: would it succeed now?
    pub(crate) async fn would_succeed(&self, to: Address, data: &Bytes) -> bool {
        let req = TransactionRequest::default()
            .with_from(self.tx.sender)
            .with_to(to)
            .with_input(data.clone());
        self.rpc.primary().call(req).await.is_ok()
    }

    pub(crate) async fn pools_tick(
        &self,
        conn: &mut PgConnection,
        core: &CoreJobs,
        rep: &mut TickReport,
    ) -> Result<()> {
        for s in &core.auction_stacks {
            if s.pool == Address::ZERO {
                continue;
            }
            // the venue's clock view, through any market of this stack
            let Some(m) = core.markets.iter().find(|m| m.market == s.market) else {
                continue;
            };
            let ctx = read_ctx(self.rpc.primary(), m.market, m.id, None).await?;
            if let Err(e) = self.j9(conn, s, &ctx, rep).await {
                tracing::warn!(stack = %s.stack, error = %format!("{e:#}"), "J9 failed");
            }
            for mk in core.markets.iter().filter(|x| x.market == s.market) {
                if let Err(e) = self.j11(conn, s, mk.asset.as_str(), rep, mk.id).await {
                    tracing::warn!(stack = %s.stack, asset = %mk.asset, error = %format!("{e:#}"), "J11 failed");
                }
            }
        }
        Ok(())
    }

    async fn j9(
        &self,
        conn: &mut PgConnection,
        s: &AuctionStack,
        ctx: &RiskCtx,
        rep: &mut TickReport,
    ) -> Result<()> {
        let p = self.rpc.primary();
        let pool = IUnderwriterPool::new(s.pool, p);
        let venue = pool.venue().call().await?;
        let now = p
            .get_block_by_number(BlockNumberOrTag::Latest)
            .await?
            .map_or(ctx.timestamp, |b| b.header.timestamp);
        let act = pool.activeEpoch().call().await?;
        let active = if act.exists {
            let e = pool.epoch(act.epochId).call().await?;
            Some((
                act.epochId,
                e.phase,
                e.bellAt.to::<u64>(),
                e.reopenAt.to::<u64>(),
            ))
        } else {
            None
        };
        let lots_settled = match active {
            Some((e, epoch_phase::SNAPSHOT, _, _)) => IAuctionHouse::new(s.house, p)
                .allReopenLotsSettled(venue, e)
                .call()
                .await
                .unwrap_or(false),
            _ => false,
        };
        let Some(step) = pool_step(
            active,
            ctx.bell_window_at,
            ctx.next_close_at,
            lots_settled,
            now,
        ) else {
            return Ok(());
        };
        let (key, data) = match (step, active) {
            (PoolStep::Open, _) => (
                format!("J9:{venue}:{}:open", ctx.epoch_id),
                Bytes::from(IUnderwriterPool::openEpochCall { venue }.abi_encode()),
            ),
            (PoolStep::Snapshot, Some((e, ..))) => (
                format!("J9:{venue}:{e}:snapshot"),
                Bytes::from(IUnderwriterPool::snapshotEpochCall { epochId: e }.abi_encode()),
            ),
            (PoolStep::Settle, Some((e, ..))) => (
                format!("J9:{venue}:{e}:settle"),
                Bytes::from(IUnderwriterPool::settleEpochCall { epochId: e }.abi_encode()),
            ),
            _ => return Ok(()),
        };
        if !self.would_succeed(s.pool, &data).await {
            tracing::debug!(key, "J9 step not callable yet");
            return Ok(());
        }
        let r = self
            .tx_job(
                conn,
                &key,
                &json!({ "stack": s.stack, "step": format!("{step:?}"), "now": now }),
                s.pool,
                || Ok(data.clone()),
                rep,
            )
            .await?;
        tracing::info!(stack = %s.stack, key, result = ?r, "J9 epoch lifecycle");
        Ok(())
    }

    async fn j11(
        &self,
        conn: &mut PgConnection,
        s: &AuctionStack,
        ticker: &str,
        rep: &mut TickReport,
        market_id: B256,
    ) -> Result<()> {
        let p = self.rpc.primary();
        let params = crate::core::abi::ICredenceMarket::new(s.market, p)
            .marketParams(market_id)
            .call()
            .await?;
        let asset = params.assetId;
        let inv = IUnderwriterPool::new(s.pool, p)
            .inventory(asset)
            .call()
            .await?;
        let unlisted = inv.qty.saturating_sub(inv.inGda);
        if unlisted == 0 || inv.gdaId != 0 {
            return Ok(());
        }
        let data =
            Bytes::from(IUnderwriterPool::resellInventoryCall { assetId: asset }.abi_encode());
        if !self.would_succeed(s.pool, &data).await {
            return Ok(());
        }
        let key = format!("J11:{asset}:{unlisted}:{}", inv.cost);
        let r = self
            .tx_job(
                conn,
                &key,
                &json!({ "asset": ticker, "unlisted": unlisted.to_string() }),
                s.pool,
                || Ok(data.clone()),
                rep,
            )
            .await?;
        tracing::info!(asset = ticker, unlisted = %unlisted, result = ?r, "J11 GDA resale");
        Ok(())
    }

    /// J5's last step: end the asset's REOPEN once its queue window is over.
    pub(crate) async fn j5_complete_reopen(
        &self,
        conn: &mut PgConnection,
        core: &CoreJobs,
        asset_label: &str,
        ctx: &RiskCtx,
        rep: &mut TickReport,
    ) -> Result<()> {
        if ctx.clock_state != REOPEN_STATE
            || ctx.open_print_at == 0
            || ctx.timestamp < ctx.open_print_at + REOPEN_QUEUE_S + ctx.phase_extension
        {
            return Ok(());
        }
        let Some(s) = core.auction_stacks.iter().find(|s| s.market == ctx.market) else {
            return Ok(());
        };
        let data = Bytes::from(
            IAuctionHouse::completeReopenCall {
                assetId: ctx.asset_id,
            }
            .abi_encode(),
        );
        if !self.would_succeed(s.house, &data).await {
            return Ok(()); // a REOPEN tranche has not cleared yet
        }
        let key = format!("J5:{asset_label}:{}:completeReopen", ctx.closure_id);
        let r = self
            .tx_job(conn, &key, &json!({}), s.house, || Ok(data.clone()), rep)
            .await?;
        tracing::info!(asset = asset_label, closure = ctx.closure_id, result = ?r, "J5 completeReopen");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lifecycle() {
        let (bw, close) = (1_000, 8_200);
        // no unsettled epoch: open inside the Bell window only
        assert_eq!(pool_step(None, bw, close, false, 999), None);
        assert_eq!(
            pool_step(None, bw, close, false, 1_000),
            Some(PoolStep::Open)
        );
        assert_eq!(pool_step(None, bw, close, false, 8_200), None);
        assert_eq!(pool_step(None, 0, 0, false, 5_000), None);
        // open → snapshot at its Bell deadline
        let open = Some((41, epoch_phase::OPEN, 7_300, 100_000));
        assert_eq!(pool_step(open, bw, close, false, 7_299), None);
        assert_eq!(
            pool_step(open, bw, close, false, 7_300),
            Some(PoolStep::Snapshot)
        );
        // snapshot → settle after the reopen, once every REOPEN lot settled
        let snap = Some((41, epoch_phase::SNAPSHOT, 7_300, 100_000));
        assert_eq!(pool_step(snap, bw, close, true, 99_999), None);
        assert_eq!(pool_step(snap, bw, close, false, 100_500), None);
        assert_eq!(
            pool_step(snap, bw, close, true, 100_500),
            Some(PoolStep::Settle)
        );
    }
}
