# ADR-0111 · BE-chain · NAV settlement (SettlementAdapter, SolverAuction, fallbackAdvance), interfaces v3, J10 timing

Status: accepted (S4) · Date: 2026-09-29

## Context
S4 brief items A1, A2 and B: the NAV stack liquidates Treasury-fund collateral at T+0 through an allowlisted solver
auction, and the pool advances the cash when nobody bids (Guide §8.8, §8.6.1). BE-backend builds J10, the solver bot,
the settlement indexer tables and the notifier on these interfaces, so they are frozen first as **ABI release v3**
(`deployments/abis/v3/`). v0–v2 stay frozen; `make abis-check` now checks v2→v3 too.

## 1. Interfaces v3 (additive except four ADR-listed breaks)
New contracts: `SettlementAdapter` (`ISettlementAdapter`) and `SolverAuction` (`ISolverAuction is ISolverVenue`),
both in `contracts/src/settlement/`. New shared types (append-only): `SettlementStatus`, `Settlement`, `SolverLot`,
`RedemptionClaim`. New errors: `ConcentrationExceeded`, `NothingToSettle`, `UnknownSettlement`, `SettlementNotOpen`,
`NoVenue`, `UnknownRedemption`.

| Contract | Addition |
| --- | --- |
| `ISettlementAdapter` | `openSettlement(marketId, borrowers[]) → settlementId`, `finalize(id)`, `completeReopen(assetId)`; the market callbacks `getOrCreate` / `nextTranche` / `lotSettled`; `setVenues`, `setWindow`; views `settlement(id)`, `venues()`, `window()`, `kappaNav()`, `nextSettlementId()`, `openReopenSettlements(asset, closure)`, `market()`, `pool()` |
| `ISolverAuction` | `bid(id, price)`, `setSolver`, `initializeWiring(adapter, loanToken)`, `withdrawRefund()`, views `lot(id)`, `minBid(id)`, `isSolver`, `refundOwed`, `best(id)` |
| `IUnderwriterPool` | `fallbackAdvance` implemented; `claimRedemption(requestId)`; views `redemptionClaimsOutstanding()`, `redemptionClaim(requestId)`; concentration limit `maxAssetShare()` / `setMaxAssetShare` (ADR-0112) |

Events (the indexer's projections, Guide §10.3):

| Emitter | Event |
| --- | --- |
| adapter | `SettlementOpened(uint64 indexed id, bytes32 indexed marketId, address venue, uint256 qty, uint256 floorPrice, uint40 endsAt)` (v2 shape) |
| venue | `SolverWindowOpened(id, token, qty, floorPrice, endsAt)`, `SolverBid(uint64 indexed id, address indexed solver, uint256 price)`, `SolverRefunded(id, solver, amount, pushed)`, `SolverSet`, `RefundWithdrawn` |
| adapter | `SettlementFilled(id, solver, qty, proceeds)` (fill only), `FallbackAdvanced(uint64 indexed id, qty, floorPrice, requestId)` (no bid), and for every settlement **`SettlementFinalized(uint64 indexed id, bool filled, address solver, uint256 price, uint256 proceeds, uint256 requestId)`** |
| adapter | `SettlementPositionsSettled(id, positions)`, `NavReopenCompleted(asset, closureId)`, `VenuesSet`, `WindowSet` |
| pool | **`RedemptionRequested(uint64 indexed epochId, uint256 indexed requestId, bytes32 indexed marketId, address fund, uint256 qty, uint256 cost)`**, **`RedemptionClaimed(uint64 indexed epochId, uint256 indexed requestId, uint256 assets, int256 pnl)`**, `ConcentrationLimitSet` |
| market (unchanged) | `Flagged`, `LotReleased`, `LotsReleased`, `LotCleared`, `PositionSettled`, `Shortfall` for the lot `id` |

Breaks (listed in `abi_diff.py` and `deployments/abis/v3/CHANGELOG.md`):
- `openSettlement` now returns the settlement id.
- `UnderwriterPool.fallbackAdvance` is `nonpayable` (it was `pure`, reverting `NotImplemented`, in S3).
- `ISettlementEvents.RedemptionClaimed(uint256,uint256)` removed: never emitted; the pool is the claimer and emits its own.
- `IUnderwriterPoolEvents.FallbackAdvanced(bytes32,…)` removed: never emitted; the adapter emits `FallbackAdvanced(id, …)`
  and the pool `RedemptionRequested`.

`credence-bindings` binds v3 (all contracts) and adds `ISolverAuction`.

## 2. Design
- **A settlement id is the NAV market's lot id.** The market's lot machinery is reused unchanged (`flagForAuction`,
  `releaseLots`, `onAuctionCleared`, `settlePositions`), so the NAV lot's positions, quantities and per-position
  settlement are read from the market exactly as for an equity auction (`lotBorrowers(id)`, `lotPosition(id, b)`,
  `PositionSettled`).
- `openSettlement` calls `market.flagForAuction`, which asks the adapter's `getOrCreate` for the lot. `getOrCreate`
  only answers inside `openSettlement` (transient flag), so a direct `flagForAuction` on the NAV market reverts: no NAV
  lot can ever be left unreleased. At most 128 borrowers per call = one lot (`nextTranche` is never needed).
- **κ_nav in the market.** `releaseLots` sizes a NAV market's lot with κ_nav = 0.5 % (`MarketLib.KAPPA_NAV`) instead of
  the engine's κ, so the market's F-4.5a reserve equals the adapter's floor `NAV × 99.5 %` (same block, same oracle
  read). Precondition H*(1 − κ)(1 − λ) = 1.1 × 0.995 × 0.99 = 1.0835 > LT 0.93.
- **Venue custody.** The adapter transfers the lot to `venues()[0]` before `open`. `SolverAuction` holds only the best
  bid's escrow (qty × price, rounded up); the outbid solver is refunded in the same transaction (push; a refused push
  is credited to `refundOwed` for `withdrawRefund`, so a blocklisted solver cannot block better bids). A winner that
  can no longer receive the fund token at `finalize` voids its bid (refunded) and the lot falls back to the pool.
- **Pool advance.** No bid: the adapter transfers the tokens to the pool and calls `fallbackAdvance(marketId, qty,
  floor)`. The pool pays `min(qty × floor, freeCash)` (the same rule as `backstopBuy`, ADR-0110 §6), calls
  `fund.requestRedeem(qty, pool, pool)` and carries the claim **in NAV at cost** (§8.6.1). The adapter forwards what
  arrived to the market at p̄ = proceeds / qty rounded down, so the per-position proceeds never exceed the lot's.
  `claimRedemption` (permissionless) redeems into the pool; realised P&L = assets − cost (the κ_nav discount plus the
  fund's accrual) goes to the active epoch's `backstopPnl` (INV-POOL-01).
- **Tips.** The market tips its caller (the adapter) for FLAG and SETTLE; the adapter forwards those to the keeper, and
  pays one OPEN_SETTLEMENT / FINALIZE_SETTLEMENT tip itself (the adapter must be a `KeeperTips` payer).
  `claimRedemption` pays the pool's EPOCH tip.
- **NAV REOPEN.** A fund asset's REOPEN is ended by the adapter (`completeReopen`), not the equity auction house, which
  now reverts `WrongKind` for a non-equity asset (before, it could end a NAV REOPEN while a REOPEN settlement was open).
- **Issuer gate.** Gated redemptions or a frozen fund → `issuerFrozen` → the clock is HALTED → the market's flag
  reverts `ActionNotAllowedInState`, so `openSettlement` reverts; repay and add-collateral stay open (INV-REPAY-01).

## 3. Timing contract for J10 (brief A2)
All times are chain timestamps. `S` = the settlement, `d = clock.closureInfo(asset)`.

| Step | Call | Precondition (else it reverts with) | Keeper pre-check |
| --- | --- | --- | --- |
| open | `adapter.openSettlement(marketId, borrowers ≤ 128)` | clock (after `poke`) is **REGULAR** (lot kind INTRADAY, HF < 1), **EXTENDED** (EMERGENCY, uncovered HF < 0.92) or **REOPEN** with `now < d.openPrintAt + 120 + d.phaseExtension` (REOPEN, HF < 1); CLOSED, HALTED, CORP_ACTION or a later REOPEN → `ActionNotAllowedInState(5, state)`; nobody eligible → `NothingToSettle` | `market.healthFactor(id, b) < 1e18` (0.92e18 in EXTENDED), `position(id, b).auctionId == 0`; `eth_call` first |
| bid | `solverAuction.bid(id, price)` | `now < S.endsAt`; solver allowlisted and `fund.canHold(solver)`; `price ≥ minBid(id)` = max(floor, ⌈best × 1.0001⌉) | `minBid(id)` |
| finalize | `adapter.finalize(id)` | `now ≥ S.endsAt` (`TooEarly(endsAt)`); status OPEN; with no valid bid and the fund gating redemptions → `RedemptionsGated` (retry each poll until ungated) | `settlement(id).status == OPEN`, `block.timestamp ≥ endsAt` |
| NAV reopen | `adapter.completeReopen(asset)` | `d.reopenPending`, `d.openPrintAt ≠ 0`; `now ≥ d.openPrintAt + 120 + d.phaseExtension`; `openReopenSettlements(asset, d.closureId) == 0` (REOPEN settlements of that closure finalized) | as listed |
| claim | `pool.claimRedemption(requestId)` | `fund.claimableRedeemRequest(requestId, pool) > 0`; not yet claimed (`RequestAlreadyClaimed`) | the view, then `eth_call` |

- **Window:** `adapter.window()` = **15 min** (timelock, 5 min ≤ w ≤ 1 day); `endsAt = openedAt + window` is in
  `SettlementOpened`. There is no phase extension on a solver window.
- **Finalize is one transaction**: venue settlement, `onAuctionCleared`, and `settlePositions` of the whole lot (≤ 128
  positions, ≈ 80k gas each). `market.settlePositions(id, …)` stays permissionless and idempotent if J10 ever needs it.
- **Redemption (T+1):** the testnet issuer operator fulfils `fulfillRedeem(requestId)` on the **next USBANK session**
  after the request, at that session's published NAV (§8.12). J10 polls `claimableRedeemRequest(requestId, pool)` after
  each USBANK NAV strike (session close, 17:00 ET) and claims as soon as it is non-zero. On local chains the issuer is
  the deployer key (the e2e fulfils it as an ops step). A claim never expires.
- **Idempotency key:** `(settlementId, step)` with steps `open`, `finalize`, `claim:<requestId>`; the ids come from
  `SettlementOpened` / `FallbackAdvanced` / `RedemptionRequested`.
- Gas (anvil, `forge test --gas-report`, Solidity stand-in engine): see the S4 report §5; the devnode figures follow in
  item E.

## Consequences
- The NAV stack needs these deploy steps: `SettlementAdapter(timelock)`, `SolverAuction(timelock)`; `solver.initializeWiring
  (adapter, usdc)`, `adapter.initializeWiring(market, pool, tips, [solver])`; the fund's registry allowlists the market,
  the adapter, the venue, the pool and every solver; `tips.setPayer(adapter)`; the clock's settlement wiring is the
  adapter. `DeployCoreLocal` does all of it.
- Spec issue (report §6): §8.8 lists `openSettlement`'s forbidden states as {HALTED, CORP_ACTION}, but INV-LIQ-01 (§14.2)
  also forbids liquidation in CLOSED. The market's flag rules apply to the NAV stack as they are: CLOSED reverts too,
  and EXTENDED allows only uncovered HF < 0.92 (EMERGENCY). A fund's NAV does not move while CLOSED, so nothing is lost.
