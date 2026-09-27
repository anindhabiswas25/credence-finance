# Sprint 1 PM review

Date: 2026-09-28 · Reviewer: PM · Commit reviewed: `fc6c3bf`
**Verdict: Sprint 1 ACCEPTED for both roles.** Every acceptance item was re-run independently from clean clones.

## 1. Independent verification

| Check | Command (clean clone of `fc6c3bf`) | Result |
| --- | --- | --- |
| Chain acceptance 1, 3, 4, 5 | `make contracts-build contracts-test risk-test` | ✅ EXIT 0 in 3 m 10 s: **102 Solidity tests passed** (5 invariant suites at 32,768 calls each); golden 22/22, proptests 9/9, unit 6/6, cli 3/3 |
| Chain acceptance 7 | `make contracts-coverage` | ✅ EXIT 0: `src/clock` 99.18%, `src/oracle` 98.99% of lines; invariants re-ran at 256 runs |
| Chain acceptance 6 | `make stylus-check`, `devnode-deploy-engine`, `stylus-diff DIFF_N=2000` | ✅ size 23.7 KB (23,703 bytes compressed, one fragment); deployed and activated on the devnode; differential at 2,000 inputs per function: **0 mismatches**. The reported size differs by 122 bytes from the engineer's 23,581; the build is not byte-reproducible across checkouts. Track this in S2 (R-24 reproducibility) |
| Backend acceptance 1 | `make backend-install backend-build backend-test` | ✅ EXIT 0 in 2 m 12 s: Rust 11 + 5 + 52 + 1 + 1, SDK 37, API 12, indexer 2, calendar 17. All passed; 3 e2e tests are ignored by design and run below |
| Backend acceptance 4 | `make relayer-e2e` | ✅ `relayer_end_to_end_on_local_chain ... ok` (EXIT 0) |
| Backend acceptance 6 | `make keeper-e2e` | ✅ `j1_pokes_on_schedule ... ok`, `leader_failover_no_duplicates ... ok` (EXIT 0) |
| Code scan | grep for TODO / unimplemented / skipped tests in shipped sources | ✅ none |

Size of the S1 codebase: contracts 3.7k lines of source + 3.6k lines of tests; risk-core 1.9k; Stylus 1.1k; relayer 6.9k; keeper 2.1k; API 0.9k.

## 2. Rulings on the spec issues

### BE-chain

| # | Issue | Ruling |
| --- | --- | --- |
| 1 | G-22 does not match its model | **BE-chain is correct; the guide was wrong.** The guide's closed form let the collateral price go negative in extreme t₃ tails, so a loss could exceed the debt. With the zero price floor (the engine's behaviour), the exact value is 2.1444 / 85.77 / 4.394, and the PM reproduced it independently. Guide v1.1: R-22 rewritten, F-4.3 and F-4.4 carry the floor, G-22 = 2.14 / 85.77 / 4.39. |
| 2 | Rounded safe-LTV inputs in G-10/11/17 | Accepted. v1.1 states full-precision inputs; with those, the doc figures (2,896.78; 8,527.09; 96.5454) follow exactly. Update the tests in S2. |
| 3 | `BorrowPaused` event vs error | Accepted: `BorrowPausedByGuardian`. Guide updated. |
| 4 | NAV 50 h rule halts every Monday | **Real bug, found in S1.** New R-23: freshness is counted in USBANK sessions. Implement in S2. |
| 5 | Stylus gas ≈ 5× the estimates | Accepted. The guide now carries the measured values and CI ceilings; profile in S2. |
| 6 | Nightly build for one fragment | Accepted for testnet (R-24), pinned and reproducible. Revisit before the mainnet audit. |
| 7 | v3-core does not compile on 0.8 | Accepted. Removed from the guide. |
| 8 | Provisional reference at close | Accepted (ADR-0103 #1). |
| 9 | Phase extension accumulating over weekends | Accepted (ADR-0103 #6). |
| 10 | Root `Stylus.toml` has no owner | Assigned to BE-chain in the charter. |

### BE-backend

| # | Issue | Ruling |
| --- | --- | --- |
| 1 | Rust 1.91 vs alloy 2.5 | Accepted. The guide pins 1.95.0 (R-24). |
| 2 | `signer-aws` pins aws-smithy | Accepted: use alloy's re-exported KMS client (ADR-0005). |
| 3 | Vendor licensing | **Escalated to a launch gate (R-26).** S2 includes a spike on feeds already licensed for on-chain use, with a cost table, and the user decides. |
| 4 | `observedAt` skew on on-demand chains | Accepted as handled (ADR-0004 §9). |
| 5 | `price_point.status` not derivable | Resolved by interface v1: `ReportAccepted` gains `marketStatus` (R-25). BE-chain delivers in S2. |
| 6 | Early-close post-market and USBANK windows | ADR-0003 accepted. |
| 7 | Engine address in the address book | Resolved: one local address book with `shared.riskEngine` (charter §2a). |

## 3. Process notes (fixed in the charter §2a)
- A rustup race corrupted a toolchain, and there was cargo lock contention. Rules added: a separate `CARGO_TARGET_DIR` per role, and a DECISION on the board before global tool changes.
- Two address-book files. Rule added: one `deployments/<chainId>.local.json`.
- Good practice worth keeping: early interface freezes, byte-level cross-checks (EIP-712 digests, calendar ABI encoding), and flagging spec errors instead of silently "fixing" them. The G-22 finding caught a PM error.

## 4. Security action (user)
The free vendor keys were pasted into chat during S1. **Rotate them** (Massive dashboard → Keys; Alpaca Paper → API Keys → Regenerate), and update `.env`.

## 5. Sprint 2
Briefs: `docs/team/prompts/sprint-2-{blockchain,backend,quant}.md`. The Quant engineer joins.
