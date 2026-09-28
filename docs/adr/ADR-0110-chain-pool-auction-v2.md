# ADR-0110 · BE-chain · UnderwriterPool, AuctionHouse and interfaces v2

Status: accepted (S3) · Date: 2026-09-29

## Context
S3 builds the real `UnderwriterPool` (§8.6) and `AuctionHouse` (§8.7) and, per the PM's S2 ruling, adds the events
the indexer needs to be a pure projection again (Guide §10.3). Several v1 events and pool / auction functions must
change shape, so the S3 interfaces are a **new frozen release, `deployments/abis/v2/`** (brief A2). v0 and v1 stay
frozen; `make abis-check` checks v0→v1 and v1→v2, and each break is listed with its reason in
`contracts/script/abi_diff.py` and in `deployments/abis/v2/CHANGELOG.md`.

## Decisions

### 0. Addendum (same sprint)
- `cancelLot(auctionId)` on the market (additive, v2): a lot that can no longer be fixed because the clock left the state its kind needs (an INTRADAY lot the keeper fixes after the close) is cancelled, and its positions are freed untouched. Without it they would keep `auctionId` forever.
- `poolFeeReceivable()` on the market (additive, v2): the pool's NAV counts the fee receivable with interest accrued to now. Each market's stored `poolFeeAccrued` only updates when that market is touched.
- Gap Cover is sold from the Bell window (close − 2 h) until `bellAt`. The epoch opens at the Bell window (§8.6.1), so a `buyCover` earlier in the session reverts `EpochNotOpen`, and the app offers cover from the Bell window on.

### 1. ABI v2 breaks (everything else is additive)
- `PositionSettled(bytes32 indexed marketId, address indexed borrower, uint64 indexed auctionId, collateralSold,
  proceeds, penalty, shortfall, refund, debtAfter)` replaces v1's six-field event. `refund` is added to the brief's
  list, because it is money leaving the protocol to the borrower and the UI shows it.
- New: `AutoCoverApplied(marketId, borrower, closureId, premium, debtAfter)`. It is emitted with `CoverBought(auto = true)`.
- Pool events carry the epoch and the resulting state: `EpochOpened` (window times, navBefore, withdrawSharesQueued),
  `EpochSnapshotted` (J, worst loss), `EpochSettled` (every flow, navAfter, sharePriceAfter), `EpochQueuesProcessed`,
  `CoverWritten` (+ assetId, worst loss), `ShortfallPaid` / `*Credited` (+ epochId), `BackstopBought` (+ epochId,
  paid), `WithdrawClaimed` (+ stillOwed), plus `Deposited`, `InventoryListed`, `InventorySold`, `LossReserveReleased`.
- Auction events carry market, venueEpoch, tranche and escrow; `GdaBuy` is renamed `GdaBought` (brief A2). New:
  `LotSettled`, `ReopenCompleted`, `GdaClosed`, `TimingsSet`, `LimitsSet`.
- `Epoch` and `Auction` structs are extended; new `Inventory`, `Bid`, `Gda`, `EpochPhase`.

### 2. `writeCover(r, maxPremium) → (policyId, premium)`
§8.6.2's `previewCover` then `writeCover(r, premium)` with an equality check computes the capacity and the quote
**twice** per cover. `poolCapacity` is the dominant cost (ADR-0108 §5: about 2.0M gas at 10 markets), and the Bell's
auto-cover runs once per borrower in a J3 batch. So the pool computes once, requires `premium ≤ maxPremium`, and the
market pays in the same transaction (money-flow order: pool books, then market transfers; a failed transfer reverts
both). `previewCover` stays for quotes and `bellStatus`.

### 3. Epochs
- A pool is bound to **one venue** at construction (XNYS for the equity stack, USBANK for NAV). `openEpoch(venue)`
  reverts `WrongVenue` for another.
- `epochId` = calendar index `i` of the session whose close starts the closure, which is what the market already sends
  as `CoverRequest.epochId` (the clock's session cursor). Times come from the `CalendarStore`: bellWindowAt =
  close_i − 2 h, bellAt = close_i − 15 min, closeAt = close_i, reopenAt = open_{i+1}.
- **At most one unsettled epoch.** `openEpoch` for i+1 reverts `EpochStillOpen` while i is unsettled. The epoch
  normally settles within minutes of the reopen, and the next Bell window is hours later. If a keeper is late, cover for
  i+1 is unavailable and the Bell falls back to the pre-close sale (fail closed).
- `writeCover` needs the epoch to be OPEN or SNAPSHOT and `r.epochId` to equal it (`PolicyEpochMismatch`).
- A calendar epoch that nobody opened can still be settled once its reopen has passed. It opens and settles in one call,
  so withdrawals queued for it are never stranded.

### 4. Capacity (R-13, PM gas ruling)
The pool stores the epoch's **aggregate** K-loss vector (64 packed words) tagged with the epoch id. The first policy
of a new epoch overwrites the words instead of adding to them: no zeroing at settlement and no fresh 20k SSTOREs. Each
`writeCover` = one `coverLossVector` + one `poolCapacity(current, add, uncovered bounds of every market, J)` + one
`quoteCover` at the returned u_after. Uncovered bounds come from `market.uncoveredExposure(id)` (new view, value at
V_live of `totalCollateral − covered[upcoming]`, and the closure's safe LTV). J = the Bell-deadline snapshot once
taken, the live NAV before.

### 5. Deposits, withdrawals, NAV
- `deposit` mints at once when no epoch is unsettled and no Bell window is open. Otherwise it queues into that epoch,
  and the shares are minted at `sharePriceAfter` when the epoch settles; `claimDeposit` transfers them.
- `requestWithdraw` escrows the shares for the first calendar epoch whose Bell window has not opened. At settlement
  they are burned at `sharePriceAfter` and the assets reserved; `claimWithdraw` pays **oldest epoch first**
  (`ClaimOrder`), partially if free cash is short (inventory not yet resold).
- NAV = cash + Σ market pool-fee receivable + Σ inventory at min(cost, V × (1 − κ)) − unearned premiums −
  pending loss reserve − queued deposits − reserved unpaid withdrawals. `freeCash` (what `payShortfall` and
  `backstopBuy` may spend) = cash − queued deposits − reserved unpaid withdrawals.

### 6. Backstop and GDA
- `backstopBuy` pays **min(qty × R, freeCash)**. In the extreme case of an empty pool, the auction house forwards what
  it got, the positions settle short, and the shortfall goes down the waterfall (the pool has nothing left, so the
  reserve, then the seniors). This keeps a clearing from ever reverting.
- `resellInventory(asset)` (permissionless) hands the inventory to the auction house for a GDA (F-4.5e: k = 1.02 × V,
  price halves in 24 h, r_e = inventory / 3 days). The auction house pays each sale to the pool (`onGdaSale`), and
  realised P&L = proceeds − average cost.

### 7. R-11 pending loss reserve
For every asset with policies in the epoch, the pool keeps that asset's **worst covered loss**: the sum over its
policies of max_j L_{p,j}, taken from the policy's K-vector at write time. At settlement, if an asset's REOPEN has not
completed (`clock.closureInfo(asset).reopenPending`) or its REOPEN lots have not settled, its worst covered loss is
held as `pendingLossReserve`. `releaseLossReserve(epoch, asset)` releases it later.

### 8. Auction house
- **Tranches**: a lot holds at most **128** positions (§8.7.1 says "up to 256"; S2's market used 200). When a lot
  fills, the market calls `nextTranche(auctionId)`. The auction house marks the lot `full`, creates tranche+1 with the
  same schedule, and from then on `getOrCreate` returns the new tranche. **Why 128:** `fixLots` is one call per lot
  and makes one Stylus `liquidationLot` per position (about 50k gas each through the router, measured on the devnode),
  so a 256-position lot would come to about 23M gas: too close to the 24M cap for a call that cannot be split. At 128,
  `fixLots` is about 12M and a whole-lot `settlePositions` about 10M (`RiskGasTest`). Positions beyond 128 are
  handled by more tranches on the same schedule.
- **REOPEN completion**: after the last REOPEN tranche of (asset, closure) clears, the auction house calls
  `clock.markReopenComplete`. The permissionless `completeReopen(asset)` does the same after the queue window when no
  REOPEN auction exists (otherwise the asset would sit in REOPEN forever).
- An empty lot (released 0) is settled at fixing (ADR-0107 §7). `allReopenLotsSettled(venue, epoch)` counts
  unsettled REOPEN auctions per (venue, epoch).
- R-19: open-kind reserves are final at clearing: R = (1 − κ) × min(V_start, V_clear). Bids below the final R are
  refunded.
