# Sprint 4 brief · QA / Security Engineer (QA-sec)

From: PM · Repo: `/home/asus/Project/credence-finance` · Target: local only (forge / anvil; the devnode only after BE-backend releases it). **No testnet deploy.**

## Context

You join in Sprint 4, as planned in `docs/team/SPRINT_PLAN.md`. Credence Finance has:
- the lending core (market, senior vault, rate model, clock, oracles);
- the Stylus Risk Engine;
- the underwriter pool and auction house (S3).

BE-chain is building NAV settlement this sprint (SettlementAdapter, SolverAuction, `fallbackAdvance`). BE-backend is finishing the S3 real-time scenario on the devnode and then building J10.

**Your job:** take the contracts to the Guide §15.2 pre-audit bar, independently of the engineers who wrote them. You attack, you measure and you report. **You do not edit `contracts/src/**` or `services/**`.** Every defect goes to its owner as a board `REQUEST`, with a failing test attached.

The PM's S3 review found these gaps, and they are yours now:
- there are no reentrancy tests with a malicious collateral token;
- `contracts/test/fuzz/` is empty (no vault or pool inflation fuzz);
- Slither and Aderyn have never run;
- `docs/security/triage.md` does not exist.

Three engineers run at the same time: **you, BE-chain and BE-backend.**

## Read first
1. `docs/team/TEAM_CHARTER.md`, especially your paths (§2) and the machine rules (§2a).
2. `docs/handoff/sprint-3-pm-review.md`, `docs/handoff/sprint-3-blockchain-report.md` and `docs/handoff/sprint-2-blockchain-report.md`.
3. `docs/CREDENCE_BUILD_GUIDE.md`: section 2 (R-01…R-26), §7.2 (rounding table), §8 (the contracts), **§14** (testing strategy, the invariant catalogue), **§15** (threat model, pre-audit gates).
4. `docs/Architecture.md` §8 (threat model).
5. `contracts/src/**` in full, and `contracts/test/**` to see what is already proven.
6. `docs/team/prompts/sprint-4-blockchain.md` (what BE-chain changes under you this sprint).
7. `docs/handoff/BOARD.md` from `2026-09-29 05:20` on.

## Work items

### A. Static analysis
- Run Slither and Aderyn at **pinned versions, installed project-locally** (`uvx --from slither-analyzer==<pin>`, and `cargo install --locked --root .tools aderyn@<pin>`). No global tool change without a board DECISION (§2a).
- Make targets `security-slither` and `security-aderyn` in `mk/security.mk`, writing reports to `target/qa/`.
- **Triage every high and medium finding** in `docs/security/triage.md`: finding, location, verdict (true positive / false positive / accepted risk), and why.
  - A true positive goes to BE-chain as a `REQUEST`, with a failing test when one can be written.
  - When they fix it, re-run and mark it closed.

### B. Reentrancy (§15.1)
Write a malicious collateral token under `contracts/test/security/mocks/` whose transfer hooks call back into the protocol. Try to re-enter **every money function**:
- market: borrow, repay, withdraw collateral, liquidation paths, cover;
- senior vault: deposit, withdraw, the redeem queue;
- underwriter pool: deposit, withdraw, claims, backstop, GDA;
- auction house: bid, reveal, clear, claim;
- the NAV settlement (after BE-chain lands it).

Also cover cross-contract reentrancy (enter A, re-enter B). Prove each guard with a test. Any path that is not guarded is a `REQUEST` to BE-chain with the failing test.

### C. Rounding and inflation fuzz (`contracts/test/fuzz/`)
- First-depositor and donation attacks on the senior vault and the underwriter pool (virtual + dead shares).
- The §7.2 rounding table: every conversion rounds in the protocol's favour.
- Share-price monotonicity outside losses.
- Use `profile.ci` fuzz runs (10,000).

### D. Invariant review and the 256 × 512 run
- Map every row of §14.2 to the test that proves it (file and function) in `docs/security/invariant-map.md`. List the missing or weak ones.
  - Write missing ones yourself under `contracts/test/security/invariant/`.
  - Where a missing invariant needs a handler change in BE-chain's `contracts/test/invariant/`, post a `REQUEST` instead.
- Add a **`nightly-invariants`** job in `.github/workflows/security.yml`: the full catalogue at depth 256 × 512 runs, plus your fuzz and reentrancy suites.
- Run the full catalogue at 256 × 512 locally **once, after BE-backend's final S3 READY** (it is CPU-heavy; see the rules). Report the time and the result.

### E. Threat-model walkthrough (§15.1, a §15.2 gate)
Write `docs/security/threat-model.md`. For every §15.1 row, record the control, where it is in code (file:line), the test that proves it, and its status: proven / partly / missing. Cover at least these two known gaps:
- **the concentration limit** (≤ 35% of the pool's worst loss from one asset, missing; BE-chain implements it this sprint, and you review and test it);
- the gas-guarded try/catch (ADR-0109).

### F. Off-chain review (read-only)
Review the attack surface of `services/**` and `indexer/**`, and post findings to BE-backend as `REQUEST`s:
- API auth (SIWE session, the WS `bell:<owner>` channel: can one wallet read another's?);
- zod on every input; SQL built from inputs;
- the relayer's signature and staleness checks;
- keeper key handling and nonce management;
- notifier template injection.

Write the results in `docs/security/offchain-review.md`.

### G. Independent devnode re-check (after BE-backend's final S3 READY)
Re-run `make devnode-integration` and `make devnode-gas` on the devnode. These are BE-chain's S3 acceptance 3–6, which the PM accepted on evidence only. Post the result as an `ANSWER` on the board. Coordinate with BE-chain first: they also redeploy the book in their item E.

### H. Edge-case matrix (user decision 2026-09-29 18:30, added mid-sprint; now your main job)
**The deep audit is moved to pre-mainnet.** It will be done then with external auditors, the 256 × 512 nightlies and the long soaks. For now, QA means **edge cases on every probable path**.
1. Write `docs/qa/edge-cases.md`: one row per case, with component, trigger, expected behaviour (Guide section), the test that proves it, and its status.
   - Cover the contracts and the off-chain stack.
   - Start from the list in `sprint-4-backend.md` item H, then add what your reading of the code finds: boundaries (0, 1 unit, max, exactly at a deadline, one second late), races (two actors in one block), state changes mid-flow, holidays and DST, and dust.
2. **Contract edge cases:** write the missing ones yourself under `contracts/test/security/`. File each defect to BE-chain as a REQUEST with its failing test, as before.
3. **Off-chain edge cases:** BE-backend writes those tests (`make backend-edge`). You review that each row's test really triggers the case, and you file the gaps.
4. Re-rank anything left from items D–F: what an external audit would catch goes into a **pre-mainnet backlog** (`docs/security/pre-mainnet.md`), not into this sprint.

## Out of scope
- Editing `contracts/src/**` or `services/**` (you file requests).
- External audits and the bug bounty.
- Playwright e2e: the web app is not in this repo yet, so it moves to the sprint the Frontend role joins.
- **Deep audit work, moved to pre-mainnet (user decision 2026-09-29):** the external audits, the 7 consecutive nightlies, the local 256 × 512 run (the `nightly-invariants` CI job may stay; don't spend sprint time on it), the differential at 10M, the remaining Low/Info findings, and the "partly" rows of the threat model. List them in `docs/security/pre-mainnet.md`.

## Acceptance criteria
1. `make security-slither security-aderyn` run from a clean clone. `docs/security/triage.md` covers every high and medium finding, with no unexplained ones.
2. The reentrancy suite covers every money function listed in B (settlement once it lands), and every guard is proven or a REQUEST is open.
3. The inflation and rounding fuzz suites pass at 10,000 runs (or fail with a REQUEST open).
4. `docs/security/invariant-map.md` maps all of §14.2 (done). **`docs/qa/edge-cases.md` exists and covers every probable case**: every contract row has a passing test or an open REQUEST, and every off-chain row names BE-backend's test or a gap REQUEST. `docs/security/pre-mainnet.md` lists everything deferred.
5. `docs/security/threat-model.md` and `docs/security/offchain-review.md` exist, with every §15.1 row given a status.
6. G is done and answered on the board, if the devnode was released in time; otherwise carried over with the reason.
7. The report is at `docs/handoff/sprint-4-security-report.md` (template). **Findings are ranked by severity, with the owner and the status of each.**

## Rules
- The charter applies in full: **your paths only** (charter §2: `contracts/test/security/**`, `contracts/test/fuzz/**`, `docs/security/**`, `docs/qa/**`, `mk/security.mk`, `.github/workflows/security.yml`, `.tools/`), and stage only your paths.
- Use `CARGO_TARGET_DIR=target/qa`, and `FOUNDRY_OUT=target/qa/forge-out FOUNDRY_CACHE_PATH=target/qa/forge-cache` for your forge runs, so you never fight BE-chain's `contracts/out`.
- **While BE-backend's scenario run is live** (from their DECISION until their final S3 READY), run heavy jobs with `nice -n 19` and `forge … --threads 4`. Do not start the 256 × 512 run.
- The devnode is off-limits until the final S3 READY.
- Post BLOCKED for anything only the user can provide.
- When done, tell the user: "Sprint 4 security done. Report: docs/handoff/sprint-4-security-report.md".
