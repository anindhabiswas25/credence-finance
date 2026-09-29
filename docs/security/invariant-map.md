# Invariant map (Build Guide §14.2) · S4

Owner: QA-sec. Every §14.2 row → the test that proves it (file and function), how strong the proof is, and what is
missing. Paths are under `contracts/test/`. "Mock stack" = `MarketInvariantsTest` (real market and vault; mocked clock,
oracle, engine, pool, auction house). "Real stack" = `RiskInvariantsTest` (real market, vault, pool and auction house;
mocked clock, oracle, engine). Default depth 256 runs × 128; the §15.2 gate runs everything at **512 runs × depth 256**
(`profile.ci`, `make security-invariants`, nightly job `nightly-invariants` in `.github/workflows/security.yml`).

| §14.2 ID | Property | Proved by (file :: function) | Strength | Gaps / notes |
| --- | --- | --- | --- | --- |
| INV-MKT-01 | `loan.balanceOf(market) + ΣB ≥ Σ(S + F_pool + F_treasury)` | `invariant/MarketInvariants.t.sol :: invariant_MKT01_solvency`; `invariant/RiskInvariants.t.sol :: invariant_MKT01_solvency` | Strong (both stacks, direct state check) | — |
| INV-MKT-02 | `B ≤ S + F_pool + F_treasury` per market | `MarketInvariants :: invariant_MKT02_borrowsCovered`; `RiskInvariants :: invariant_MKT02_borrowsCovered` | Strong | — |
| INV-MKT-03 | Σ position collateral = totalCollateral; token balance ≥ Σ | `MarketInvariants :: invariant_MKT03_collateral`; `RiskInvariants :: invariant_MKT03_collateral` | Strong | — |
| INV-LIQ-01 | No collateral decrease (except owner withdrawal) while CLOSED / HALTED / CORP_ACTION | `MarketInvariants :: invariant_LIQ01_noLiquidationWhileShut` (ghost `ghostLiqViolations`, `MarketHandler.sol:548`); `RiskInvariants :: invariant_LIQ01_noLiquidationWhileShut` (`RiskHandler.sol:621`) | Strong | — |
| INV-LIQ-02 | No sale from a covered position in EXTENDED | `MarketInvariants :: invariant_LIQ01_noLiquidationWhileShut` (same ghost, check at `MarketHandler.sol:373-380`) | **Partial** | Shares a counter with LIQ-01 (a failure does not say which), and only the mock stack cycles through EXTENDED; `RiskHandler` never reaches EXTENDED, so EMERGENCY lots are never fixed / cleared on the real auction house. The rule itself lives in the market (`LiquidationLogic.sol:60`), so the mock stack proves it; the real-stack path is a nice-to-have (REQUEST, low). |
| INV-REPAY-01 | `repay` succeeds in every state with engine and oracle reverting | `MarketInvariants :: invariant_REPAY_neverReverts` (`MarketHandler.repayWhileBroken`: engine, oracle **and clock** reverting) | Strong | Mock stack only; repay calls nothing but the token, so the real pool is irrelevant. |
| INV-REPAY-02 | `addCollateral` succeeds under the same conditions | `MarketInvariants :: invariant_REPAY_neverReverts` (`MarketHandler.sol:233`) | Strong | Same counter as REPAY-01. |
| INV-WF-01 | Senior supply falls only in `_waterfall`, after pool = min(S, free cash) and reserve = min(rest, balance) | `MarketInvariants :: invariant_WF01_waterfallOrder`; `RiskInvariants :: invariant_WF01_waterfallOrder` (`RiskHandler.sol:511`) | Strong | + `security/GasGriefing.t.sol :: test_settle_gasCannotPushAShortfallToSeniors` (no caller gas limit skips the pool). |
| INV-COV-01 | No cover after `bellAt` or outside REGULAR | `MarketInvariants :: invariant_COV01_coverWindow`; `RiskInvariants :: invariant_COV01_coverWindow` | Strong | — |
| INV-POOL-01 | Epoch accounting sums to zero; `sharePriceAfter = NAV_after / supply` | `RiskInvariants :: invariant_POOL01_epochAccounting` (`RiskHandler.sol:561-564`, ≤ 64 units of dust) | Strong at settlement | Checked only when an epoch settles (by design). The GDA double count of **QA-01** happens *inside* a transaction and is invisible to any end-of-call invariant: it is proven by `security/Reentrancy.t.sol :: test_cross_gdaBuy_*` instead. |
| INV-POOL-02 | A write with u_after > u_max never succeeds | `RiskInvariants :: invariant_POOL02_utilisationBound` | Strong | + §15.1 concentration: `security/Concentration.t.sol :: test_oneAssetIsCappedAndAnotherStaysOpen`, `testFuzz_capHolds` (QA-sec, not in §14.2). |
| INV-AH-01 | Cash in = cash to market; refunds = escrow − payment; bonds refunded xor forfeited | `RiskInvariants :: invariant_AH01_cashConservation` (+ exact escrow balance) | Strong | — |
| INV-AH-02 | Every filled bid pays exactly p* | `RiskInvariants :: invariant_AH02_uniformPrice` (checked at claim, `RiskHandler.sol:537`) | Strong | — |
| INV-AH-03 | No bid below R is filled | `RiskInvariants :: invariant_AH03_reserveRespected` | Strong | Does not cover QA-02 (below-reserve bids *occupying* slots). |
| INV-AH-04 | Collateral in = collateral out | `RiskInvariants :: invariant_AH04_collateralConservation` (lots, unclaimed fills, unsold GDA) | Strong | — |
| INV-CLK-01 | Clock monotonicity (one closureId per close) | `invariant/ClockInvariants.t.sol :: invariant_CLK01_closureIdOncePerClose` | Strong | — |
| INV-CLK-02 | The guardian only restricts | `ClockInvariants :: invariant_CLK02_guardianOnlyRestricts` | Strong | — |
| INV-CLK-03 | One open print per closure | `ClockInvariants :: invariant_CLK03_oneOpenPrintPerClosure` | Strong | — |
| INV-FAIL-01 | Fail closed | `ClockInvariants :: invariant_FAIL01_failClosed` | Strong | Unit: `unit/AssetClock.t.sol :: test_gasStarvedPokeRevertsInsteadOfHalting` (ADR-0109 on the clock); QA-sec adds the market sites in `security/GasGriefing.t.sol`. |
| INV-ORA-01 | Off-hours valuation ≤ reference close | `ClockInvariants :: invariant_ORA01_offHoursNeverAboveRef` | Strong | The valuation it protects is also used to *list* backstop inventory (**QA-04**) — a place where "lower is safer" is false. |
| INV-SV-01 | Vault share price falls only with a recorded waterfall loss | `MarketInvariants :: invariant_SV01_sharePriceFallsOnlyOnLoss` (tolerance 1 unit, `MarketHandler.sol:554`); `RiskInvariants :: invariant_SV01_…` (`RiskHandler.sol:626`) | Strong, with dust | The 1-unit tolerance hides **QA-06** (the accrued view dips 1 unit with time alone). QA-sec's stricter version: `security/invariant/SharePriceInvariants.t.sol :: invariant_QA_SP01_vaultSharePriceNeverFalls` (≤ 2-unit dust counted separately). |
| INV-DEBT-01 | Σ debt ≤ totalBorrowAssets ≤ Σ debt + #positions | `MarketInvariants :: invariant_DEBT01_debtSums`; `RiskInvariants :: invariant_DEBT01_debtSums` | Strong | — |
| INV-GOV-01 | Only the timelock changes a parameter; the guardian cannot lower a haircut or shorten a closure | `MarketInvariants :: invariant_GOV01_onlyTimelockAndSafeGuardian` (`MarketHandler.attack`, `guardianAct`); `ClockInvariants :: invariant_CLK02_…` (closures) | Strong for the market and clock | Pool / auction house / settlement setters are covered by unit tests (`test_wiringAndGovernance`, `test_governance`, `NavSettlement :: test_access`), not by an invariant. Adequate: their setters are `onlyTimelock` one-liners. |

## Added by QA-sec (`contracts/test/security/invariant/`)

| ID | Property | Test | Why |
| --- | --- | --- | --- |
| INV-QA-SP-01 | The vault's share price never falls without a loss (beyond ≤ 2 units of view dust, QA-06) | `SharePriceInvariants.t.sol :: invariant_QA_SP01_vaultSharePriceNeverFalls` | §15.1 "rounding / inflation attacks": every flow (deposit, withdraw, redeem, queue, interest, donation) rounds for the remaining holders. |
| INV-QA-SP-02 | The pool's share price never falls without a loss (beyond 1 unit of settlement rounding) | `SharePriceInvariants.t.sol :: invariant_QA_SP02_poolSharePriceNeverFalls` | §14.2 has no pool-side counterpart of INV-SV-01. |
| INV-QA-SP-03 | The vault holds in cash every processed redemption it owes | `SharePriceInvariants.t.sol :: invariant_QA_SP03_vaultClaimablesInCash` | R-17 queue solvency. |

## Missing or weak (summary)
1. **NAV settlement invariants** (cash in = cash out, tokens conserved, floor respected, no settlement while HALTED):
   BE-chain's S4 item C; not in `test/invariant/` at `53611cf`. The unit suite `unit/NavSettlement.t.sol` and QA-sec's
   `security/SettlementReentrancy.t.sol` cover the flows meanwhile. The 512 × 256 run covers them once they land.
2. INV-LIQ-02 on the real auction house (above): low priority, the rule is in the market.
3. In-transaction states (QA-01) are outside what invariants can see; the reentrancy suite's `AccountingProbe` checks
   them at every hook.
4. Invariants run with the mocked engine (the real Stylus engine is covered by the differential suite, §14.3) and a
   mocked clock / oracle for the money suites (the real clock and oracle have their own `ClockInvariants`).

## The 512 × 256 run
See `docs/handoff/sprint-4-security-report.md` §4 for the time and result of the local run (`make security-invariants`,
started after BE-backend's final S3 READY, per the machine rules).
