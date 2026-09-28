# Sprint 2 PM review

Date: 2026-09-28 · Reviewer: PM · Commit reviewed: `aea53d1`
**Verdict: Sprint 2 ACCEPTED for BE-chain, BE-backend and QE, with one carry-over:** BE-backend acceptance 4 at market level (`make api-bell-e2e`). It moves to S3 as item A1 (BE-chain) + A1 (BE-backend).

## 1. Independent verification

| Check | Command | Result |
| --- | --- | --- |
| Chain acceptance 1 | clean clone of `aea53d1`: `make contracts-build contracts-test risk-test` | ✅ EXIT 0 in 5 m 29 s: **153 Solidity tests passed, 0 failed** (19 suites, invariants included); risk-core golden 22, props 9, unit 10; cli 4; bindings 1 |
| Chain acceptance 1 (coverage) | clean clone: `make contracts-coverage` | ✅ core 99.28%, governance 100%, clock 99.19%, oracle 98.70% (gate 95%) |
| Chain ABIs | clean clone: `make abis-check` | ✅ `46 ABIs, additive except 4 allowed break(s)` (R-25 `ReportAccepted` + the pure→view changes, all ADR-documented) |
| Backend acceptance 1 | clean clone: `make backend-install backend-build backend-test` | ✅ EXIT 0 in 3 m 37 s: relayer 64, keeper σ vectors 8, SDK 44, API 33, feeds 9, indexer 3, notifier 13, calibration 36 (+6 skipped: tool-dependent checks). 0 failed |
| Backend acceptance 3 (σ) | `make keeper-sigma-test` | ✅ 8 + 5 passed: every QE vector bit for bit |
| Backend acceptance 4 (engine level) | `make api-engine-e2e` on the devnode | ✅ `100 positions checked over 18 sets (NEEDS_ACTION 47, safe LTV below max 29), mismatches 0` against router `0x24f4…d209` |
| Backend acceptance 4 (market level) | `make api-bell-e2e` on the devnode | ❌ `Error: reverted: poke`. The devnode book (BE-chain 18:02) uses the real calendar, which starts 2026-10-01, and the devnode clock is 2026-09-28. The engineers each pointed at the other ("waits for DeployCoreLocal" / "use a synthetic calendar"), so neither closed it. **Carry-over to S3.** |
| QE outputs | QE report + BE-chain 15:13 ANSWER | ✅ bundle `risk-bundle-889d50e4` loaded on the devnode, 24/24 hashes read back equal |

## 2. Rulings

### BE-chain
| # | Issue | Ruling |
| --- | --- | --- |
| 1 | Gas ceilings `coverLossVector` 332k / 300k, `poolCapacity` (10 markets) 2.02M / 600k | **Accepted for testnet** with the CI regression limits (measured + 10%). **Condition for S3:** the pool keeps an aggregate K-loss vector per epoch, so `writeCover` never recomputes all markets, and BE-chain measures `enforceBell` with auto-cover through the real pool and publishes the largest batch within 24M gas. The keeper sizes J3 from it. Revisit when Stylus multi-fragment programs ship. |
| 2 | Appendix A G-10/G-11/G-17 at debt at the Bell vs R-08 | **R-08 wins.** Every closure check uses projected debt. Guide v1.2 re-states Appendix A with the projected figures (Maya 96.92 TSLA, Priya's cure at D × (1 + 7.29% × 3/365)). The tests keep asserting the projected numbers. |
| 3 | INV-COV-01 wording | Accepted as implemented: *no voluntary `buyCover` at or after `bellAt`; auto-cover only in [`bellAt`, close)*. Guide v1.2 rewords it. |
| 4 | HF ≥ 1.05 floor binds only for tight params | Accepted; no change. |
| 5 | Scenario A keeper tips | §8.10 (2 USDC per processed position) wins; Appendix A gets fixed. |
| 6 | INV-DEBT-01 direction | Accepted: \|Σ debt − B\| ≤ n. |

### BE-backend
| # | Issue | Ruling |
| --- | --- | --- |
| 1 | ADR-0011 state reads (no events for auto-cover / settlement) | **Fix at the source:** BE-chain adds `AutoCoverApplied`, `PositionSettled` and the pool/auction events in S3 (A2); the indexer returns to pure projections. |
| 2 | J2 "26 h before a binding close" | Accepted: each of the next two scheduled closes. |
| 3 | `/bell` equality with a fixed-premium stand-in | Accepted for S2; in S3 the equality is against the real pool's `previewCover`. |
| 4 | ADR-0010 dedupe key collision | Accepted: `J2:<marketId>:<closureId>:<borrower>:<stage>`. |
| 5 | ADR-0009 **D1** (OPEN/CLOSE from the first/last RedStone package) | **Accepted for testnet only**, flagged `OracleFirstRegular`; mainnet needs a licensed official-print source. |
| 6 | ADR-0009 **D2** (COIN/SPY not on RedStone) | PM recommends (a) ask RedStone to list them, fallback (b) swap to GOOGL/AMZN with a QE recalibration. **Needs the user.** Not blocking S3 (local only). |
| 7 | ADR-0009 **D3** (RedStone written permission) | **User action**: email RedStone. Gates the public testnet (S5), not S3. `RedStonePriceSource` is built clean-room in S3. |

### QE
| # | Issue | Ruling |
| --- | --- | --- |
| 1 | Earnings nights make 93% of premiums | Real product issue. **Deferred to S4** (QE rejoins): scheduled-earnings attribute on the closure, earnings vs ex-earnings sets. Testnet launches with the current sets. |
| 2 | Docs' t₃ premiums ~20% above finite-set chain | Accepted; docs are illustrative. No change. |
| 3 | Calibrated weekend sets stricter than the t₃ stand-in | Accepted; the calibrated sets are binding. |

## 3. Process notes
- **Handoff gap:** the only unmet item fell between two roles, each waiting on the other. Rule for S3: an acceptance item that needs another role's deploy names the exact READY it waits for, and the owner of that READY runs the dependent check once as a smoke test.
- Good: byte-level cross-checks continued (σ vectors bit-exact, 0 mismatches Rust ↔ Stylus ↔ WASM), reproducible Stylus builds fixed, every deviation has an ADR.

## 4. User actions
1. **Rotate the vendor keys** (open since S1): Massive → Keys; Alpaca Paper → API Keys → Regenerate; update `.env`.
2. ADR-0009 D2: approve "ask RedStone, fallback swap to GOOGL/AMZN".
3. ADR-0009 D3: email RedStone for written permission (needed before S5).

## 5. Sprint 3
Briefs: `docs/team/prompts/sprint-3-{blockchain,backend}.md`. Two engineers: BE-chain + BE-backend. Frontend stays deferred (user: two engineers at a time, backend first).
