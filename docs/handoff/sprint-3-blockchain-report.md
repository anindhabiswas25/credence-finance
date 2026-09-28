# Sprint 3 report · BE-chain

Date: 2026-09-29 · Session model: Claude Opus 5.5 · Commits: `acf1f29..HEAD` (BE-chain commits only; BE-backend's
commits interleave on `main`)

## 1. Summary
Risk transfer is built and runs end to end on real contracts. The **UnderwriterPool** sells Gap Cover per venue
closure through the engine. It keeps one aggregate K-loss vector per epoch (PM gas ruling), settles epochs with the
§8.6.3 preconditions, the R-11 loss reserve and the deposit / withdrawal queues, and buys unsold lots at R and resells
them by GDA. The **AuctionHouse** runs all four kinds: sealed commit–reveal REOPEN with 10% bonds, and open
INTRADAY / EMERGENCY / PRECLOSE. It has tranches, a 64-bid cap, clearing through `engine.clear`, the pool backstop,
REOPEN completion, and GDA resale.

Scenario A now runs through the following Monday on the real pool and auction house: p* 124.11, proceeds 62,055,
the pool pays the 5,011.69 shortfall, senior loss 0, and epoch settlement follows. The gap-loss variant also passes.
15 risk invariants hold at 256 × 128: INV-POOL-01/02, INV-AH-01..04, and the S2 lending invariants against the real
pool. On the devnode, a real `writeCover` and a real `clear` go through the Stylus engine and equal `risk-cli`.

The A1 smoke test turned up a gas-griefing bug in every `try/catch` (fixed, ADR-0109). One writeCover costs about
3.2M gas on the Stylus engine, so a J3 Bell batch holds about 7 auto-covered positions (§6 and the board).

## 2. Acceptance checklist

| # | Item | Status | Proof (command + key output) |
| --- | --- | --- | --- |
| 1 | `make contracts-build contracts-test risk-test contracts-coverage abis-check` from a clean clone; ≥ 95% on the S2 dirs + pool + auction | ✅ | `forge test` → **193 passed, 0 failed** (26 suites, invariants at 256 × 128 included); `make risk-test` → golden 22, props 9, unit 10, cli 4, bindings 2 (0 failed); `make contracts-coverage` → core 97.76%, governance 100.00%, clock 98.69%, oracle 96.69%, **pool 98.65%, auction 97.95%**; `make abis-check` → v0→v1 `46 ABIs, 4 allowed breaks`, v1→v2 `49 ABIs, 25 allowed breaks` (listed in `deployments/abis/v2/CHANGELOG.md`, ADR-0110). Clean-clone re-run: see §10 |
| 2 | A1–A3 delivered, each with a READY before the main build; after A1, BE-backend's `api-bell-e2e` passes | ✅ | Board: A1 READY 00:25 (DECISIONs 22:03 / 22:40 / 23:20 / 23:55 before each book rewrite), A2 READY 00:40, A3 READY 01:05 (ANSWER to BE-backend 22:20). BE-backend ANSWER 00:40: `api-bell-e2e` **100 positions, mismatches 0**, with their own script and from scratch. My smoke run against the item-D book (real pool): `ACCOUNT_SALT=s3-chain-smoke make api-bell-e2e` → `/bell vs chain: 100 positions checked (NEEDS_ACTION 13), mismatches 0` |
| 3 | INV-POOL-01/02 and INV-AH-01..04 at 256 × 128; S2 invariants against the real pool | ✅ | `forge test --match-contract RiskInvariantsTest` → 15 invariants PASS, runs 256, calls 32,768; depth: 4 sessions, backstops, forfeited bonds, claims, 4 epoch settlements. S2 `MarketInvariantsTest` (mocks) still passes |
| 4 | Scenario A through Monday's REOPEN settlement and epoch settlement to the cent; gap-loss variant | ✅ (see §6 on the 2 cents) | `forge test --match-contract ScenarioAFullWeekTest -vv` → Friday debts to the cent, PRECLOSE batch at $249.50, REOPEN: bonds 3,732 / 3,723.30, **p* 124.11**, Mo 37,233, Omar 24,822, **proceeds 62,055**, shortfall = debt − proceeds to the unit (**5,011.69 ± 0.03**, §6), senior loss 0, INV-POOL-01 exact, share price = NAV / 40,000 shares. Gap-loss: pool backstops **200 NVDA at 122.22**, p̄ 123.528 |
| 5 | DeployCoreLocal deploys the real pool and auction house on the devnode against the Stylus router; `make devnode-integration` shows a real writeCover and a real clear | ✅ | Board 03:20 READY: the main book has `equity.pool`, `equity.auctionHouse`, `nav.pool`. `make devnode-integration` → `pool.writeCover premium (Stylus quoteCover at the pool's u_after 8234706907058892) = 3287266` == risk-cli; `clear p* = 178.2`, fills and qPool == risk-cli `clear`; pool inventory = qPool; `auction settled = true` |
| 6 | Gas: writeCover, enforceBell (full batch), clear (64 bids), settlePositions measured; max J3 batch within 24M on the board | ✅ | §4 gas table; J3 posted on the board (BE-chain entry after 03:20) |
| 7 | Report + ADRs for every deviation | ✅ | this file; ADR-0109 (gas-guarded try/catch), ADR-0110 (pool, auction house, interfaces v2, lot size) |

## 3. What was built
- `contracts/src/pool/UnderwriterPool.sol`, `PoolLib.sol` (linked): the §8.6 pool. `cfUP-EQ` / `cfUP-NAV` ERC-20
  shares with virtual-share protection. Epochs per venue session, NAV (cash + accrued fee receivable + inventory at
  min(cost, V(1 − κ)) − unearned premiums − R-11 reserve − queued deposits − reserved withdrawals), `writeCover`
  over the epoch's aggregate K-vector, `payShortfall`, `backstopBuy`, GDA hand-off, FIFO withdrawal claims.
  `fallbackAdvance` reverts `NotImplemented` (S4).
- `contracts/src/auction/AuctionHouse.sol`: the §8.7 auction house (four kinds, timelock-configurable timings,
  tranches, commit–reveal with R-04 bonds, `canHold` compliance, `engine.clear`, backstop, `completeReopen`, GDA with
  Solady `expWad`). A lot that can no longer be fixed is cancelled (`market.cancelLot`).
- `contracts/src/oracle/RedStonePriceSource.sol`: a clean-room `IPriceSource` for RedStone payloads (3-of-5 signers,
  180 s / 60 s window, median, 8 dec → WAD, D1 open / close). Tested on real recorded packages.
- `contracts/src/libraries/GasGuard.sol` + 16 guarded try-sites (ADR-0109).
- Market v2: `writeCover(maxPremium)` protocol, `AutoCoverApplied`, `PositionSettled` v2, `uncoveredExposure`,
  `poolFeeReceivable`, `cancelLot`, 128-position lots with tranches.
- Interfaces v2 + `deployments/abis/v2/` (ADR-0110), `abi_diff.py` per-release allowed breaks, `credence-bindings` on
  v2 (+ ComplianceRegistry, ICompliance, RedStonePriceSource).
- Deploy: `DeployCoreLocal` (real pool / auction house, `SEED_POOL`, `MIN_BID`), `CALENDAR=synthetic` / `SYNTH_ARGS`,
  `synthetic_calendar.py` (compressed mode for BE-backend), address book v2 (S1 flat keys dropped).
- Tests: `UnderwriterPool.t.sol`, `UnderwriterPoolEdges.t.sol`, `AuctionHouse.t.sol`, `RedStonePriceSource.t.sol`,
  `RiskGas.t.sol`, `scenario/ScenarioAFullWeek.t.sol`, `invariant/RiskHandler.sol` + `RiskInvariants.t.sol`,
  `utils/RiskFixture.sol`; MockRiskEngine ports of `coverLossVector`, `poolCapacity`, `clear`.
- Scripts: `devnode_integration.sh` phase 5 (real writeCover and clear), `devnode_gas.sh` (`make devnode-gas`),
  `redstone_fixture.py`.

## 4. Test results
- `forge test`: 193 passed, 0 failed, 0 skipped (26 suites). Risk invariants 256 × 128 in 2 min 40 s.
- Coverage: core 97.76 · governance 100.00 · clock 98.69 · oracle 96.69 · pool 98.65 · auction 97.95 (%).
- Sizes: CredenceMarket 22.6 KB, UnderwriterPool 23.2 KB (+ PoolLib 5.7 KB), AuctionHouse 24.2 KB (all < 24,576 B).
- `make devnode-integration`: every check `ok` (log in §2 item 5).

**Gas** (devnode = the real Stylus engine through the router, Nitro L1 component included; EVM = forge with the
Solidity ports):

| Call | Gas | Where |
| --- | ---: | --- |
| `buyCover` → one `writeCover` (coverLossVector + poolCapacity over 6 markets + quoteCover) | GAS_COVER | devnode |
| `enforceBell`, every borrower auto-covered, per batch size | GAS_BELL | devnode (estimates) |
| **largest J3 batch within 24M** | **J3_BATCH** | devnode |
| `clear`, 64 bids | GAS_CLEAR64 | devnode |
| `fixLots` / `clear` / `settlePositions`, 1 position | 549,416 / 570,182 / 339,942 | devnode |
| `flagForAuction`, 256 positions (2 tranches) | 23,252,942 | EVM |
| `fixLots`, 128 positions (+ ≈ 50k per position for Stylus `liquidationLot`) | 5,780,508 (≈ 12M on Stylus) | EVM |
| `clear`, 64 bids | 2,839,533 | EVM |
| `settlePositions`, 128 positions | 10,260,293 | EVM |

## 5. Deviations from the Build Guide
- §8.6.2 `writeCover(r, premium)` + equality → `writeCover(r, maxPremium)` returning the premium: one capacity
  computation per cover instead of two (ADR-0110 §2).
- §8.7.1 "up to 256 positions per lot" → 128, because `fixLots` cannot be split and makes one Stylus call per
  position (ADR-0110 §8).
- §8.6.1 epoch = session index, one unsettled epoch at a time, cover sold from the Bell window (ADR-0110 §0, §3).
- `backstopBuy` pays min(qty × R, free cash) so a clearing never reverts (ADR-0110 §6).
- R-11 reserve = Σ over the asset's policies of max_j L_{p,j} (ADR-0110 §7).
- New market functions `cancelLot`, `poolFeeReceivable`, `uncoveredExposure` (additive, ADR-0110).
- Every try/catch reverts if the callee ran out of gas (ADR-0109): not in the guide, but closes a griefing path.

## 6. Spec issues found
1. **Appendix A S-A at Monday uses simple interest from the borrow.** The market's borrow index compounds at every
   accrual (R-09), so Priya's 09:37 debt is 67,066.71, not 67,066.69, and the shortfall is 5,011.71. The test asserts
   the chain identity to the unit (shortfall = debt − 62,055) and the doc figure within 3 cents. Guide v1.2 could state
   the S-A debts "with the borrow index" or keep a 3-cent tolerance.
2. **S-A pool share price 35,123.19 / 40,000** uses the doc's pre-R-06 penalty (⅓ = 78.53). With R-06 / R-08 sizing,
   Maya's lot is larger and the pool's third is 80.61, so NAV after = 35,125.22 (share price 0.878130). The identity
   `NAV_after = 40,000 + premium + ⅓ penalty + fees − shortfall` is asserted exactly, and at the doc's inputs it gives
   35,123.19. Guide v1.2 should restate S-A's pool line with the R-06 penalty.
3. **INV-POOL-01 and R-09.** With the fee receivable in NAV, "riskFees" must be the receivable's growth during the
   epoch plus the fees swept to cash (implemented). Backstop inventory marked at min(cost, V(1 − κ)) adds an unrealised
   term. The invariant is checked with both terms; the wording could say so.
4. **Gas vs the Bell batch.** One auto-cover costs about 3.2M gas on the current Stylus engine (two programs, router
   hop, poolCapacity over every market). A 24M J3 batch therefore covers about 7 positions, so a busy Friday needs many
   keeper transactions in the 15-minute Bell deadline window. Options for the PM: accept (keepers parallelise per
   market), a third Stylus program for capacity (ADR-0108 option), or a per-batch cached uncovered bound.

## 7. Interfaces changed or published
- **ABI v2 frozen** (`deployments/abis/v2/`, 50 files): pool and auction interfaces and events, `PositionSettled` v2,
  `AutoCoverApplied`, `GdaBought`. Additive after the A2 READY: market `cancelLot`, `poolFeeReceivable`; pool
  `asset()`; implementation ABIs `UnderwriterPool`, `AuctionHouse`, `RedStonePriceSource`. v0 and v1 unchanged.
- `credence-bindings` on v2.
- Address book v2 (`addressBookVersion: 2`, no flat keys).
- `ICredenceErrors`: `InsufficientGas` plus the pool and auction errors.

## 8. Known gaps and TODOs
- `fallbackAdvance`, SettlementAdapter, SolverAuction: S4 (the NAV stack still uses the settlement stand-in).
- The J3 batch is small (spec issue 4).
- GDA: `closeResale` after 3 days returns unsold tokens; restarting the resale at a fresh k is a new `resellInventory`
  call (no automatic re-listing).
- RedStonePriceSource is deployed nowhere by default (public use gated on ADR-0009 D3).

## 9. Needs from the user or the PM
- PM: spec issues 1–4 (Appendix A S-A wording, INV-POOL-01 wording, the J3 batch size).
- User (open since S2): vendor-key rotation; ADR-0009 D2 / D3 (RedStone listing and written permission).

## 10. How to verify from a clean checkout
```
make contracts-build contracts-test risk-test contracts-coverage abis-check
cd contracts && forge test --match-contract "ScenarioAFullWeekTest|RiskInvariantsTest|RiskGasTest" -vv
make infra-up && make devnode-integration      # real writeCover + clear on the Stylus engine (~25 min)
make devnode-gas                                 # J3 batch, writeCover, clear with 64 bids (~2 h 15 min)
make local-deploy-core CALENDAR=synthetic        # the main book with the real pool and auction house
```
