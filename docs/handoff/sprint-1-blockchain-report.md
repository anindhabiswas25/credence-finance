# Sprint 1 report · BE-chain

Date: 2026-09-28 · Session model: Claude Opus 5.5 (`claude-opus-5-5`) · Commits: `d1f4f1a..HEAD` (BE-chain commits: `d1f4f1a`, `eed0f6f`, `558e2d7`, `c542e3d`, `0b8f6bf`, `d04ce51`, `3523bc9`, `636813f`, `202a962`, plus this report)

## 1. Summary

The on-chain foundation for Sprint 1 is built and tested.
- **Interfaces:** v0 of every §8 interface and its ABI was frozen first, and the backend built its relayer, keeper, SDK and indexer against it.
- **Clock and price layer:** CalendarStore, AssetClock, CredencePriceFeed, OracleAdapter, SequencerHealth and UniV3TwapSource are implemented and tested. So are the four testnet assets. Coverage is 99.2% of lines on `src/clock` and 99.0% on `src/oracle`, and all five invariant suites pass at 256 runs × depth 128.
- **Real calendar:** The clock was driven through two real weeks of BE-backend's generated XNYS calendar: Thanksgiving 2026 (a holiday Thursday, then a 13:00 early close) and the Good Friday 2027 closure (4 days).
- **Risk math:** `credence-risk-core` implements F-4.2 to F-4.6 with the golden vectors G-01…G-22. `risk-cli` exposes every function as JSON.
- **Stylus spike:** The Stylus Risk Engine is deployed and activated on the local nitro-devnode: 23,581 bytes compressed, one fragment. A 10,000-input differential per function (30,000 calls in total) found **0 mismatches**.

What does not work yet:
- Four golden vectors can't match the guide's figures, because the guide's own inputs don't produce them (§6). The tests assert the correct values instead.
- The Stylus build needs a pinned nightly to fit one code fragment on ArbOS 40.
- The measured Stylus gas is far above the guide's estimates.

## 2. Acceptance checklist

| # | Item | Status | Proof (command + key output) |
| --- | --- | --- | --- |
| 1 | `make contracts-build contracts-test risk-test` passes from a clean checkout | ✅ | Fresh `git clone` of `202a962` into a scratch dir, then that exact command: `EXIT 0`, `real 3m38.8s`, `Ran 10 test suites … 102 tests passed, 0 failed`. Solidity **102 passed, 0 failed** (97 unit / fuzz / scenario + 5 invariant). Rust: golden **22/22**, proptests **9/9**, risk-core unit **6/6**, risk-cli **3/3**. |
| 2 | Interfaces v0 and ABIs committed; a `READY` entry on the board | ✅ | `d1f4f1a`: 27 interfaces in `contracts/src/interfaces/`, `Types/Errors/Events.sol`, 27 ABIs in `deployments/abis/v0/`. BOARD 2026-09-27 21:50 READY. Implementation ABIs added (22:40 READY). `IRiskEngine` gained 2 views, additive (00:05 READY). |
| 3 | G-01…G-22 pass in `cargo test -p credence-risk-core` | ⚠️ | `cargo test -p credence-risk-core --test golden` → `22 passed`. G-10, G-11, G-17 and G-22 assert the values their stated inputs produce, not the doc's figures. The tolerances to the doc and the independent closed form are in ADR-0102 §1; see §6. |
| 4 | INV-CLK, INV-ORA, INV-FAIL suites pass at 256 runs × depth 128 | ✅ | `make contracts-invariant` → `invariant_CLK01…, CLK02…, CLK03…, FAIL01…, ORA01… (runs: 256, calls: 32768, reverts: 0)`. Mutation-checked: disabling the guardian input fails CLK-02, and dropping feed-closed handling fails FAIL-01. |
| 5 | Full-week clock scenario passes, incl. holiday and early close | ✅ | `forge test --match-path test/scenario/ClockWeek.t.sol` → `test_thanksgivingWeek`, `test_goodFridayWeek`, and `test_sixMonthsOfSessions_oneClosurePerClose` (126 real sessions). |
| 6 | Stylus spike deployed on the local devnode; 10k-input differential reports 0 mismatches; size and gas in the report | ✅ | `make devnode-deploy-engine` → `engine at 0xe547…42ea (23581 bytes compressed)`. `make stylus-diff` → `clear 10000/0 mismatches, liquidationLot 10000/0, safeLtv 10000/0` (985 of them revert cases, compared byte for byte). Gas: §4. |
| 7 | `forge coverage` ≥ 95% lines on `src/clock` and `src/oracle` | ✅ | `make contracts-coverage` → `ok src/clock lines 365/368 = 99.18%`, `ok src/oracle lines 388/392 = 98.98%`. |
| 8 | This report, with every deviation backed by an ADR | ✅ | ADR-0101 (interfaces), ADR-0102 (risk-core vectors, toolchain, Stylus build), ADR-0103 (clock / oracle behaviour). |

## 3. What was built

**Toolchain / repo**
- `rust-toolchain.toml`: 1.95.0 + wasm32 (ADR-0102 §2). `.tool-versions`.
- Root `Cargo.toml` (with `[workspace.dependencies]` and `profile.stylus`) and `Cargo.lock`. BE-backend appends its members.
- `contracts/foundry.toml`, `remappings.txt`, `.gitignore`. Dependencies are installed at pinned tags by `make contracts-deps`: OZ v5.6.1, forge-std v1.16.2, solady v0.1.26.
- `mk/contracts.mk`: 24 targets, each with a `##` help comment. `make help` lists them.
- `.github/workflows/contracts.yml`: fmt, build with sizes, an ABI-drift check, tests (ci profile), the coverage gate, gas snapshot `--check`, slither.
- `.github/workflows/rust.yml`: fmt, clippy `-D warnings`, the golden / proptest / engine tests, the engine ABI parity check. It also starts a devnode, runs `cargo stylus check`, deploys, and runs the 10k differential.

**Solidity** (`contracts/src/`)
- `libraries/`: `Types.sol`, `Errors.sol` (`ICredenceErrors`), `Events.sol` (per-component event interfaces). Plus `WadMath`, `SharesMath` and `PackedInt` (4 × u64 and 16 × i16, the same layout as risk-core), and `ClockLib` (restrictiveness).
- `interfaces/`: 27 interfaces covering every §8 component, including `ICredencePriceFeed`, `INavSource`, `ITwapSource`, `IProtocolReserve`, `ITreasury`, `ICredenceGuardian`, `ISolverAuction`, `IComplianceRegistry` and `IFaucet`.
- `clock/CalendarStore.sol`: an append-only session store with validation, `coverageEnd`, and a binary-search `findSession`.
- `clock/AssetClock.sol`: the full §8.2.2 poke (steps 1–10). It covers:
  - exactly-once closure accounting, even across missed pokes;
  - the provisional-to-final reference price, and halt / guardian / corporate-action closures;
  - guardian restrictions that only restrict, and the R-20 sequencer-gap extension;
  - `closureDays` (R-07) and `markReopenComplete`, gated to the auction house or settlement adapter.
- `oracle/CredencePriceFeed.sol`:
  - EIP-712 `submit`: m-of-n, sorted signers, no duplicates, low-s.
  - Per-asset `seq`, a 5 s skew bound, and a 96-entry ring with `twap`.
  - Official open / close storage, and a NAV history.
- `oracle/OracleAdapter.sol`:
  - F-3.2 valuation by state, `feedHealth` (including `statusHalted`), and the open-print rule with the 15-minute wait and the TWAP fallback.
  - The post-halt open, the stress flag, the shallow-pool rule, the NAV rules, and `sharesPerToken` capped at ×10 / ÷10.
- `oracle/SequencerHealth.sol`: the gap detector. `oracle/UniV3TwapSource.sol`: the mean-tick TWAP via `expWad` (no TickMath port) and ±2% depth. Unit-tested against a mock pool; not deployed.
- `testnet/`: `CredenceStockToken` (issuer ratio, freeze, compliance hook, capped minters), `CredenceTreasuryFund` (allowlist, NAV, `redemptionsGated`, ERC-7540-style request / fulfil / claim), `ComplianceRegistry`, `Faucet` (24 h per (address, token)), and `IssuerRoles`.
- `script/DeployClockLocal.s.sol`: a local-only deploy of the whole clock / price stack and the test assets. `script/make_calendar_fixture.py` and `script/check_coverage.py`.

**Tests** (`contracts/test/`)
- `unit/`: AssetClock (21), OracleAdapter (20), CredencePriceFeed (17), Libraries (14), TestAssets (10), UniV3TwapSource (5), CalendarStore (5), SequencerHealth (2). Fuzz tests are included in those counts.
- `invariant/`: `ClockHandler` drives the real stack with 10 actors. `ClockInvariants.t.sol` holds the 5 invariants.
- `scenario/ClockWeek.t.sol`: the real-calendar weeks.
- `mocks/`: MockAssetClock, MockOracle, MockProbeToken, MockTwapSource, MockUniV3Pool, MockERC20.
- `fixtures/`: slices of BE-backend's calendar JSON, same shape and byte-identical encoding.

**Rust**
- `crates/risk-core`: no_std. Modules `fixed` (512-bit mul-div, packing), `scenarios` (`ZSource`; `SliceZ` / `PackedZ`), `safe_ltv` (plus cures, bell status, the σ rate limit), `premium`, `capacity` (loss vector, uncovered bound, `pool_capacity`), `liquidation` (F-4.5a/b/d), `clearing` (pro-rata ties, R-05) and `rates`. Tests: `tests/golden.rs` and `tests/props.rs`.
- `crates/risk-cli`: the `risk-cli` binary. 21 commands, JSON in → JSON out, and `--abi` output for Foundry FFI.
- `stylus/risk-engine`: `safeLtv`, `liquidationLot`, `clear`, `setScenarioSet` (checks ascending order, stores the keccak), `setParams`, `setSigmaFloor`, `updateSigma` (the R-15 rate limit), plus views and the timelock / sigma-oracle gates.
  - `scripts/stylus-ws.sh` builds the Stylus workspace; `scripts/deploy.sh` deploys and activates through the StylusDeployer; `scripts/abi-check.sh` checks engine ↔ `IRiskEngine` parity; `scripts/devnode.sh` checks for a devnode.
- `stylus/risk-engine-diff`: the §14.3 differential harness. Reproducible seed, revert payloads compared, mismatches written to `crates/risk-core/tests/regressions/`, and a gas report.

## 4. Test results

**Solidity** (`make contracts-test`)

| Suite | Result |
| --- | --- |
| Invariants (256 × 128) | 5 passed (32,768 calls each, 0 reverts) |
| AssetClock | 21 passed |
| OracleAdapter | 20 passed |
| CredencePriceFeed | 17 passed |
| Libraries | 14 passed |
| TestAssets | 10 passed |
| UniV3TwapSource | 5 passed |
| CalendarStore | 5 passed |
| ClockWeek scenarios | 3 passed |
| SequencerHealth | 2 passed |
| **Total** | **102 passed, 0 failed, 0 skipped** |

**Coverage** (`make contracts-coverage`):

| Scope | Lines | Statements | Branches | Functions |
| --- | --- | --- | --- | --- |
| AssetClock | 99.06% | 98.46% | 91.86% | 100% |
| CalendarStore | 100% | 100% | 100% | 100% |
| CredencePriceFeed | 98.50% | 98.80% | 100% | 100% |
| OracleAdapter | 99.00% | 98.81% | 98.28% | 100% |
| SequencerHealth, UniV3TwapSource, libraries, testnet assets | 100% (IssuerRoles: 95.2% of statements) | | | |
| All sources | 99.33% | | | |

**Gas** (from the gas snapshot / `--gas-report` on the scenario suite):

| Call | Min | Avg | Max |
| --- | --- | --- | --- |
| `AssetClock.poke` | 105k | 136k | 182k (a close + reference + open print in one poke) |
| `CredencePriceFeed.submit`, one report, 2 signatures | 57k | 72k | 115k |
| `OracleAdapter.valuationPrice` | 35k | 43k | 49k |
| `feedHealth` | 28k | 33k | 36k |

`CalendarStore.appendSessions` costs about 25.7k gas per session. `.gas-snapshot` is committed (96 entries).

**Rust**

| Command | Result |
| --- | --- |
| `cargo test -p credence-risk-core` | unit 6/6 · golden 22/22 · proptests 9/9 (2,000 cases each) |
| `cargo test -p credence-risk-cli` | 3/3 |
| `make stylus-test` | engine TestVM 3/3 |
| `make risk-lint` | clean: rustfmt, clippy `-D warnings` on all 4 crates |

G-22 printout:

```text
G-22 engine: E[L] 2144381 ES 85775235 premium 4394513
G-22 closed form: E[L] 2.1444 ES 85.7745 premium 4.3945; doc: 2.26 / 90.51 / 4.64
```

**Stylus**
- `make stylus-check` → `contract size: 23.6 KB (23581 bytes)`, one fragment, data fee 0.000151 ETH.
- `make stylus-abi-check` → all 18 functions and errors match `IRiskEngine`.
- Differential (`make stylus-diff`, seed 20260927, 50 s): clear 10,000 cases / 199 revert cases / 0 mismatches; liquidationLot 10,000 / 475 / 0; safeLtv 10,000 / 311 / 0 (across 20 on-chain re-randomised sets, σ and α).
- Gas per call (`eth_estimateGas`, including the 21k intrinsic cost and calldata, L1 price 0): `safeLtv` (N = 3,000) **80,719**, `liquidationLot` **71,295**, `clear` (64 bids) **143,618**. Caching the program (`cargo stylus cache bid`) did not change these numbers.

## 5. Deviations from the Build Guide

| Guide section | What I did instead | Why | ADR |
| --- | --- | --- | --- |
| §6.1 Rust 1.91.0 | Pinned 1.95.0 | alloy 2.5 needs ≥ 1.94.1 (BE-backend REQUEST) | ADR-0102 §2 |
| §6.1 Foundry v1.8.3 | Local runs used the installed forge 1.6.0 (v1.7.0). CI pins v1.8.3. | I didn't upgrade the forge the backend also uses mid-sprint | — (see §8) |
| §6.2 `forge install Uniswap/v3-core` | Not installed. UniV3TwapSource has a minimal pool interface and `expWad` pricing. | v3-core's math libraries need solc < 0.8 | ADR-0101 §9 |
| §6.2 Deps via `forge install` | `contracts/lib` is git-ignored and installed at pinned tags by `make contracts-deps` | Submodules would need a root `.gitmodules`, which is outside BE-chain's paths | ADR-0101 §9 |
| §8.9.2 stable Stylus build | The on-chain build uses `nightly-2025-08-01` with build-std / `panic_immediate_abort`, from a generated workspace (`target/stylus-ws`) | Fits one fragment (ArbOS 40). cargo-stylus needs a root `Stylus.toml` that no role owns. | ADR-0102 §3 |
| §8.3.1 `IPriceSource` | Added `lastRegular`; `INavSource`; `FeedHealth.statusHalted`; `openPrint` also returns `fallbackUsed` | Needed for a reference at the close, the NAV rules and fail-closed halts | ADR-0101 §4, ADR-0103 |
| §8.2.2 step 1, 3, 7, 8 | Reference / halt / reopen interpretations | Details and tests | ADR-0103 |
| Appendix B `BorrowPaused` event | Renamed `BorrowPausedByGuardian` | Clashes with the Appendix C error | ADR-0101 §6 |
| Appendix A G-10/11/17/22 | Tests assert the stated-input values | The doc figures don't follow from the stated inputs | ADR-0102 §1 |
| §14.1 coverage via `forge coverage` | `forge coverage --ir-minimum` | Without IR the contracts hit stack-too-deep | — (tooling) |

## 6. Spec issues found

1. **G-22 does not match its stated model.** The unit-variance t₃, C = 18,000, D = 13,500, σ = 4%, κ = 3%, τ = 3/365, u = 0 give E[L] = 2.1444, ES = 85.77, π = 4.394. The doc says 2.26 / 90.51 / 4.64. I checked this by independent numerical integration, and the engine matches it to $0.0001. No simple variant reproduces the doc's figures: κ additive gives 2.35; no κ gives 1.80; D_proj gives 2.15; κ = 3.5% gives 2.21. R-22's "closed-form" premiums ($4.64 etc.) inherit the same problem.
2. **G-10, G-11 and G-17 use a rounded safe LTV as input**, but their expected outputs come from the unrounded one. With the stated inputs: 2,896.79 (doc 2,896.78), 8,527.125 (8,527.09) and 96.5456 (96.5454). The fix is to state the inputs to 7+ digits, or to state the outputs from the rounded inputs.
3. **`BorrowPaused` is both an event (App. B, guardian) and an error (App. C).** They cannot share an ABI.
4. **NAV 50-hour halt vs a normal weekend (§8.3.2, Architecture §3.8).** NAV is published on business days at 17:00 ET, so on Monday morning it is about 64 h old (about 88 h after a 3-day holiday weekend). Under the stated rule every NAV market is HALTED each Monday until that day's NAV lands. The clock implements the rule as written. The PM should confirm this, or define the age in business days.
5. **§8.9.3 gas estimates** (< 15k for `safeLtv`) are about 5× below what I measured on the devnode (≈ 57k of execution after the intrinsic cost). They probably leave out the per-call Stylus program entry cost.
6. **§8.9.2 / §6.3 assume a stable-toolchain Stylus build.** On ArbOS 40 the engine only fits one fragment with nightly build-std (ADR-0102).
7. **§6.2 lists Uniswap v3-core** for a 0.8.30 project. Its math libraries don't compile on 0.8.
8. **§8.2.2 step 3 as written HALTs every asset at every close.** The official closing print is published after 16:00. This is handled with a provisional reference (ADR-0103 #1).
9. **§8.2.2 step 1 (R-20) as written accumulates a phase extension** over any quiet weekend, because `reopenPending` is true all weekend. It is implemented as time after `reopenAt` only (ADR-0103 #6).
10. **Charter gap:** a root `Stylus.toml` is needed by cargo-stylus, and no role owns it. The PM could assign it to BE-chain, which would remove the generated-workspace step.

## 7. Interfaces changed or published

- **Frozen v0:** `deployments/abis/v0/*.json`, 27 interfaces + `ICredenceErrors`, plus 10 implementation ABIs. The EIP-712 report digest, `sessionDate`, venue ids and batch rules are in ADR-0101.
- **Additive change after v0:** `IRiskEngine.timelock()` and `sigmaOracle()` (READY 00:05). No selector changed.
- **Behaviour change, no ABI change:**
  - A HALT or corporate-action closure without a reference now reaches REOPEN.
  - `closureDays` reverts before the first session.
  - One poke after downtime emits one `ClosureStarted` per missed close.
  - A `ReferenceUpdated` event follows each close once the official CLOSE lands.
  - All posted on the board (DECISION 01:10).
- **Local deployments** are git-ignored: `deployments/<chainId>.local.json` (`make local-deploy-clock`) and `deployments/devnode.engine.json` (`make devnode-deploy-engine`).

## 8. Known gaps and TODOs

- **Stylus engine scope:** only the S1 spike functions exist. `bellStatus`, `quoteCover`, `coverLossVector`, `poolCapacity`, `precloseLot` and `setJointColumn` are in `IRiskEngine` but not in the engine, so they revert with an unknown selector. That's S2. The math for all of them is already in risk-core and tested.
- **Stylus gas** is well above the guide's estimates. Profile it with `cargo stylus trace` in S2, and consider the program cache on testnet.
- **CI:** `contracts.yml` and `rust.yml` have not run on GitHub yet (there's no remote). I only validated their YAML. `slither` has not run locally. The `ci` profile (10k fuzz, invariants 512 × 256) has not run locally either; its length is untested against the 60-minute timeout.
- **Guide §5's `differential.yml`** (nightly, 1M inputs) is not created. `rust.yml`'s stylus job runs 10k per PR.
- **Foundry:** the local forge is 1.6.0 / v1.7.0, not the guide's v1.8.3. Nothing I used depends on 1.8 features.
- **Not in the S1 brief, not built:** `ChainlinkPriceSource` / `RedStonePriceSource` (mainnet adapters), `crates/risk-py`, `crates/credence-bindings`, and `gda.rs` (F-4.5e).
- **Deploy script:** `DeployClockLocal.s.sol` makes the deployer the timelock, guardian and issuer (local only; the script refuses 421614 and 42161). The testnet deploy with a Safe and timelock is S5.
- **Leftover toolchains:** the unused toolchains `1.91.0` and `nightly-2026-05-27` are still installed on this machine. They're harmless and can be removed with `rustup toolchain uninstall`.

## 9. Needs from the user or the PM

- **PM:** rule on spec issues 1, 2 and 4 (G-22 model, rounded golden-vector inputs, the NAV 50 h weekend rule).
- **PM:** assign the root `Stylus.toml` (issue 10), or accept the generated workspace.
- **PM:** confirm the nightly-toolchain Stylus build (ADR-0102 §3) for testnet, or plan for an ArbOS with multi-fragment programs.
- **User:** nothing blocks BE-chain. BE-backend's vendor-key BLOCKED entry doesn't affect these deliverables.

Global tools installed this sprint (exact commands):

```bash
rustup toolchain install 1.91.0 --profile minimal -c rustfmt -c clippy -t wasm32-unknown-unknown   # guide pin, later superseded
rustup toolchain install 1.95.0 --profile minimal -c rustfmt -c clippy -t wasm32-unknown-unknown
rustup toolchain install nightly-2026-05-27 --profile minimal -c rust-src -t wasm32-unknown-unknown   # tried, unused
rustup toolchain install nightly-2025-08-01 --profile minimal -c rust-src -t wasm32-unknown-unknown   # Stylus on-chain build
cargo +stable install --locked cargo-stylus@0.10.9
cargo +stable install --locked twiggy   # wasm size analysis
```

## 10. How to verify from a clean checkout

```bash
git clone <repo> credence-finance && cd credence-finance
make contracts-build contracts-test risk-test   # acceptance 1, 3, 4, 5 (installs pinned Solidity deps)
make contracts-coverage                        # acceptance 7: ok src/clock 99.18%, ok src/oracle 98.98%
make risk-lint stylus-test stylus-abi-check    # Rust hygiene + engine ABI parity

# Stylus spike (acceptance 6); needs docker, cargo-stylus 0.10.9 and nightly-2025-08-01 (commands in §9)
make infra-up                                  # BE-backend's devnode (+ StylusDeployer bootstrap)
make stylus-check                              # 23.6 KB, one fragment, activation ok
make devnode-deploy-engine                     # deploy + activate + constructor → deployments/devnode.engine.json
make stylus-diff DIFF_N=10000                  # "mismatches": 0, plus the gas report

# optional: the clock + price stack on a local chain
make local-deploy-clock LOCAL_RPC=http://127.0.0.1:8547
```
