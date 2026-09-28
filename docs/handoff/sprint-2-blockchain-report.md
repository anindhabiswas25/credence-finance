# Sprint 2 report · BE-chain

Date: 2026-09-28 · Session model: Claude Opus 5.5 (resumed after the rate-limit cutoff) · Commits: `dda7b1a..HEAD`
(`c1b32ea`, `274d1c0` before the cutoff).

## 1. Summary
The Risk Engine is complete and live on the devnode. The full engine is two fragments, so it runs as two Stylus
programs behind a Solidity router (R-24). The router serves every `IRiskEngine` function. The differential shows
0 mismatches at 10,000 inputs per function across all 8 math functions, and both programs build byte-identically
from two different checkouts. The lending core is built and tested: market, Senior Vault, rates, tips, treasury,
reserve, σ oracle, timelock and guardian. The tests cover 10 invariant suites at 256 × 128, scenario A Monday to the
Friday Bell to the cent, and a devnode integration where the real market calls the real Stylus engine and matches
`risk-cli`. Coverage is ≥ 98.7% on all four gated directories. What is not met: two of the five §8.9.3 gas ceilings
(`coverLossVector`, `poolCapacity`), explained in §5 and ADR-0108. QE's calibrated bundle is loaded on the devnode
engine, and BE-backend's items are all delivered.

## 2. Acceptance checklist

| # | Item | Status | Proof (command + key output) |
| --- | --- | --- | --- |
| 1 | `make contracts-build contracts-test risk-test` passes from a clean clone; `make contracts-coverage` ≥ 95% on `src/core`, `src/governance`, `src/clock`, `src/oracle` | ✅ | `git clone … && make contracts-build contracts-test risk-test` → exit 0 in 5 min 3 s (clean clone of `6e485ae`; 152 Solidity tests passed, 0 failed; re-run at `c57a1dd`: 153 passed, 0 failed, 19 suites); `make contracts-coverage` → core 99.17%, governance 100.00%, clock 99.19%, oracle 98.70% (clean clone, exit 0) |
| 2 | A1–A5 delivered, each with a READY before the main build work | ✅ | Board: A1 09:45, A5 10:20 (before the cutoff), A2 11:22, A3 11:31, A4 11:36; `make risk-validate-set`, `make risk-py-test` (3 passed), `make risk-wasm-test` (node + web builds passed) |
| 3 | Every `IRiskEngine` function live on the devnode; differential 10k per function with 0 mismatches; gas within the ceilings or explained | ⚠️ gas partly | `make stylus-abi-check` (both programs == their router interfaces, both directions); `make stylus-diff DIFF_N=10000` → 8 functions × 10,000 cases, **0 mismatches**; gas: safeLtv 86,465 / 100k ✅, quoteCover 90,764 / 250k ✅, clear 158,954 / 200k ✅, coverLossVector 331,861 / 300k ❌, poolCapacity (10 markets) 2,019,551 / 600k ❌, explained in §5 / ADR-0108 §5; `make devnode-integration` → market ↔ engine == risk-cli |
| 4 | Invariant suites of E pass at 256 × 128; INV-REPAY proven with a reverting engine and oracle | ✅ | `cd contracts && forge test --match-contract MarketInvariantsTest` → 10 invariants PASS, runs 256, calls 32,768; `repayWhileBroken` runs with the engine, oracle **and clock** reverting |
| 5 | Scenario A Monday-to-Bell passes to the cent | ✅ | `forge test --match-contract ScenarioAWeekTest` → debts 60,049.93 / 67,028.99 / 55,535.10, LTVs 60.05 / 74.48 / 74.05%, G-10 / G-11 cures to the cent, G-17 lot 96.5454, $35.95 cover, Bell, pre-close settlement |
| 6 | G-06..G-11 and G-17 pass with the v1.1 inputs | ✅ | `cargo test -p credence-risk-core --test golden` → 22 passed (full-precision inputs, doc figures exactly) |
| 7 | R-23 NAV tests pass | ✅ | `forge test --match-contract "NavStalenessTest\|OracleAdapterTest"` → normal weekend, 3-day holiday weekend, missed single strike (CLOSED), missed double strike (HALTED) |
| 8 | Report with ADRs for every deviation | ✅ | this file; ADR-0106 (set format), ADR-0107 (lending core), ADR-0108 (engine split, repro, gas, tooling) |

## 3. What was built
- `crates/risk-core/src/setfile.rs` (feature `files`): the ADR-0106 scenario-set / joint-set / risk-bundle format,
  covering parse, build, validate, hashing and file helpers. `gap_factor_at` gives F-4.2 at full precision.
  `mul_div` takes a 256-bit fast path (bit-identical).
- `crates/risk-cli`: `validate-set <file>`, `build-set`, `build-joint`.
- `crates/risk-py`: the Python module `credence_risk` (PyO3, abi3). It covers every function of QE's `Engine` protocol
  in the same argument order, plus `ScenarioSet`, `load_set_file`, `load_joint_file`, `load_bundle`,
  `validate_file`, `build_set` and `build_joint`. `make risk-py-develop` / `risk-py-test`.
- `crates/risk-wasm`: `@credence/risk-wasm`, one package with Node and web builds, `bigint` API; the Bell quote and
  the previews. `make risk-wasm` / `risk-wasm-test`.
- `crates/credence-bindings`: alloy `sol!` over the v1 ABIs, 19 contracts.
- `stylus/risk-engine` (PricingEngine) and `stylus/auction-math` (AuctionMath): the two programs.
  `contracts/src/risk/RiskEngineRouter.sol` and `IStylusPrograms.sol`: the `IRiskEngine` in front of them.
- `contracts/src/core`: `CredenceMarket` with its linked libraries `market/{MarketLib, BorrowLogic, CoverLogic,
  LiquidationLogic}`, plus `SeniorVault`, `KinkedRateModel`, `KeeperTips`, `Treasury` and `ProtocolReserve`.
- `contracts/src/governance`: `CredenceTimelock`, `CredenceGuardian`. `contracts/src/oracle/SigmaOracle.sol`.
- `contracts/src/oracle/OracleAdapter.sol`: R-23 NAV freshness in USBANK strikes.
- `contracts/script`:
  - `DeployCoreLocal.s.sol` (`make local-deploy-core`)
  - `LoadScenarioSet.s.sol` with `plan()`, and `load_risk_bundle.sh` (`make risk-load-set`)
  - `devnode_integration.sh` (`make devnode-integration`)
  - `DeployClockLocal.s.sol`, which wires the clock again
- `stylus/risk-engine/scripts`: `deploy.sh` (router + two programs, `ENGINE_BOOK`), `abi-check.sh` (two programs,
  two directions), `stylus-ws.sh` (lock refresh, path remapping) and `repro.sh` (`make stylus-repro`).
- `stylus/risk-engine-diff`: every math function, a dedicated engine per run, `--only` groups, gas with CI limits.
- Tests:
  - `test/unit/{CredenceMarket, CredenceMarketPaths, SigmaOracle, TipsTreasuryReserve, Governance, LoadScenarioSet}`
  - `test/invariant/{MarketHandler, MarketInvariants}`
  - `test/scenario/{ScenarioAWeek, NavStaleness}`
  - mocks: `MockRiskEngine` (ports of the lot and Bell math), `MockUnderwriterPool`, `MockAuctionHouse`,
    `MockMarketClock`, `MockMarketOracle`
- CI:
  - `rust.yml`: a `bindings` job, a `stylus-repro` job, and the stylus job gains `stylus-diff` + `devnode-integration`
  - `differential.yml`: nightly, 1M per function, four parallel groups
  - `contracts.yml`: coverage over four directories

## 4. Test results
- Solidity: `forge test` (clean clone at `c57a1dd`), 153 tests passed, 0 failed, across 19 suites:
  - 10 lending-core invariants (INV-LIQ-02 checked inside the LIQ suite) plus the S1 clock invariants, at 256 × 128
  - `ScenarioAWeek`, `NavStaleness`, `ClockWeek`
- Rust: risk-core golden 22, props 9, unit 10; risk-cli 4; bindings 1; Stylus PricingEngine 3, AuctionMath 2.
  risk-py smoke 3, risk-wasm smoke on 2 builds.
- Differential (`make stylus-diff DIFF_N=10000`, dedicated devnode engine, 208 s):

  | Function | Cases | Revert cases | Mismatches |
  | --- | ---: | ---: | ---: |
  | safeLtv | 10,000 | 307 | 0 |
  | bellStatus | 10,000 | 307 | 0 |
  | quoteCover | 10,000 | 307 | 0 |
  | coverLossVector | 10,000 | 0 | 0 |
  | poolCapacity | 10,000 | 0 | 0 |
  | liquidationLot | 10,000 | 475 | 0 |
  | precloseLot | 10,000 | 718 | 0 |
  | clear | 10,000 | 199 | 0 |

- Coverage (`make contracts-coverage`): src/core 959/967 = 99.17%, src/governance 104/104 = 100%, src/clock
  367/370 = 99.19%, src/oracle 456/462 = 98.70%.
- Stylus sizes (compressed, one fragment each, activation checked): PricingEngine 22,416 B, AuctionMath 24,219 B.
  Reproducible: `make stylus-repro` gives identical sha256 from two clones.
- Contract sizes: CredenceMarket 21,257 B (the logic libraries 7.5 / 10.6 / 14.3 KB), CredenceGuardian 7.3 KB,
  SigmaOracle 5.1 KB.
- Devnode integration (`make devnode-integration`): a real borrow through the market, then σ through `SigmaOracle`.
  After that, `safeLtv` = 0.6903296, `bellStatus` = NEEDS_ACTION with repay 575.088205, and `quoteCover` = 3.807254 /
  1.627679 / 65.107147, all equal to risk-cli.

## 5. Deviations from the Build Guide
- **§8.9.3 R-24 split:** capacity (`coverLossVector`, `poolCapacity`, joint columns) sits in the second program
  (AuctionMath), not in the PricingEngine. The PricingEngine with capacity is 26.7 KB, which is two fragments.
  ADR-0108 §1.
- **`IRiskEngine`:** `liquidationLot`, `precloseLot` and `clear` changed from `pure` to `view`, because the router
  forwards them. Selectors are unchanged. ADR-0108 §2.
- **Gas ceilings:** `coverLossVector` is 331,861 against a 300k ceiling, and `poolCapacity` (10 markets) is 2,019,551
  against 600k. The cost is exact 256-bit mul-div per scenario per market in WASM, plus the router hop. The faster
  `u128` path does not fit AuctionMath's fragment. CI enforces a regression limit (measured + 10%) for these two.
  ADR-0108 §5.
- **Root `Stylus.toml`:** not added. The generated build workspace stays because it needs the nightly toolchain and
  `wasm32` members only. ADR-0108 §4.
- **§8.4 file layout:** the market is split into linked libraries to fit 24 KB, and compiled with optimizer runs 200.
  ADR-0107 §1.
- Rules the guide leaves open (ADR-0107):
  - money-flow conventions between contracts
  - zero-debt collateral withdrawal allowed in any state
  - an empty lot releases 0
  - the lot size cap of 200 positions
  - SigmaOracle wired once to its engine

## 6. Spec issues found
1. **G-10 / G-11 / G-17 vs R-08.** Appendix A states the cures and the pre-close lot at the debt at the Bell. R-08
   says every closure check uses the projected debt. So the market's scenario A figures are slightly higher than the
   doc's: Maya's lot is 96.92 TSLA instead of 96.5454, and Priya's cure uses D × (1 + 7.29% × 3/365). The test
   asserts both sets of numbers. The PM should say whether Appendix A should carry the projected figures.
2. **INV-COV-01 vs `enforceBell`.** "No cover after `bellAt`" contradicts auto-cover, which runs only after `bellAt`.
   Implemented as: a borrower buys before `bellAt`; auto-cover runs in [`bellAt`, close). ADR-0107 §6.
3. **§8.9.3 gas ceilings** for `coverLossVector` and `poolCapacity` can't be met in a one-fragment build (see §5).
4. **Withdrawal floor HF ≥ 1.05 (§8.2.2).** With LT ≥ maxLtv + 3 pp and maxLtv ≤ 0.75, the LTV limit always binds
   first. The HF floor only matters for tight parameters such as the NAV market's 90/93.
5. **Scenario A keeper tips.** The doc pays $3 / $5 per keeper call; §8.10 pays 2 USDC per processed position.
   Implemented per §8.10.
6. **INV-DEBT-01 direction.** Each position's debt rounds up, so Σ debt can exceed `totalBorrowAssets` by up to one
   unit per position. The guide states Σ debt ≤ B ≤ Σ debt + n. The test asserts |Σ debt − B| ≤ n.

## 7. Interfaces changed or published
- v1 ABIs (`deployments/abis/v1`, 47 files, `make abis-check` passes):
  - implementation ABIs of the lending core, governance, `SigmaOracle` and `RiskEngineRouter`
  - `IRiskEngine`: + `jointHash`, + `sigmaAt`; the auction functions become `view`
  - `ISigmaOracle`: + `initializeWiring(address)`
- ADR-0106 file formats (QE produces them). risk-py and risk-wasm APIs (board READYs A3 and A4).
- Address book:
  - `equity` / `nav` stacks with `pool` / `auctionHouse` / `settlement`
  - `shared.riskEngine` = the router; `stylus.riskEngine` / `stylus.auctionMath` = the programs
  - the S1 flat keys are still written; BE-backend no longer reads them, so they can go in S3
- `credence-bindings` crate. Frozen for S2: yes. S3 adds only the pool, auction house and settlement implementations.

## 8. Known gaps and TODOs
- Two gas ceilings not met (§5).
- The 1M-per-function nightly differential is written (`differential.yml`) but has not run in CI yet; locally it ran
  at 10k per function.
- The devnode calendar starts 2026-10-01, so the real-hours devnode market is CLOSED until then. The integration run
  uses a synthetic calendar in its own book.
- Pool / auction house / settlement are local stand-ins until S3. The auction house must treat a lot that released 0
  as settled (ADR-0107 §7).

## 9. Needs from the user or the PM
- A decision on the two gas ceilings: raise them, wait for multi-fragment programs, or fund a third program.
- A ruling on spec issues 1 and 2 (Appendix A at projected debt; the wording of INV-COV-01).

## 10. How to verify from a clean checkout
```bash
git clone <repo> credence && cd credence
make contracts-build contracts-test risk-test          # Solidity + risk-core + risk-cli + bindings
make contracts-coverage                                  # ≥ 95% on src/core, src/governance, src/clock, src/oracle
make abis-check stylus-abi-check                         # ABIs additive; programs == router interfaces
make stylus-test risk-py-test risk-wasm-test risk-validate-set
make stylus-repro                                        # two clones → identical WASM (needs the pinned nightly)
make infra-up                                            # devnode (BE-backend's target)
make stylus-check                                        # both programs one fragment + activation
make devnode-deploy-engine && make risk-load-set RISK_BUNDLE=calibration/out/risk-bundle-889d50e4.json
make stylus-diff DIFF_N=10000                            # 8 functions × 10k, 0 mismatches, gas report
make devnode-integration                                 # market ↔ Stylus engine == risk-cli
make local-deploy-core                                   # the whole protocol on the devnode
```
