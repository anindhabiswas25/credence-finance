# Sprint 4 brief · Senior Blockchain Engineer (BE-chain)

From: PM · Repo: `/home/asus/Project/credence-finance` · Target: local only (anvil / forge; the devnode only after BE-backend releases it). **No testnet deploy.**

## Context

Your Sprint 3 is **accepted**. `docs/handoff/sprint-3-pm-review.md` has the PM's clean-clone re-run and a ruling on each of your spec issues 1–4. BE-backend is still finishing S3. Their first real-time `make scenario-a-e2e` died at 01:24 UTC when the laptop went down, so they re-run it in full (about 2.5 h, user's decision: real time, no compressed clock). The run holds the devnode and `deployments/412346.local.json` until they post their final S3 READY on the board. **Until that entry is on the board, do not deploy to, reset or poke the devnode, and do not write the devnode book.** Everything in A–D below runs on forge or anvil. Only item E needs the devnode.

**Three engineers run at the same time this sprint:** you, BE-backend, and the new **QA / Security engineer (QA-sec**, brief `docs/team/prompts/sprint-4-security.md`). QA-sec now owns the pre-audit hardening that was in your item C: reentrancy tests, inflation fuzz, Slither and Aderyn, `docs/security/**`, the 256 × 512 run and the nightly CI job. They file each defect as a board `REQUEST` with a failing test. **Fixing their high and medium findings in `src/` is part of your sprint.**

S4 is **NAV settlement + hardening**. It completes the last on-chain feature (the Treasury-fund stack's T+0 liquidation) and takes the contracts to the Guide §15.2 pre-audit bar, so S5 can deploy to Arbitrum Sepolia.

## Read first
1. `docs/team/TEAM_CHARTER.md` (§2, §2a).
2. `docs/handoff/sprint-3-pm-review.md`.
3. `docs/CREDENCE_BUILD_GUIDE.md`: **§8.8** (SettlementAdapter, SolverAuction), §8.6 (`fallbackAdvance`), §8.12 (testnet assets; the NAV test fund), R-23, §10.2 J10, **§14.2** (every invariant), **§15.1–15.2** (threat model, pre-audit gates), Appendix A **S-B**.
4. `docs/One week of money flow.md` (scenario B, the whole week).
5. `docs/handoff/BOARD.md` from `2026-09-29 03:20` on.

## Sprint goal
The NAV stack liquidates Treasury-fund collateral at T+0 through a solver auction, with the pool advance as fallback. Scenario B passes to the cent. The contract suite meets the pre-audit gates that can be met before an external audit.

## Work items

### A. Early deliverables for BE-backend (first; post a `READY` for each)
1. **Interfaces v3 (or additive v2) for the NAV stack:** `ISettlementAdapter`, `ISolverVenue` / `SolverAuction`, `pool.fallbackAdvance`, the NAV fund's redemption claim, and every event J10 and the indexer need: `SettlementOpened`, `SolverBid`, `SettlementFinalized(filled, proceeds)`, `FallbackAdvanced`, `RedemptionRequested`, `RedemptionClaimed`. Put the ABIs in `deployments/abis/…`, run `make abis-check`, write an ADR, and regenerate `credence-bindings`.
2. **Timing contract for J10:** window length, finalize preconditions, and when the pool may claim a redemption (T+1 USBANK session). The keeper builds J10 from this READY.

### B. NAV settlement (§8.8)
- `SettlementAdapter`: `openSettlement(marketId, borrowers[])`, permissionless and tipped, HF < 1, state ∉ {HALTED, CORP_ACTION}. Lot sized with F-4.5a at `κ_nav = 0.5%`, floor = NAV × 99.5%. It pulls the lot with `releaseLots` and opens a 15-min window on `venues[0]`. `finalize(settlementId)`.
- `SolverAuction` (native testnet venue): allowlisted solvers only, bid ≥ floor and ≥ 1.0001 × best, escrow `qty × price`, the outbid solver refunded at once, `best`, `finalize`.
- `UnderwriterPool.fallbackAdvance` (NAV pool): the pool pays `qty × floor`, receives the tokens, calls `fund.requestRedeem(qty)` (ERC-7540 style) on the testnet `CredenceTreasuryFund`, and later claims the redemption. It earns the 0.5% discount. The claim must be in NAV as "outstanding redemption claims at cost" (§8.6.1).
- Issuer gate: gated redemptions → clock HALTED → `openSettlement` reverts, and repay stays open.
- `DeployCoreLocal` deploys the real NAV settlement in place of the S3 stand-in.

### C. Hardening (§15), your part
- **Concentration limit (§15.1, missing):** at most 35% of the pool's worst loss may come from one asset, enforced in `writeCover` (timelock parameter) and tested. Check first whether R-13 / §9.5 changes the number, and write an ADR. QA-sec reviews it.
- **Settlement invariants:** cash in = cash out, tokens conserved, the floor respected, no settlement while HALTED. Add them to `contracts/test/invariant/`.
- **QA-sec's findings:** answer every `REQUEST` from QA-sec on the board. Fix true positives in `src/` with their failing test turned green, or reply with the reason it is not a defect. Add `nonReentrant` wherever their reentrancy suite shows a gap.
- NatSpec complete on every external function of `src/`.
- **J3 batch (spec issue 4 follow-up):** prototype the per-batch cached uncovered bound in `enforceBell`, measure it with `make devnode-gas` (when the devnode is free), and keep it only if it at least doubles the batch without breaking INV-POOL-02. Write an ADR either way.

### D. Tests
- Unit and fuzz tests for SettlementAdapter, SolverAuction and `fallbackAdvance`.
- **Scenario B, the whole week, to the cent** (Appendix A S-B): Thursday Ben's INTRADAY lot of 20.23 at 362.18, with the penalty split 73.26 × 3; Friday premiums of 297.42 in total; Monday Priya 59.08 at 156.02, with debt after 4,578.38; Dev's full close; the pool backstop of 40 at 218.25; the shortfall of 672.59; Zed's bond of 86 to the pool; cash in = cash out = 31,087.15; pool share price 0.9998823, and Sara receives 9,998.82. Use the same approach as S-A: premiums injected, and chain identities asserted where R-06 / R-08 / R-09 move a cent (with an explanation in the report).
- A NAV scenario: a Treasury-fund position with HF < 1, a solver fill, and then a no-bid case → `fallbackAdvance` → redemption claimed at T+1.
- Coverage ≥ 95% of lines on every `src/` directory, including the new settlement directory.

### E. On the devnode (only after BE-backend releases it)
- `make devnode-integration` extended with a NAV settlement (a solver fill and a fallback) through the Stylus router.
- Redeploy the main book with the real NAV settlement. Post a DECISION first.

## Out of scope
Arbitrum Sepolia deploy scripts, Arbiscan / Stylus verification, and post-deploy checks (S5). External audits. The frontend.

## Acceptance criteria
1. `make contracts-build contracts-test risk-test contracts-coverage abis-check` passes from a clean clone, with ≥ 95% on every `src/` directory.
2. A1–A2 are delivered, each with a READY before the main build.
3. Scenario B passes to the cent, or to the chain identity with every cent difference explained. The NAV solver-fill and fallback scenarios pass.
4. The settlement invariants exist and pass at 256 × 128 (QA-sec runs the whole catalogue at 256 × 512).
5. The concentration limit is in place and tested. Every QA-sec `REQUEST` of high or medium severity is fixed or answered with a reason on the board.
6. The devnode integration shows a NAV settlement (after the devnode is released), and the main book has the real NAV settlement.
7. The report is at `docs/handoff/sprint-4-blockchain-report.md` (template), with ADRs for every deviation.

## Rules
The charter applies in full: your paths only, stage only your paths, and the §2a rules. The devnode stays off-limits until BE-backend posts its final S3 READY. **While their real-time run is live, the keeper must hit its Bell and auction deadlines,** so run your heavy jobs with `nice -n 19` and `forge … --threads 4` (`contracts-coverage`, long invariant runs, release builds). QA-sec owns `contracts/test/security/**` and `contracts/test/fuzz/**`; do not edit them. Post BLOCKED for anything only the user can provide. When done, tell the user: "Sprint 4 blockchain done. Report: docs/handoff/sprint-4-blockchain-report.md".
