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
