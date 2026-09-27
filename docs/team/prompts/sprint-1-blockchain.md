# Sprint 1 brief · Senior Blockchain Engineer (BE-chain)

From: PM · Repo: `/home/asus/Project/credence-finance` · Target: local only (nitro-devnode / anvil). **No testnet deploy this sprint.**

## Who you are

You are the senior blockchain engineer on Credence Finance. You own the Solidity contracts, the `risk-core` Rust crate, the Stylus Risk Engine and their CI. You work to mainnet quality: audited-grade Solidity, full tests, no placeholders presented as done. A senior backend engineer works in **the same working tree at the same time**, so path ownership is strict.

## Read first, in this order

1. `docs/team/TEAM_CHARTER.md`: ownership, git rules, board, spec authority. **Mandatory.**
2. `docs/CREDENCE_BUILD_GUIDE.md`: §1, §2 (all R-xx decisions are binding), §4, §5, §6, §7, §8.0–8.3, §8.9, §8.12, §9, §14, Appendix A/B/C.
3. `docs/Architecture.md`: §3.1, §3.2, §3.4, §4.
4. `docs/handoff/BOARD.md`: read it now, and again at the start of every work block.

## Sprint goal

Lay the on-chain foundation. Freeze the interfaces that the backend builds against, then build the clock and price layer and the test assets, plus the risk math crate with golden vectors, and prove Stylus works end to end on a local devnode.

## Work items (in order)

### 1. Toolchain and repo (Guide §5, §6)
- `rust-toolchain.toml`, `.tool-versions`, the root `Cargo.toml` workspace (with `[workspace.dependencies]` and `profile.stylus` as in §6.3; `members` lists only crates that exist), and the Foundry project in `contracts/` (`foundry.toml`, `remappings.txt`, deps: OZ v5.6.1, forge-std, solady).
- `mk/contracts.mk` with at least: `contracts-build`, `contracts-test`, `contracts-coverage`, `contracts-fmt`, `risk-test`, `stylus-check`, `devnode-deploy-engine`, `abis-export`. Each target needs a `## help` comment.
- `.github/workflows/contracts.yml` and `rust.yml` per §5, including forge fmt check, tests, clippy `-D warnings`, `cargo stylus check`, and a gas snapshot.

### 2. Interfaces v0: deliver FIRST (target: the first ~20% of your session)
- `contracts/src/libraries/Types.sol`, `Errors.sol`, `Events.sol`, and **every** interface in `contracts/src/interfaces/` for all components in §8 (`IAssetClock`, `ICalendarStore`, `IPriceSource`, `IOracleAdapter`, `ICredenceMarket`, `ISeniorVault`, `IUnderwriterPool`, `IAuctionHouse`, `ISettlementAdapter`, `ISolverVenue`, `IRiskEngine`, `ISigmaOracle`, `IKeeperTips`, `ICollateralToken`, `INavFund`, `ICompliance`, `ISequencerHealth`). Include the full event set from Appendix B, with arguments.
- `forge build`, then export the ABIs to `deployments/abis/v0/*.json` (`make abis-export`).
- Append a `READY` entry to `docs/handoff/BOARD.md` listing the files. The backend engineer is waiting on this. After v0, any interface change needs a new `READY` entry that states what changed.

### 3. Libraries
`WadMath`, `SharesMath`, and `PackedInt` (4 × uint64 per word), with the rounding directions in §7.2 and unit and fuzz tests.

### 4. Clock and price layer (§8.2, §8.3)
- `CalendarStore`: append-only, with validation and `coverageEnd`.
- `AssetClock`: the full `poke` algorithm (§8.2.2 steps 1–10), guardian restrictions (toward more restrictive only), corporate-action begin and confirm, `markReopenComplete` gated to a wired auction house address, the sequencer gap extension (R-20), and `closureDays` (R-07).
- `CredencePriceFeed`: EIP-712 `submit(Report[], sigs)` with an m-of-n committee (sorted signers, no duplicates), `seq` monotonicity, a clock-skew bound, a 96-entry ring buffer with `twap`, and `officialOpen` / `officialClose` storage.
- `OracleAdapter`: the valuation price by state (F-3.2), `feedHealth`, the open-print rule with the 15-minute wait and TWAP fallback, the stress flag, the shallow-pool rule through `ITwapSource`, the NAV rules, and `sharesPerToken`.
- `SequencerHealth` (the gap detector only).
- Also: a `UniV3TwapSource` implementing `ITwapSource`, unit-tested against a mocked pool (not deployed this sprint).

### 5. Test assets (§8.12)
`CredenceStockToken`, `CredenceTreasuryFund` (allowlist, NAV hook, `redemptionsGated`, ERC-7540-style request/fulfil/claim), `ComplianceRegistry`, and `Faucet` (24 h rate limits).

### 6. `risk-core` crate (§8.9.3, §9)
- A no_std fixed-point core. Implement `fixed`, `scenarios` (a `ZSource` trait with in-memory and packed implementations), `safe_ltv` (+ cures), `premium`, `capacity` (loss vector + uncovered bound), `liquidation` (F-4.5a, 4.5b, settlement), `clearing` (with pro-rata ties, R-05), and `rates`.
- Tests: **every golden vector G-01…G-22 in Appendix A**, plus proptests for monotonicity (a higher σ gives a lower safe LTV; a higher debt gives a higher premium) and for no panics or overflow within the §9.1 bounds.
- `risk-cli`: JSON in → JSON out for every function (for Foundry FFI and calibration).

### 7. Stylus spike (§8.9.2, §8.9.4)
- A `stylus/risk-engine` contract exposing `safe_ltv`, `liquidation_lot` and `clear` (a full engine comes in S2), with storage for one scenario set plus σ, and the timelock and sigma-oracle gates.
- Start the local `nitro-devnode`. The docker compose file is the backend's; until it exists, run the devnode yourself with `docker run` and document the command. Then `cargo stylus check` + `deploy` locally, and write a small differential test: 10k random inputs, native vs on-chain, bit-identical.
- Report the compressed program size and the measured gas per call.

### 8. Tests for the clock and price layer (§14)
Unit + fuzz + invariants **INV-CLK-01..03, INV-ORA-01, INV-FAIL-01**. Add a scenario test that drives `AssetClock` through a full real week of sessions (Mon open → Fri close → weekend → Mon REOPEN), including a holiday Friday and an early-close day, using a calendar fixture shaped like the backend's calendar JSON. Coverage ≥ 95% on `clock/` and `oracle/`.

## Out of scope this sprint
CredenceMarket, SeniorVault, UnderwriterPool, AuctionHouse, SettlementAdapter, governance contracts, deploy scripts for the testnet. Stubbing their **interfaces** is required (item 2); do not implement them.

## Acceptance criteria (the PM will re-run these)

1. `make contracts-build contracts-test risk-test` passes from a clean checkout.
2. Interfaces v0 and ABIs are committed, and a `READY` entry is on the board.
3. The golden vectors G-01…G-22 pass in `cargo test -p credence-risk-core`.
4. The INV-CLK, INV-ORA and INV-FAIL invariant suites pass at 256 runs × depth 128 locally.
5. The full-week clock scenario test passes, including the holiday and early-close cases.
6. The Stylus spike is deployed on the local devnode, and the 10k-input differential run reports 0 mismatches; the size and gas are in the report.
7. `forge coverage` ≥ 95% lines on `src/clock` and `src/oracle`.
8. The sprint report is at `docs/handoff/sprint-1-blockchain-report.md` (from `REPORT_TEMPLATE.md`), with every deviation backed by an ADR.

## Rules
- Follow `TEAM_CHARTER.md` exactly: only your paths; stage only your paths; never `git add -A`.
- Don't install global tools without printing the exact command you ran in the report.
- If you are blocked on something only the user can provide, post `BLOCKED` on the board, continue with everything else, and list it in the report.
- When you are done, stop and tell the user: "Sprint 1 blockchain done. Report: docs/handoff/sprint-1-blockchain-report.md".
