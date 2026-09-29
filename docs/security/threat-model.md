# Threat-model walkthrough (Build Guide §15.1, a §15.2 gate) · S4

Owner: QA-sec · Recorded 2026-09-29 on `da70569` (NAV settlement and the fixes of QA-01..08 included).
For every §15.1 row: the control, where it is in code (`contracts/src/…:line` unless stated), the test that proves it,
and a status: **proven** (a test fails if the control is removed), **partly** (proven in part, or only by a unit test
of the mechanism, or an off-chain/ops control not testable here), **missing** (no control found).
Test paths are under `contracts/test/`.

## Walkthrough

| # | Threat | Control | Where | Proven by | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | Gap worse than history | u_max 50 % on the joint stress replay | `pool/PoolLib.sol:333` (`CapacityExceeded`, via `engine.poolCapacity`) | `invariant/RiskInvariants.t.sol :: invariant_POOL02_utilisationBound`; `unit/UnderwriterPool.t.sol :: test_capacityExceededReverts` | proven |
| 1a | ″ | **Concentration: ≤ 35 % from one asset** (S4, ADR-0112; cap = `maxAssetShare × u_max × J`, timelock `setMaxAssetShare`) | `pool/UnderwriterPool.sol:293` | QA-sec, independent: `security/Concentration.t.sol :: test_oneAssetIsCappedAndAnotherStaysOpen`, `testFuzz_capHolds` (1,000 runs; the cap binds, another asset stays open) | proven (was **missing** at S3) |
| 1b | ″ | Caps, θ = 100 % loading | market `setCaps` (`core/CredenceMarket.sol`), engine params | unit tests (`CredenceMarket.t.sol`), backtest (QE) | partly (backtest is QE's, outside this repo's tests) |
| 2 | Oracle manipulation (weekend DEX) | `min(frozen ref, DEX TWAP)` off hours; no liquidation in CLOSED | `oracle/OracleAdapter.sol:148`; `core/market/LiquidationLogic.sol:195` (`_releaseAllowed`) | `invariant/ClockInvariants.t.sol :: invariant_ORA01_offHoursNeverAboveRef`; `MarketInvariants / RiskInvariants :: invariant_LIQ01_noLiquidationWhileShut` | proven |
| 2a | ″ (found in S4) | "lower is safer" does not hold when the pool *sells*: resale listing and GDA buys only in REGULAR, never below (1 − κ)·V_live | `pool/PoolLib.sol:182`; `auction/AuctionHouse.sol:384` | `security/AuctionFindings.t.sol :: test_QA04_resaleIsNotListedWhileClosed`, `test_QA03_gdaNeverSellsBelowTheReserveWhileShut` | proven (QA-03, QA-04 fixed) |
| 3 | Compromised relayer node | 2-of-3 committee signatures (EIP-712, sorted unique signers); cross-feed check → borrow pause; severe disagreement → HALT | `oracle/CredencePriceFeed.sol:127`; `core/market/BorrowLogic.sol:40`; `clock/AssetClock.sol:404` | `unit/CredencePriceFeed.t.sol` (signatures, replay, skew); `unit/OracleAdapter.t.sol`, `unit/AssetClock.t.sol` (disagreement, HALT) | proven |
| 3a | ″ (found in S4) | A report cannot move `seq` more than 2^32 (a signed max-seq report would have ended the feed); nodes refuse out-of-window seqs | `oracle/CredencePriceFeed.sol:152` (`SeqStepTooLarge`); relayer `de6d1bd` | `security/OracleFindings.t.sol :: test_QA08_aSeqJumpCannotEndTheFeed`; BE-backend unit tests (read-only here) | proven (QA-08 / OFF-01 fixed) |
| 4 | Both feeds wrong the same way | Different vendors; **open print vs last close ± 50 % → guardian page**; the guardian can HALT | vendors: relayer config; HALT: `governance/CredenceGuardian.sol` → `AssetClock.restrict` | guardian HALT: `unit/Governance.t.sol :: test_haltAndExtendClosedOnlyExtend`; runbook drill (ops) | **partly — the ± 50 % open-print page is missing**: no check found in `contracts/src`, `services/relayer` or `services/keeper` (and the S4 alert rules could not fire at all until BE-backend's `c62962d`). REQUEST to BE-backend (S4/S5 alerting). |
| 5 | Stale open print | 15-min wait, then the agreeing 5-min TWAPs | `oracle/OracleAdapter.sol:266` | `unit/OracleAdapter.t.sol` (open-print cases); `invariant/ClockInvariants.t.sol :: invariant_CLK03_oneOpenPrintPerClosure` | proven |
| 6 | Bidder collusion | Reserve (1 − κ)·P° = 97 %; pool backstop at R; p* published | `auction/AuctionHouse.sol:509` (`_reserve`), `:242` (`backstopBuy`) | `RiskInvariants :: invariant_AH03_reserveRespected`; `unit/AuctionHouse.t.sol :: test_intradayClearsAtUniformPriceWithBackstop` | proven |
| 7 | Commit griefing | Forfeited bond to the pool; ≤ 64 bids; minimum notional; **(S4) no below-reserve bid holds a slot, a reveal below R forfeits its bond** | `auction/AuctionHouse.sol:545`, `:560`, `:325` (`BidBelowReserve`) | `unit/AuctionHouse.t.sol :: test_bidRules`, `test_reopenSealedAuction`; `security/AuctionFindings.t.sol :: test_QA02_aBidAtTheReserveIsNeverLockedOut`, `test_QA02_revealBelowReserveForfeitsTheBond` | proven (QA-02 fixed; before it, the 64 slots were free to take) |
| 8 | Timeboost / ordering | Sealed commit–reveal (commitment binds chain, house, auction, bidder); uniform price; timestamp windows | `auction/AuctionHouse.sol:300`, `:566` | `RiskInvariants :: invariant_AH02_uniformPrice`; `unit/AuctionHouse.t.sol :: test_sealedRevealRules` | proven |
| 9 | Sequencer outage | Phase extension by the gap + 120 s grace (R-20) | `clock/AssetClock.sol:206` | `unit/AssetClock.t.sol :: test_sequencerGapExtendsPhase` | proven |
| 10 | Keeper down | Permissionless jobs with tips; lazy `poke`; two keeper instances with leader fencing | `core/KeeperTips.sol:62`; keeper `leader.rs` | every keeper job is callable by a test EOA (unit suites); tips never block (`unit/UnderwriterPoolEdges.t.sol :: test_aTipThatCannotBePaidDoesNotBlock`); chaos drill: BE-backend's scenario A SIGKILLs the keeper mid-auction | partly (chaos drill is an e2e / ops control) |
| 11 | Reentrancy via the collateral token hook | `nonReentrant` on every money function; tokens allowlisted per market (`createMarket` is `onlyTimelock`) | e.g. `core/CredenceMarket.sol:211…`, `settlement/SettlementAdapter.sol:115`; `core/CredenceMarket.sol:120` | `security/Reentrancy.t.sol` (32 tests, ERC-777-style hooks on USDC and the collateral: market, vault, pool, auction house, keeper-tip paths, cross-contract probes) and `security/SettlementReentrancy.t.sol` (6); coverage per function in `docs/security/reentrancy.md` | proven. **Per-contract guards do not stop cross-contract reentry**: QA-01 (GDA) was exactly that and is fixed (`gdaBuy` books the sale before the tokens leave); `test_cross_gdaBuy_*` keep it fixed. |
| 12 | Rounding / inflation on the vault and pool | Vault: OZ virtual shares (offset 6) + 1e3 dead shares; pool: virtual (S, 1) with 18-dec shares; §7.2 table | `core/SeniorVault.sol:27`, `:176`; `libraries/SharesMath.sol` | `fuzz/InflationFuzz.t.sol` (vault + pool first-depositor / donation, 10,000 runs); `fuzz/RoundingFuzz.t.sol` (every §7.2 row in Solidity); `security/invariant/SharePriceInvariants.t.sol` | proven. The pool has **no dead shares** (QA-I1): fuzz shows it is not needed (loss ≤ (a0 + donation)/1e12 + 2 units). Engine rows (premium up, lot up) are in risk-core's tests. |
| 13 | Stylus engine bug | Holds no funds; every engine call fails closed (the transaction reverts); differential suite; dedicated audit | `risk/RiskEngineRouter.sol`; `libraries/GasGuard.sol:13` on caught calls | `make stylus-diff` (0 mismatches at 10k, S2); INV-REPAY-01/02 with the engine reverting | partly (10M-input differential and the audit are later gates) |
| 13a | ″ gas-guarded try/catch (ADR-0109) | A caught failure must not be one the caller caused by choosing the gas limit (`GasGuard.check`; `checkOwn` at own-code sites since QA-09) | `libraries/GasGuard.sol:13`; 16 guarded sites | `unit/AssetClock.t.sol :: test_gasStarvedPokeRevertsInsteadOfHalting`; QA-sec: `security/GasGriefing.t.sol` sweeps the caller's gas limit over `enforceBell` (never a forced sale instead of auto-cover) and `settlePositions` (never a shortfall pushed past the pool to the seniors) | proven — **QA-09 (High) found by the sweep in the unoptimised build, fixed `ee740b5`** |
| 14 | Governance key compromise | 48 h timelock (1 h testnet), no admin role; guardian can pause during the delay; Safes on hardware wallets | `governance/CredenceTimelock.sol` (OZ `TimelockController`, admin 0) | `unit/Governance.t.sol :: test_timelockHasNoAdmin`; drill (ops) | partly (key custody is ops) |
| 15 | Guardian key compromise | The guardian can only restrict: haircut only up (≤ 10 pp, ≤ 7 days), unpause delayed 6 h, closures only extended | `core/CredenceMarket.sol:185`; `governance/CredenceGuardian.sol` | `MarketInvariants :: invariant_GOV01_onlyTimelockAndSafeGuardian`; `ClockInvariants :: invariant_CLK02_guardianOnlyRestricts`; `unit/Governance.t.sol` | proven |
| 16 | Relayer / keeper key theft | KMS signers (local keys refuse to load off dev chains); least privilege; hot-wallet caps; alerting | `crates/credence-common/src/signer.rs`; keeper `KEEPER_MAX_FEE_GWEI` (`3d23f80`, OFF-09) | code review (`docs/security/offchain-review.md`); signer unit tests (BE-backend) | partly: no balance cap on the hot wallets themselves, and the alert rules only started working in `c62962d` |

## The two named gaps
- **Concentration limit (row 1a).** Missing at the S3 review; BE-chain added it in `6da23ce` (`UnderwriterPool.writeCover`,
  error `ConcentrationExceeded`, `setMaxAssetShare` timelock-only, default 0.35). QA-sec review: the per-asset worst loss
  Σ_p max_j L_{p,j} equals max_j Σ_p L_{p,j} because an asset's policies are comonotone in the scenario (one z column per
  asset), so the sum is exact, not an over-count. Interpretation for the PM: §15.1 says "≤ 35 % of pool worst-loss from
  one asset"; the code caps one asset at 35 % of the pool's **capacity** (u_max × J), since 35 % of the *current* worst
  loss would forbid the first policy. Proven independently (row 1a); rationale in ADR-0112.
- **Gas-guarded try/catch (row 13a).** ADR-0109 accepted in S3 with one unit test on the clock. QA-sec added gas-limit
  sweeps at the market's auto-cover and waterfall sites: at every limit in [¼, 1.1] × the gas used, the call either
  reverts or does exactly what it does with full gas. In the optimised build no limit breaks it, but in the
  unoptimised (coverage) build the auto-cover sweep failed: **QA-09 (High)**. `GasGuard.check` only sees an
  out-of-gas in the *immediate* callee; the auto-cover path is ≥ 6 frames deep and a deep out-of-gas hands back each
  frame's 1/64, so the catch branch was reachable. Fixed in `ee740b5` (`GasGuard.checkOwn`: empty revert data from
  Credence's own code counts as out-of-gas) at the auto-cover, `payShortfall` and `reserve.cover` sites; a third sweep
  covers `fixLots → releaseLots` (`72fcfc8`). The remaining `check` sites call third-party code or fail harmlessly
  (tips, previews, inventory marks, clock / oracle reads whose leaves are far cheaper than the rest of the call).

## Found during the walkthrough (all fixed in S4)
QA-01 (cross-contract reentrancy at the GDA), QA-02 (bid-slot griefing), QA-03 (GDA decay across closures; spec ruling
pending in ADR-0113), QA-04 (resale listing at a closed-market valuation), QA-08 (feed `seq` jump), QA-09 (deep out-of-gas past the ADR-0109 guard), and from the edge-case matrix QA-10 (late Bell batch reverting). QA-11 (vault market list append-only at 32) is Low, ruled for S5. See the register in
`docs/security/triage.md`.

## Open after S4
1. Row 4: the open-print ± 50 % sanity page does not exist (REQUEST to BE-backend).
2. Row 16: hot-wallet balance caps (ops, S5 with DevOps).
3. QA-I2: a senior loss is recognised at the permissionless `settlePositions`; a lender can exit between the clear and
   the settlement (design note for the audit).
4. The 7 consecutive green nightlies of the 512 × 256 invariant job (the count starts with `nightly-invariants`).
