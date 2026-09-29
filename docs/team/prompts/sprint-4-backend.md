# Sprint 4 brief · Senior Backend Engineer (BE-backend)

From: PM · Repo: `/home/asus/Project/credence-finance` · Target: local only (nitro-devnode / anvil). **No testnet deploy.**

## Context

Your Sprint 3 code is done, but **S3 acceptance 3–6 are not met yet**. The PM checked the logs of the `make scenario-a-e2e` run you left unattended:
- Every log in `target/be/scenario-a/` (keeper, ponder, relayers) stops at **01:24:42 UTC**, 13 minutes **before** the Friday Bell.
- The laptop then went down, and it rebooted at 12:12 local. `check.log` only reached the Bell window (`/bell` == `bellStatus` for Priya and Maya).
- So the Bell auto-cover, the pre-close sale, the Monday open, the REOPEN auction, the keeper kill between `fixLots` and `clear`, and `settleEpoch` **never ran**.
- The devnode container is gone, too.

**The user's decision: run it again at real time (the full ~2.5 h). Real tests find real bugs.** No compressed Bell constants, no anvil time-warp. The user keeps the laptop on for the whole run.

This sprint has two parts. **Part 1 (finish S3) comes first and has priority over everything else.** You are the engineer with extra work: while the 2.5-h run waits on the devnode's clock, you do Part 2 under the rules below.

Three engineers run at the same time this sprint: **you, BE-chain (S4) and the new QA / Security engineer (QA-sec).** Both of them stay off the devnode until your final S3 READY.

## Read first
1. `docs/team/TEAM_CHARTER.md` (§2, §2a; the QA-sec paths and the three-engineer machine rules are new).
2. `docs/handoff/sprint-3-pm-review.md` (your rulings: ADR-0012, J2 binding and J8 claim helpers are all accepted).
3. `docs/handoff/sprint-3-backend-report.md` (your interim report).
4. `docs/team/prompts/sprint-4-blockchain.md` items A1–A2 (what you build J10 on).
5. `docs/CREDENCE_BUILD_GUIDE.md`: §8.8, §10.2 (J10), §10.3–10.5, §11, **§16.1**.
6. `docs/handoff/BOARD.md` from `2026-09-29 05:20` on.

## Part 1. Finish Sprint 3 (first)

1. **Pre-flight:**
   - Post a board DECISION that you are bringing the devnode up.
   - Run `make infra-up db-migrate`, then `make local-deploy-core CALENDAR=synthetic SYNTH_ARGS='--regular-minutes 155 --closure-minutes 15 --session-minutes 150'`. Use the same args as before, or longer if your seeding needs more time before the Bell window.
   - Post the new book on the board.
2. **Survive a sleep or a session end:**
   - Start the run detached from your Claude session with `setsid nohup`, so it doesn't depend on your terminal.
   - Wrap it in `systemd-inhibit --what=idle:sleep:handle-lid-switch --who=credence --why="scenario A e2e" …` so the laptop cannot suspend on idle or on the lid.
   - Tell the user in one line to keep the charger plugged in.
3. **Make the runner fail loudly, never silently:**
   - Add a watchdog to `run.sh` or `check.ts`. If the devnode's block time stops advancing for more than 60 s, or any service process dies, it writes `ABORTED: <reason>` to `check.log` and exits non-zero.
   - The last run died with no line in `check.log`. That must not happen again.
4. **Run `make scenario-a-e2e` to the end, at real time.** It must cover:
   - the Bell with auto-cover;
   - the pre-close sale;
   - the Monday open print;
   - the J5 REOPEN auction cleared by the bot, with the forfeited bond;
   - the pool shortfall and `settleEpoch`;
   - J11 if `qPool > 0`;
   - the kill-watch SIGKILL between `fixLots` and `clear`;
   - every indexer/API figure == the chain;
   - every §10.5 notification `sent` with the chain's amounts.
   - **The keeper sends 0 failed txs.**
5. **If a real bug shows up:**
   - Fix it (your paths) or post a REQUEST (BE-chain's paths).
   - Write down what failed in the report.
   - Re-run the whole scenario. A partial run does not count.
6. **Finalise the report:**
   - Update `docs/handoff/sprint-3-backend-report.md` with the full `check.log` and the keeper tx summary (mined / reverted / by job).
   - Post the **final S3 READY** on the board. That READY releases the devnode to BE-chain and QA-sec.
   - Tell the user: "Sprint 3 backend final. Report: docs/handoff/sprint-3-backend-report.md".

## Part 2. Sprint 4 backend (the extra work, alongside the run)

### Rules while the scenario run is live
The run uses the binaries in `target/be/debug`, and kill-watch restarts the keeper from there.
- Build Part 2 with **`CARGO_TARGET_DIR=target/be-s4`**, never `target/be`, until the final S3 READY.
- Never restart a scenario service on new code during the run.
- No devnode or DB e2e targets during the run: unit tests only.
- Use `nice -n 10` for builds.
- Check `check.log` at least every 20 min, and before the Bell, the close, the open and the auction deadlines.

### Items
**A. Clean-ups from the PM's log review (do these first):**
- **Log noise:** in the run, `core: market read failed` fired **28,979 times**. It comes from COIN, MSFT and SPY, which have no price in the scenario: `NoReferencePrice(bytes32)`, selector `0x2da33f4c`. Treat a market with no reference price as "not live". Log it once per state change, not every tick, and expose it as a gauge (`keeper_markets_unpriced`).
- **Bell times from the chain:** the keeper hard-codes the Bell window and deadline (`schedule.rs:12-13` `BELL_WINDOW_LEAD_S` / `BELL_LEAD_S`, and `core.rs:126` `BELL_BEFORE_CLOSE_S`). Read `AssetClock.bellWindowAt` / `bellAt` from the chain instead, so the keeper and the contracts cannot drift. Keep the constants only as a startup self-check that warns when they differ.
- **`programTimeLeft 0 days` alert:** the keeper raised `stylus-activation` P2 (RB-10) for the router `0x24f4…d209` on the devnode. Find out whether it is a real devnode activation expiry or a wrong read. Fix it, or document it.

**B. J10 NAV settlement (after BE-chain's READY A1 and A2):**
- `openSettlement` for HF < 1 NAV positions, then `finalize` after the window, then the pool's redemption claim at T+1.
- Idempotency key `(settlementId, step)`, restart-safe like J5.
- Pre-checked with views + `eth_call`, and failed txs are counted.
- Until A1/A2 land, build against the brief's event list and unit-test with mocks.

**C. Test solver bot:** extend `services/bidder` (or add `services/solver`) so a NAV settlement can clear without a human: allowlisted solver, bid ≥ floor and ≥ 1.0001 × best, config-driven, plus a no-bid profile that forces `fallbackAdvance`.

**D. Indexer and API for settlement:**
- Tables `settlement`, `solver_bid` and `redemption_claim`, as pure projections of the new events.
- `GET /v1/settlements?market=&status=` and `/v1/settlements/:id`.
- The NAV pool's `/v1/pool/nav` includes outstanding redemption claims at cost (§8.6.1).
- OpenAPI and zod.

**E. Notifier:** §10.5 messages for a NAV position sold at T+0 (solver fill or pool advance) with exact amounts.

**F. Ops (§16.1):**
- Grafana dashboards (keeper, relayer, pool, auctions) as provisioned JSON under `infra/`.
- Every §16.1 alert as a Prometheus rule with a promtool test. Several already exist; add the missing ones: reopen stuck, epoch not settled, pool utilisation, Stylus activation, calendar coverage, shortfall reached the reserve or senior.

**G. NAV e2e on the devnode (after your final S3 READY and BE-chain's item E deploy):**
- `make nav-settlement-e2e`: a solver fill and a no-bid fallback, keeper-only after seeding.
- Indexer, API and notifier == the chain.

### H. Edge-case suite (user decision 2026-09-29 18:30, added mid-sprint)
**No 65-hour runs before mainnet.** Instead, prove the off-chain stack on **every probable edge case**, each as a short automated test.
- Use unit tests with mocks, anvil with time warp (`MockRiskEngine`), or the devnode only where the Stylus engine matters.
- Target `make backend-edge`, whole suite ≤ 30 min.
- QA-sec owns the case list (`docs/qa/edge-cases.md`) and files each gap as a REQUEST. Build your tests against it, and mark each row with the test that proves it.

Cover at least:
- **Relayer:**
  - one vendor down, both down;
  - stale, zero or outlier prices;
  - feed disagreement over 1.5 % and over 5 %;
  - 1 of 3 signer nodes down (still signs); 2 of 3 down (no quorum, so the feed goes stale and the asset HALTs, fail closed);
  - a submission not mined; an RPC outage;
  - the open print missing, then the TWAP fallback after 15 min;
  - holiday, early close and DST switch days;
  - a stock split (`sharesPerToken`).
- **Keeper:**
  - killed and restarted **between every pair of steps** of J3, J5, J9, J10 and J11, not only `fixLots`/`clear`;
  - two instances with leader failover;
  - a stuck tx; a gas spike; an RPC error mid-batch;
  - a position repaid or closed between the pre-check and the tx;
  - a Bell with 0 positions;
  - a Bell with 35+ NEEDS_ACTION positions (4+ J3 txs, all inside the 15-min deadline);
  - a lot over 128 positions (tranches);
  - an auction with no bids, every bidder failing to reveal, and partial fills;
  - pool capacity exhausted (cover fails closed);
  - a withdraw queue with a cash shortage;
  - a GDA still unsold at the next closure;
  - NAV: a solver fill, no bid (fallback), `RedemptionsGated` (retry), a solver voided, the T+1 claim delayed by a holiday;
  - a sequencer gap (R-20 phase extension);
  - HALTED mid-cycle;
  - calendar coverage running out.
- **Indexer:**
  - a restart and a full reindex give identical tables;
  - an anvil reorg;
  - several contracts' events in one block.
- **API and WS:**
  - pagination edges; unknown ids (404); invalid inputs (400); uint256-max values;
  - WS disconnect and reconnect; session expiry.
- **Notifier:**
  - a channel down, then retry, then dead-letter;
  - a duplicate event gives one message;
  - a user with no channel;
  - Telegram rate limits;
  - amounts of 1 base unit and at the maximum.
- **Postgres restart** mid-cycle.

## Out of scope
- **Long soak runs** (the ≈ 65-h recorded weekend, multi-weekend soaks): moved to the **pre-mainnet** phase by the user. Not in S4, S5 or S6.
- Production deploy, KMS, RPC failover (S5).
- The web app.

## Acceptance criteria
1. **S3 is closed.** `make scenario-a-e2e` passes on the devnode at real time, end to end, with 0 failed keeper txs and the kill-watch restart proven. The S3 report is final, and the final S3 READY is posted.
2. `make backend-install backend-build backend-test backend-lint` passes from a clean clone.
3. A (log noise, Bell times from the chain, `programTimeLeft`) is done, with tests. `make backend-edge` passes, and every off-chain row of `docs/qa/edge-cases.md` names its test (or is marked deferred to pre-mainnet with the PM's agreement).
4. J10, the solver bot, the settlement indexer/API and the notifier messages are built, with unit tests. `make nav-settlement-e2e` passes on the devnode if BE-chain's item E lands this sprint; otherwise mark it carried over with the reason.
5. Every §16.1 alert has a rule and a promtool test, and the dashboards are provisioned.
6. The report is at `docs/handoff/sprint-4-backend-report.md` (template), with ADRs for every deviation.

## Rules
- The charter applies in full: your paths only, stage only your paths, and the §2a rules.
- You own the devnode: post before `infra-up`, `infra-down` or `infra-reset`.
- Post BLOCKED for anything only the user can provide.
- When S4 is done, tell the user: "Sprint 4 backend done. Report: docs/handoff/sprint-4-backend-report.md".
