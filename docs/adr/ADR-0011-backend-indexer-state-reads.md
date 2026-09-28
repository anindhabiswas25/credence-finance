# ADR-0011 · Indexer: market, position and vault rows are read at the event's block

Status: accepted · Sprint 2 · Owner: BE-backend · Guide §10.3, §11.1

## Context
§10.3 asks for handlers that are "pure projections of events, with no RPC reads, except `context.client.readContract` for health factors and σ at the block of the event". The S2 contracts do not emit an event for every state change a row depends on:
- the Bell's auto-cover adds the premium to debt through `mintDebt` without a `Borrow` event;
- settlement moves collateral and burns borrow shares (`LotReleased`, `PositionSettled`) without collateral or repay events;
- interest accrual changes the supply and fee receivables, and the vault's `totalAssets` grows with interest with no vault event at all.

Summing event deltas would drift from the chain on the first auto-cover.

## Decision
1. Events decide **when** a row changes. On each one, the handler reads the contract's own view **at the event's block** (`blockNumber: event.block.number`):
   - market rows: `marketState(id)`;
   - position rows: `position(id, owner)` and `debtOf(id, owner)`;
   - vault rows: `totalAssets`, `totalSupply`, `idle`, `queueLength`, `pendingRedeemShares` and `claimableAssets`.

   These reads are deterministic. Ponder caches them per block, so re-indexing does not refetch, and they are reorg-safe like the events themselves.
2. `position_event` keeps the raw event arguments (as decimal strings) plus the asset's clock state at that time, for the UI history.
3. `sigma_point` projects the engine's `SigmaUpdated` with `day = floor(block.timestamp / 86400)`. The day's last update wins.
4. `price_point.status` comes from the v1 `ReportAccepted.marketStatus` (R-25). Feeds deployed before v1 (the S1 devnode stack) still emit the v0 event, so both signatures are indexed, and v0 rows get `status = null`.
5. Market and vault addresses come from the address book (`equity.market`, `nav.market`, `equity.vault`, `nav.vault`, ADR-0105). Until a core stack is deployed, the contracts watch the zero address and index nothing.

## Consequences
- The rows equal the chain at the last event. Values that move with time between events (debt with interest, vault share price) are served live by the API from the chain (§10.4, `/bell` and `/vault`).
- There is one extra RPC call per event (two for positions). This is acceptable for testnet volumes. If it becomes a cost, the fix is contract events, not client-side arithmetic: a `DebtMinted` event for the auto-cover premium, and collateral and shares events on settlement.

## S3 update (2026-09-29, interfaces v2, ADR-0110)
BE-chain added the missing events (PM ruling S2 #1). What changed:
- **Pure projections, no RPC reads:** every S3 table (`pool`, `epoch`, `cover_policy`, `pool_flow`, `pool_request`, `backstop_inventory`, `auction`, `bid`, `lot_position`, `gda`, `open_print`), from the v2 pool, auction house, market and clock events (`indexer/src/risk.ts`). The auto-cover now lands as `AutoCoverApplied(premium, debtAfter)` on `position_event` and on its `cover_policy` row (linked through `CoverBought.policyId` in the same tx), and settlements as `PositionSettled(collateralSold, proceeds, penalty, shortfall, refund, debtAfter)` plus `Shortfall` on `lot_position`. `LotReleased` finds its market through the projected `auction` row instead of the `lotInfo` read.
- **Still read at the event's block (unchanged, by design):** the `market` row (`marketState`: interest accrual changes totals between events) and the `position` row's `borrowShares` / `debtOf`: auto-cover and settlement change a position's borrow shares, and v2 events carry the debt after but not the shares. Adding the shares to `AutoCoverApplied` / `PositionSettled` would remove the last position read; this is left as a suggestion, not a blocker (the rows are exact either way).
- The vault rows keep their reads (ERC-4626 views move with the markets' interest).
