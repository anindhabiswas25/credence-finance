# Sprint 2 brief · Senior Blockchain Engineer (BE-chain)

From: PM · Repo: `/home/asus/Project/credence-finance` · Target: local only (nitro-devnode / anvil). **No testnet deploy.**

## Context

Sprint 1 is **accepted**. Read `docs/handoff/sprint-1-pm-review.md` for the PM's verification results and a ruling on each of your spec issues. The guide is now **v1.1**: read its changelog, R-22 (the price floor at zero; your G-22 is correct and the guide was wrong), R-23 to R-26, and the updated Appendix A. The charter has new shared-machine rules (§2a), and a **Quant engineer (QE)** joins this sprint and depends on you early.

## Read first
1. `docs/team/TEAM_CHARTER.md` (§2 and the new §2a).
2. `docs/handoff/sprint-1-pm-review.md`.
3. `docs/CREDENCE_BUILD_GUIDE.md` v1.1: the changelog, §2 (R-01..R-26), §8.4, §8.5, §8.9, §8.10, §8.11, §9, §14, Appendix A.
4. `docs/handoff/BOARD.md`.

## Sprint goal
Complete the Risk Engine, and build the lending core: the market, the Senior Vault, rates, fees, the reserve and treasury, tips and governance. It must be tested to the same bar as S1, and it must be consumable by the backend and the quant.

## Work items

### A. Early deliverables for the other roles (first ~25% of the session, in this order; post a `READY` for each)
1. **Interface v1** (additive; note every change on the board):
   - `ReportAccepted` gains `uint8 marketStatus` (R-25).
   - Any ABI additions needed for the market, vault and governance (§8.4, §8.5, §8.10, §8.11).
   - Export the ABIs to `deployments/abis/v1/`, and keep `v0` untouched.
2. **Scenario-set file format** for QE (ADR). It is the JSON that `LoadScenarioSet.s.sol` and `setScenarioSet` / `setJointColumn` consume: packed words, `n`, `assetId`, `closureType`, `contentHash`, and how the on-chain `scenarioHash` is derived. Include an example file and a validator in `risk-cli` (`risk-cli validate-set <file>`).
3. **`crates/risk-py`**: PyO3 bindings (built with maturin) exposing every risk-core function QE needs for the backtest: `safe_ltv`, `quote_cover`, `cover_loss_vector`, `pool_capacity`, `liquidation_lot`, `preclose_lot`, `clear`, `settle_position` and the rates. Also expose a "load set from file" helper. It needs a smoke test and `make risk-py-develop`.
4. **`crates/risk-wasm`**: a wasm-bindgen build of risk-core for the TypeScript SDK and the API (the Bell quote and the UI previews), with a `make risk-wasm` target that emits a package the backend can depend on from `packages/sdk` (agree on the path on the board).
5. **One local address book:** `deployments/<chainId>.local.json` includes `shared.riskEngine`, and the separate `devnode.engine.json` is retired (charter §2a).

### B. Carry-overs from S1
- **R-23 NAV rule:** switch `OracleAdapter` / `AssetClock` NAV freshness to USBANK sessions (fresh / stale → CLOSED / invalid → HALTED), with tests for a normal weekend, a 3-day holiday weekend, a missed single strike, and a missed double strike.
- **Root `Stylus.toml`** is now yours. Remove the generated-workspace step if cargo-stylus allows it, or document why not.
- **Golden vectors:** update G-06..G-11 and G-17 to the v1.1 full-precision inputs. They should now match the doc figures without special-casing.
- **Local Foundry** to v1.8.3, per the charter §2a rule (post a DECISION first, because BE-backend's e2e uses forge too).
- `.github/workflows/differential.yml`: a nightly run with 1M inputs per function.
- **Reproducible Stylus artifact:** the PM's clean-clone build came out at 23,703 bytes, against your 23,581, so the build is not reproducible across checkouts. Make it byte-reproducible (pinned toolchain, deterministic paths, `--remap-path-prefix`, the cargo-stylus docker build), and add a CI check that two builds produce the same WASM hash.

### C. Full Stylus Risk Engine (§8.9)
- Implement every `IRiskEngine` function: `bellStatus`, `quoteCover`, `coverLossVector`, `poolCapacity`, `precloseLot`, `setJointColumn`, plus the S1 set. All loss math applies the R-22 zero price floor.
- Differential: 10k inputs per function per PR, with 0 mismatches.
- Gas: profile with `cargo stylus trace`, and add a CI check against the §8.9.3 ceilings. If a ceiling can't be met, explain why in the report.
- Size: if it exceeds one fragment, implement the split into `PricingEngine` + `AuctionMath` behind the same Solidity interface (R-24).

### D. Lending core (Solidity)
- `KinkedRateModel` as an **internal library** (no external call, P2).
- `CredenceMarket` (§8.4), complete, including `buyCover`, `borrowWithCover`, `enforceBell`, `flagForAuction`, `releaseLots`, `onAuctionCleared` and `settlePositions`. Program these against `IUnderwriterPool` / `IAuctionHouse` and test them with **mocks**; the real pool and auction house come in S3. Also the permission matrix per clock state, the guardian overlay, fee receivables (R-09), projected debt (R-08), cover eligibility with δ (R-03), the waterfall with the reserve, and `claimFees`.
- `SeniorVault` (§8.5): ERC-4626 with virtual and dead shares, supply and withdraw queues, caps, and the `requestRedeem` / `processQueue` / `claimRedeem` FIFO (R-17).
- `SigmaOracle` (2-of-3 EIP-712, `asOfDay` monotonic), `KeeperTips` (never reverts), `Treasury`, `ProtocolReserve`.
- `CredenceTimelock` (OZ `TimelockController`) and `CredenceGuardian` (only risk-reducing; 6-hour delayed unpause; haircut ≤ 10 pp for 7 days), wired through `initializeWiring` once.
- `script/DeployCoreLocal.s.sol`: deploys the clock/price stack, the engine address, the lending core and the test assets, lists NVDA/AAPL/TSLA/COIN/MSFT/SPY + TBILL, and seeds the vault. Local chains only.
- **`crates/credence-bindings`**: alloy `sol!` bindings generated from the v1 ABIs, for the keeper.

### E. Tests
- Unit, fuzz and invariants: **INV-MKT-01..03, INV-LIQ-01, INV-REPAY-01/02** (with the engine and oracle mocked to revert), **INV-WF-01, INV-COV-01, INV-SV-01, INV-DEBT-01, INV-GOV-01**.
- Handler actors: borrower, lender, keeper, guardian, time warp across real calendar sessions, and price shocks.
- Scenario test: **scenario A from Monday to the Friday Bell**. Rahul, Maya and Priya borrow; interest accrues; the Friday Bell cures and quotes match Appendix A (G-10, G-11), with premiums injected through `MockRiskEngine` at the doc's values.
- Integration test on the devnode: the market calling the **real Stylus engine** for `safeLtv` / `bellStatus` / `quoteCover`, compared against `risk-cli`.
- Coverage ≥ 95% of lines on `src/core` (market, vault, tips, treasury, reserve) and `src/governance`.

## Out of scope
UnderwriterPool, AuctionHouse, GDA, SettlementAdapter, SolverAuction (S3/S4), and testnet deploy scripts (S5).

## Acceptance criteria
1. `make contracts-build contracts-test risk-test` passes from a clean clone, and so does `make contracts-coverage` (≥ 95% on `src/core`, `src/governance`, `src/clock`, `src/oracle`).
2. Items A1–A5 are delivered, with a `READY` for each on the board **before** the main build work.
3. Every `IRiskEngine` function is live on the devnode; the differential at 10k per function has 0 mismatches; gas is within the ceilings or explained.
4. The invariant suites listed in E pass at 256 × 128, and INV-REPAY is proven with a reverting engine and oracle.
5. The scenario A Monday-to-Bell test passes to the cent.
6. G-06..G-11 and G-17 pass with the v1.1 inputs.
7. The R-23 NAV tests pass.
8. The report is at `docs/handoff/sprint-2-blockchain-report.md` (template), with ADRs for every deviation.

## Rules
The charter applies in full: your paths only, stage only your paths, and the shared-machine rules in §2a. Post BLOCKED for anything only the user can provide. When done, tell the user: "Sprint 2 blockchain done. Report: docs/handoff/sprint-2-blockchain-report.md".
