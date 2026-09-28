# ADR-0107 · BE-chain · Lending core: layout, money flows and the rules the guide leaves open

Status: Accepted · Date: 2026-09-28 · Owner: BE-chain (Sprint 2 item D)

## Context

Sprint 2 builds `CredenceMarket` (§8.4), `SeniorVault` (§8.5), `KinkedRateModel`, `KeeperTips`, `Treasury`,
`ProtocolReserve`, `SigmaOracle` (§8.10), `CredenceTimelock` and `CredenceGuardian` (§8.11). The pool and the auction
house are S3, so the market is programmed against `IUnderwriterPool` / `IAuctionHouse` and tested with mocks. This
records every choice the guide leaves open, and the two places where the implementation deliberately differs from a
figure in the docs.

## Decisions

### 1. Code layout (size)
`CredenceMarket` with all of §8.4 is 45 KB, far above the 24 KB limit. The logic lives in three **linked external
libraries** (`src/core/market/BorrowLogic`, `CoverLogic`, `LiquidationLogic`) that run by DELEGATECALL on one storage
struct (`Layout` in `MarketLib.sol`); `MarketLib` holds the shared internal helpers. The market itself keeps
governance, the vault hooks, `repay` / `addCollateral` (so they never touch a library, P2) and the views. These files
compile with `optimizer_runs = 200` (a Foundry compilation restriction); everything else keeps 10,000. Sizes:
market 21.3 KB, libraries 7.5 / 10.6 / 14.3 KB. Coverage runs under `FOUNDRY_PROFILE=coverage`, which drops the
restriction so the line mapping is exact.

### 2. Identity and wiring
- `marketId = keccak256(abi.encode(loanToken, collateralToken, assetId))`: stable when risk parameters change.
- New markets start with ρ_J = ρ_p = 10% (§12.2). `createMarket` checks LT ≥ maxLtv + 3 pp, H*(1 − κ)(1 − λ) > LT
  (κ from the engine) and (1 − λ_pre)(1 − κ_pre) > maxLtv (§9.6 a, b). H* is the constant 1.10 (§12.2).
- `initializeWiring` once, by the deployer; `setEngine` / `setOracle` by the timelock (R-21).

### 3. Money flows between contracts
- **Pool:** push, then notify. Premiums (`writeCover`), risk fees (`creditRiskFee`) and penalty thirds
  (`creditPenalty`) are transferred before the call. The pool only trusts calls from the market.
- **Reserve:** pull. `ProtocolReserve.fund(amount)` takes an exact approval (anyone may fund it); above the target
  (max(floor, 5% × Σ borrows)) the excess goes on to the treasury.
- **Shortfalls:** `payShortfall` / `cover` push to the market, and the market counts **what arrived** (balance delta),
  never the return value.
- **Auction proceeds** are pulled from the auction house / settlement adapter in `onAuctionCleared`.
- A failing pool, reserve or tip call never blocks a settlement: a failed reserve third goes to the treasury.

### 4. Accounting
- Interest accrues per market through the borrow index; the senior share goes into `totalSupplyAssets` at once, the
  pool and treasury shares accrue as receivables (R-09). `marketState(id)` returns the state accrued to now.
- `liquidity(id)` = S + F_pool + F_treasury − B (the market's cash). Borrows and vault withdrawals may use it all;
  `claimFees` sweeps min(receivable, liquidity), pool first.
- `repay(assets)` charges exactly `assets` and burns shares rounded down; `repay(shares)` charges the debt of those
  shares rounded up (the Morpho convention).

### 5. Projected debt everywhere (R-08), and the doc figures
Every closure check uses D_proj = D × (1 + r_b × days/365) over the in-progress or next closure: the borrow limit from
the Bell window on, `bellStatus` and its cures, the cover quote, and the **pre-close lot size**. If the calendar
cannot tell the closure length, the market uses 4 days (the longest regular closure), which is conservative.
Consequence: Appendix A's function-level vectors G-10 / G-11 (cures) and G-17 (pre-close lot) are stated at the
**unprojected** debt, so the market's own figures for scenario A are slightly higher (Priya's cure is computed on
D_proj; Maya's lot is 96.92 TSLA instead of 96.5454). The scenario test asserts both: the engine at the doc's debt
reproduces G-10 / G-11 / G-17 to the cent, and the market's numbers equal the same formulas at D_proj. Flagged for the
PM in the sprint report.

### 6. Cover and the Bell
- **INV-COV-01, read with §8.4.3:** a borrower buys cover in REGULAR before `bellAt`; the Bell's auto-cover
  (`enforceBell`) runs in [`bellAt`, close). The invariant is checked against the clock's own times.
- Coverable LTV = min(maxLtv_eff + 0.5 pp, LT − 2 pp) (R-03). Above it, auto-cover joins the pre-close sale sized down
  to maxLtv and then covers (`PRECLOSE_THEN_COVER`); if the quote or capacity fails, the lot is resized to the safe LTV.
- Auto-cover runs as an external self-call (`autoCover`, callable only by the market), so a failed quote falls back
  to a sale instead of reverting the keeper's batch.
- SAFE and already-covered borrowers are skipped with no event and no tip (ADR-0104). Tips follow §8.10 (2 USDC per
  processed position; the doc's $3 / $5 in scenario A are illustrative).

### 7. Liquidation
- `releaseLots` only in the state its kind belongs to: PRECLOSE and INTRADAY in REGULAR, EMERGENCY in EXTENDED, REOPEN
  in REOPEN (INV-LIQ-01/02). A covered position is never flagged in EXTENDED.
- Lots hold at most 200 positions (`TooManyPositions`). A borrower who cured before lot fixing is dropped; a lot
  whose borrowers all cured releases 0 and never calls `lotSettled`, so **the S3 auction house must treat a released
  lot of 0 as settled**.
- The REOPEN dequeue rule (repay / add collateral) reads only `clock.closureInfo`, inside try/catch.
- The last settled position of a lot receives the rounding dust of the proceeds.

### 8. Borrower rules not spelled out
- `withdrawCollateral` with **no debt** is allowed in every state (nothing is at risk; a user without a loan can always
  take their tokens back).
- The REGULAR withdrawal floor HF ≥ 1.05 only binds when LT / maxLtv < 1.05 (e.g. the NAV market's 93 / 90); with the
  equity 80 / 75 the LTV limit is always the tighter rule.
- `borrowWithCover` adds the premium to the debt.

### 9. Guardian overlay
`bytes32(0)` is the global overlay (ADR-0104). The market accepts from the guardian contract only: a haircut ≤ 10 pp,
lasting ≤ 7 days, and never below a live one; pauses in either direction (the guardian enforces the 6 h unpause
delay; the timelock may unpause at once). `setRiskParams` (timelock) confirms a haircut by clearing it.

### 10. Senior Vault
- totalAssets = idle (minus claimable) + Σ enabled markets' supply (a market is enabled by its first `setCap`).
- The withdraw queue must list every enabled market that holds vault money, so all of it stays reachable.
- The first deposit's 1e3 dead shares come out of that deposit (OZ virtual shares, decimals offset 6).
- Redeem requests are paid at the share price when `processQueue` reaches them, strictly FIFO: processing stops at the
  first request that cannot be paid in full.

### 11. σ
`SigmaOracle` is deployed before the engine (whose constructor needs it) and wired once (`initializeWiring(engine)`,
v1 additive). EIP-712 domain ("CredenceSigmaOracle", "1"); `asOfDay` strictly increasing per (asset, type) makes each
signed update single-use.

## Consequences
The S3 pool and auction house implement the conventions in §3 and §7. The indexer can rely on `marketIds()`, the
events of §8.4 and `lotInfo`. The scenario A figures that differ from the docs are explained in §5.
