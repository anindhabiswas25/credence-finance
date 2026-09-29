# Sprint 4 report · BE-chain

Date: 2026-09-29 · Session model: Claude Opus 5.5 · Commits: `6da23ce..HEAD` (BE-chain commits only; BE-backend's
and QA-sec's commits interleave on `main`)

## 1. Summary
The NAV stack now liquidates Treasury-fund collateral at T+0. `SettlementAdapter` flags HF < 1 NAV positions into a
market lot sized with F-4.5a at κ_nav = 0.5 %, and offers it on the native `SolverAuction` for 15 minutes at a floor of
NAV × 99.5 %. `finalize` sells to the best allowlisted solver, or has the pool advance qty × floor against a fund
redemption (`fallbackAdvance`), which the pool claims at T+1 and carries in NAV at cost until then. The issuer gate
halts the market and leaves repay open. Interfaces v3 (A1) and the J10 timing contract (A2) were posted before the main
build, and BE-backend built J10 and the solver bot on them.

Scenario B runs the whole week on the real market, pool and auction house. Every cash figure matches the doc or a chain
identity, and each cent of difference is explained (§4.2, §6). A NAV scenario on the real USBANK calendar, clock, oracle
and fund covers a REOPEN solver fill, a pool advance with its T+1 claim, and the issuer gate. Five settlement
invariants pass at 256 × 128. The §15.1 concentration limit is in place. QA-sec's 8 findings (1 High, 4 Medium, 3 Low) are fixed and closed by QA-sec, and a ninth (QA-09, a deep out-of-gas slipping past ADR-0109's guard) is fixed. NatSpec is complete on every external function, and coverage is ≥ 95 % on every `src/` directory.

**Interim: item E is not done.** The devnode is held by BE-backend's S3 re-run (their DECISION 16:45; no final S3 READY yet), so the NAV phase of `make devnode-integration`, the main-book redeploy and the J3 gas measurement wait for it. The scripts are ready (§8).

## 2. Acceptance checklist

| # | Item | Status | Proof (command + key output) |
| --- | --- | --- | --- |
| 1 | `make contracts-build contracts-test risk-test contracts-coverage abis-check` from a clean clone; ≥ 95 % on every `src/` directory | ✅ | Clean clone of `d8087e4`, niced, `make -k contracts-build contracts-test risk-test contracts-coverage abis-check` (24 m 52 s): build ok; `forge test` 286 passed, and the only 6 failures were QA-sec's `…Today` pins, which QA-sec dropped at 18:01. The current tree gives 292 passed, 0 failed (non-invariant suites) plus every invariant suite. `risk-test` all ok (golden 22, props 9, unit 10, cli 4, bindings 3). Coverage: core 98.26, governance 100, clock 98.69, oracle 96.70, pool 97.64, auction 98.00, **settlement 99.13**, libraries 100, **risk 98.59**, testnet 100 (%). `abis-check`: v0→v1, v1→v2, **v2→v3 `51 ABIs, 4 allowed breaks`** |
| 2 | A1–A2 delivered, each with a READY before the main build | ✅ | Board: **A1 READY and A2 READY at 14:10** (stamped 14:55 / 14:56 by mistake, corrected at 14:12), `6da23ce`. BE-backend ANSWER 17:05: J10 and the solver bot use the frozen v3 `credence-bindings` (`da1763d`) |
| 3 | Scenario B to the cent, or to the chain identity with every cent difference explained; NAV solver-fill and fallback scenarios pass | ✅ | `forge test --match-contract "ScenarioBWeekTest|NavSettlementScenarioTest|NavSettlementTest" -vv` → 25 passed. S-B figures in §4.2; NAV scenario: REOPEN settlement filled at floor + 0.1 %, pool advance qty × floor, claim at T+1 = +0.5 % of cost, HALTED on gated redemptions with repay open |
| 4 | Settlement invariants exist and pass at 256 × 128 | ✅ | `forge test --match-contract SettlementInvariantsTest` → 5 invariants PASS, runs 256, calls 32,768, 0 reverts: INV-SET-01 cash in = cash out, INV-SET-02 tokens conserved, INV-SET-03 floor respected, INV-SET-04 no settlement while HALTED / CLOSED / CORP_ACTION, claims in NAV at cost |
| 5 | Concentration limit in place and tested; every QA-sec REQUEST of high or medium severity fixed or answered | ✅ | ADR-0112, `ConcentrationLimitTest` (4 tests) and QA-sec's independent `Concentration.t.sol`. QA-01…QA-08 fixed in `61761b9` (ADR-0113), ANSWER on the board 16:06; `QA_FINDINGS=1 forge test --match-path 'test/security/**'` → every `finding` test passes |
| 6 | Devnode integration shows a NAV settlement; the main book has the real NAV settlement | ⏳ pending the devnode | `DeployCoreLocal` deploys the real adapter and venue (verified on a private anvil, port 8555: `nav.settlement`, `nav.solverAuction`, venue wired, deployer allowlisted as a solver). `devnode_integration.sh` phase 6 (solver fill with the lot vs risk-cli `liquidation-lot`, pool advance, claim) is written and syntax-checked, not run: the devnode is BE-backend's until their final S3 READY |
| 7 | Report at `docs/handoff/sprint-4-blockchain-report.md`, with ADRs for every deviation | ✅ | this file; ADR-0111 (NAV settlement, interfaces v3, J10 timing), ADR-0112 (concentration limit), ADR-0113 (QA-sec fixes), ADR-0114 (J3 cached uncovered bound; pending the devnode measurement) |

## 3. What was built
- `contracts/src/settlement/SettlementAdapter.sol`: `openSettlement` (flag through the market, release at κ_nav, open
  the venue window), `finalize` (fill, or pool advance; then `onAuctionCleared` and `settlePositions` of the whole lot),
  `completeReopen` for NAV assets, market callbacks, forwarding of the market's FLAG / SETTLE tips to the keeper.
- `contracts/src/settlement/SolverAuction.sol`: allowlisted ascending auction, escrow of the best bid only, immediate
  refund of the outbid solver (credited if the push fails), void of a winner that lost the fund allowlist.
- `UnderwriterPool.fallbackAdvance` / `claimRedemption` (bodies in `PoolLib.advance` / `claim`), redemption claims in
  NAV at cost, `redemptionClaimsOutstanding`, `redemptionClaim`; the §15.1 concentration limit in `writeCover`
  (`maxAssetShare`, 0.35); J3 batch hooks `beginBellBatch` / `endBellBatch` and `PoolLib.quoteBatch` (ADR-0114).
- `LiquidationLogic.releaseLots`: κ_nav for NAV lots. `AuctionHouse.completeReopen`: equity assets only.
- QA-sec fixes (ADR-0113): `GdaLib` (GDA price with the (1 − κ)·V floor), REGULAR-only `gdaBuy` and `resellInventory`,
  notify-before-transfer in `gdaBuy`, bids / reveals below R, vault first-deposit return, fee rounding, FIFO head,
  `CredencePriceFeed.MAX_SEQ_STEP`.
- Types, events and errors of v3; `deployments/abis/v3/` (51 ABIs); `crates/credence-bindings` on v3 + `ISolverAuction`.
- `DeployCoreLocal`: the real adapter and venue on the NAV stack (`NAV_SOLVERS`), book key `nav.solverAuction`.
- Tests: `NavSettlement.t.sol` (22), `SolverAuctionRefund.t.sol` (3), `ConcentrationLimit.t.sol` (4),
  `BellBatch.t.sol` (2), `RiskEngineRouter.t.sol` (4), `SettlementInvariants.t.sol` + handler (5 invariants),
  `ScenarioBWeek.t.sol` (2), `NavSettlementScenario.t.sol` (1); fixtures `NavFixture`, mocks for the Stylus programs,
  a blocklist token.
- NatSpec on every external / public function of `src/` (282 added); `forge fmt` over the tree.
- `script/devnode_integration.sh` phase 6 (NAV settlement through the Stylus router); `mk/contracts.mk`: ABI v3, the
  coverage gate on every `src/` directory, snapshot without QA suites; CI snapshot step likewise.

## 4. Test results

### 4.1 Suites
- `forge test --no-match-path 'test/invariant/*'` → **292 passed, 0 failed** (43 suites, QA-sec's included).
- Invariants at 256 × 128: `SettlementInvariantsTest` 5/5 (32,768 calls, 0 reverts); the S2 / S3 suites unchanged and passing.
- New: `NavSettlementTest` 22, `SolverAuctionRefundTest` 3, `ConcentrationLimitTest` 4, `BellBatchTest` 2, `RiskEngineRouterTest` 4, `GasGuardOwnTest` 3, `ScenarioBWeekTest` 2, `NavSettlementScenarioTest` 1.
- `QA_FINDINGS=1 forge test --match-path 'test/security/**'`: every finding test passes; QA-sec closed QA-01…08 at 18:01.
- Sizes: AuctionHouse 24,175 B, UnderwriterPool 24,019 B, CredenceMarket 22,613 B (limit 24,576); `forge fmt --check` clean; `.gas-snapshot` regenerated.

### 4.2 Scenario B, figure by figure (`ScenarioBWeekTest`)

| Doc figure | Chain | How asserted |
| --- | --- | --- |
| Ben's debt Thu 13:00: 14,809.35 | 14,809.35 | to the half cent |
| Lot 20.23 TSLA (G-13 20.2286) | 20.22863 | ± 0.0001 token |
| Aria pays 7,326.43 | 7,326.41 | = ⌈lot × 362.18⌉ to the unit; doc within 3 cents: the doc multiplied a lot rounded to 20.2287 |
| Penalty 219.79; 73.26 × 3 | 219.79; 73.26 to the pool and to the reserve | to 1 cent / to the half cent |
| 7,106.64 repays Ben; Ben owes 7,702.72, keeps 29.77 TSLA, HF 1.13 | 7,106.62; 7,702.73; 29.77; 1.1255 | identity D − (1 − λ)P to the unit; doc within 3 cents (the lot's 1.6 cents); HF at 2 decimals |
| Friday premiums 297.42 (6.53 + 280.00 + 10.89) | 297.42 | exact (injected, R-22) |
| Dev's debt with the premium 22,530.19 | within 5 cents | the doc's Friday debts carry interest to ≈ 16:00, the chain to 15:45 |
| Monday debts 13,519.02 / 22,542.59 | within $0.50 / 6 cents | the doc's Monday debts carry ≈ 7.016 days of interest (≈ 09:52), the chain reads them at 09:30 |
| Priya 59.08 at 156.02 (G-14 59.0752) | lot within 0.02 token, p* = 156.024 exactly | Appendix A's ± $0.50 rule for a rounded lot |
| Aria escrows 22,357.15; cash in 31,087.15 | within $0.50 | identity: cash in = Aria's fills + the pool's 8,730.00, to the unit |
| Pool backstop 40 at 218.25 = 8,730.00; Dev's proceeds 21,870.00 | exact | to the unit |
| Zed's bond 86 → pool | exact | epoch `bonds` |
| Penalty 276.51 (92.17 × 3), 8,940.64 repays Priya, debt after 4,578.38 | within 2 cents / $0.50 / $0.50 | identity D − (1 − λ)P to the unit |
| Shortfall 672.59 paid by the pool; senior made whole | within 5 cents | identity shortfall = debt − 21,870.00 to the unit; one `Shortfall` event, reserve 0, senior loss 0 |
| Cash in = cash out 31,087.15 | exact identity | repaid + penalty = Aria + pool, to the unit |
| Pool NAV after 99,988.23 | 99,988.34 | within 15 cents (the book's actual R-09 accrual and the cents above); INV-POOL-01 exact |
| Share price 0.9998823, Sara 9,998.82 | 0.9999662, 9,999.66 | identity Sara = 10,000 × sharePriceAfter to the unit. R-09: Umar's Wednesday deposit is minted at the NAV that already holds Mon–Wed's risk fee (19,991.72 shares, not 20,000). With Umar in on Monday (`test_scenarioB_withTheDocsShareCount`) the chain gives 0.9998834 and **9,998.83** |

### 4.3 Gas (anvil, `forge test --gas-report`, Solidity stand-in engine)
`openSettlement` (1 borrower) ≈ 447k median, 872k max; `SettlementAdapter.finalize` ≈ 661k median (fill + settle one
position), 838k max (pool advance); `SolverAuction.bid` 42k–109k; `claimRedemption` ≤ 121k. Devnode figures follow with item E.

## 5. Deviations from the Build Guide
- §8.8 / §14.2: `openSettlement` refuses CLOSED as well as HALTED and CORP_ACTION (the market's INV-LIQ-01 flag rules
  apply); EXTENDED allows only uncovered HF < 0.92 (EMERGENCY kind) → ADR-0111 §3, §6 item 1.
- §8.8: a settlement id is the market lot id; lots exist only inside `openSettlement` (a direct `flagForAuction` on
  the NAV market reverts). The adapter settles every position in `finalize`. The fund's REOPEN is ended by the adapter,
  and the auction house refuses non-equity assets → ADR-0111 §2.
- §8.6.2: `fallbackAdvance` pays min(qty × floor, freeCash), like `backstopBuy` (ADR-0110 §6) → ADR-0111 §2.
- §15.1: the concentration limit is 35 % of the pool's capacity budget (u_max × J) per asset, over covered policies →
  ADR-0112.
- F-4.5e: GDA sales only in REGULAR and never below (1 − κ) × V (QA-03) → ADR-0113, §6 item 2.
- Appendix B: `SettlementFinalized` is added for every settlement; `RedemptionClaimed` comes from the pool with the
  epoch and P&L; `RedemptionRequested` is new → ADR-0111 §1.

## 6. Spec issues found
1. **§8.8 vs §14.2:** §8.8 forbids `openSettlement` only in HALTED and CORP_ACTION; INV-LIQ-01 forbids every liquidation in
   CLOSED too. Implemented the stricter rule (a fund's NAV does not move while CLOSED, so nothing is lost). Please align
   §8.8.
2. **F-4.5e is silent on closures.** Emission and decay run while the market is shut, so a Friday listing sells at ~13 % of
   V on Monday 09:30 (QA-03). Implemented: no GDA sale outside REGULAR and a (1 − κ) × V floor. Alternative: pause the
   GDA clock outside REGULAR. PM ruling requested.
3. **§15.1 "35 % of pool worst-loss from one asset"** read literally fails the first policy of every epoch and makes the
   one-asset NAV stack unable to sell cover. Implemented against u_max × J (ADR-0112). Please restate.
4. **Scenario B's week vs R-09 / R-10.** (a) Under R-10 a Wednesday withdrawal request is paid after Wednesday night's
   epoch; the test requests on Friday before the Bell window. (b) Under R-09 Umar's Wednesday deposit buys the Mon–Wed
   fee receivable, so the doc's 20,000 shares at $1.00 and Sara's 9,998.82 hold only with a Monday deposit
   (9,998.83 on chain). (c) The doc's Monday debts carry ≈ 7.016 days of interest and its Thursday lot is rounded to
   20.2287. Suggest Guide v1.3 restate S-B's Sara as "10,000 × sharePriceAfter" or move Umar to Monday.
5. **G-13 precision:** Appendix A's 7,326.43 uses a lot of 20.2287; F-4.5a gives 20.22863 (7,326.41). Suggest 7,326.41.

## 7. Interfaces changed or published
- **ABI v3 frozen** (`deployments/abis/v3/`, `make abis-check`): additive over v2 except 4 listed breaks (ADR-0111 §1).
  After the READY, one error was added (`SeqStepTooLarge`, QA-08), and two pool functions (`beginBellBatch`,
  `endBellBatch`, onlyMarket, ADR-0114). Both additions are additive; `abis-check` passes.
- Events for J10 / the indexer: `SettlementOpened`, `SolverBid`, `SettlementFilled`, `FallbackAdvanced`,
  `SettlementFinalized`, `SettlementPositionsSettled`, `NavReopenCompleted`, `SolverRefunded`; pool
  `RedemptionRequested`, `RedemptionClaimed`, `ConcentrationLimitSet`.
- Behaviour other roles see (board ANSWER 16:06): open bids below the fixed reserve revert; `gdaBuy` needs REGULAR and
  costs ≥ (1 − κ) × V; `resellInventory` only in REGULAR; a direct `flagForAuction` on the NAV market reverts.
- Book: `nav.settlement` is the real adapter, new key `nav.solverAuction`.

## 8. Known gaps and TODOs
- **Item E** (devnode): run `make devnode-integration` (phase 6 NAV), post a DECISION, redeploy the main book with the real NAV settlement. Waits for BE-backend's final S3 READY.
- **J3 prototype (ADR-0114, in the tree):** `enforceBell` brackets a Bell batch, and the pool caches the uncovered bound. `BellBatchTest` proves it equals the full computation to rounding and never undercuts it. The gain must be measured with `make devnode-gas` on the Stylus engine: keep it if the batch at least doubles (J3 10 → ≥ 20), otherwise revert it. ADR-0114 gets written with the numbers.
- QA-09 (ADR-0113): QA-sec's gas sweep needs a coverage-context skip in their file (board 18:08).

## 9. Needs from the user or the PM
- PM rulings on §6 items 1–5.
- QA-sec: coverage-context skip for `test_enforceBell_gasCannotForceASale` (board 18:08).
- Open since S3: vendor key rotation; ADR-0009 D2 / D3.

## 10. How to verify from a clean checkout
```bash
git clone <repo> && cd credence-finance
make contracts-build contracts-test risk-test contracts-coverage abis-check
cd contracts
forge test --match-contract "ScenarioBWeekTest|NavSettlementScenarioTest" -vv     # S-B figures, NAV scenario
forge test --match-contract SettlementInvariantsTest                            # 5 invariants, 256 x 128
QA_FINDINGS=1 forge test --match-path 'test/security/**'                          # every QA finding test passes
cd .. && make devnode-integration                                                 # needs the devnode (phase 6: NAV)
```
