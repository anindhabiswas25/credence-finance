# Sprint 3 report · Senior Backend Engineer (BE-backend)

Date: 2026-09-29 · Session model: Claude Opus 5.5 · Commits: `4cacbf7..HEAD` (BE-backend paths only)

**Status: final.** `make scenario-a-e2e` passed on the devnode at real time, end to end: **`PASSED: scenario A at 2026-09-29T14:18:35Z`**. The run started at 11:19 UTC on a fresh devnode. The keeper sent 583 txs: all mined, 0 reverted, 0 replaced. The keeper kill between `fixLots` and `clear` was proven. §2 has the evidence, §4 the full `check.log`, and §4 "The runs" the history of all three runs.

## 1. Summary
- **The S2 carry-over is closed.** `make api-bell-e2e` passes on the devnode with 0 mismatches over 100 positions, and again from scratch with 100 new positions.
- **The keeper drives the whole closure cycle by itself:**
  - J3 (batches of 10), J4, J5 (flag, `fixLots`, `clear`, `settlePositions`, `completeReopen`), J6, J8 (pool step), J9 (open, snapshot, settle) and J11 (GDA) run live;
  - every step is pre-checked with views plus an `eth_call`, and every tx job is restart-safe;
  - a test bidder bot drives the auctions.
- **The indexer serves pools, epochs, policies, auctions, bids, lots and GDAs** as pure projections of the events. The API has the pool, epoch, auction and risk endpoints, the WS `auctions` and `bell:<owner>` channels, and the vault cushion.
- **The notifier sends every §10.5 event with exact amounts**, triggered from indexer rows.
- **The RedStone print mode (ADR-0009 D1)** is proven on real recorded packages, and BE-chain's `RedStonePriceSource` accepts the relayer's payloads on anvil and on the devnode.
- **Scenario A passed at real time:** about 3 h on the devnode's wall clock, with no warp and no compressed Bell constants.

## 2. Acceptance checklist
| # | Item | Status | Proof (command + key output) |
| --- | --- | --- | --- |
| 1 | `make backend-install backend-build backend-test backend-lint` passes; e2e targets pass with `infra-up db-migrate` | ✅ | Clean clone (fresh `git clone` in a scratch dir): `make backend-install backend-build backend-test backend-lint` → `EXIT 0` in 10 min 55 s. E2e: `keeper-e2e` 4 tests (incl. `killed_mid_job_restart_resumes_without_duplicates`, `stuck_tx_is_replaced_after_3_blocks_at_plus_20_percent`), `keeper-core-e2e`, `keeper-j7-e2e` 2, `indexer-core-e2e`, `relayer-redstone-e2e` 2 |
| 2 | `make api-bell-e2e` passes on the devnode, with the ANSWER posted | ✅ | `/bell vs chain: 100 positions checked (NEEDS_ACTION 13), mismatches 0`; again from scratch (`ACCOUNT_SALT=s3-backend`). Board ANSWER 00:40. In scenario A, on the real pool: `ok /bell for priya == market.bellStatus at block 854: status 1, repay 139424111, … premium 500000 (API 500000)`, same for Maya |
| 3 | `make scenario-a-e2e` passes on the devnode with no manual tx after seeding; the keeper sends 0 failed txs | ✅ | `PASSED: scenario A at 2026-09-29T14:18:35Z`; `ok no manual transaction after seeding (blocks 241..4374)`; `ok the keeper sent 0 failed txs (ops.keeper_tx reverted: 0)`. Keeper txs: J1 558, J3 1, J5 9, J6 3, J8 8, J9 2, J11 2 = **583 mined, 0 reverted, 0 replaced, 0 dropped** |
| 4 | Keeper restart test: killed between J5 `fixLots` and `clear`; completes with no duplicate tx | ✅ | `14:09:02 killed the keeper (pid 942123) between fixLots and clear; 14:09:22 restarted the keeper (pid 1716821)`; `ok after the restart every REOPEN auction cleared (2 J5 clear steps done) with no J5 step mined twice` |
| 5 | Indexer serves pools, epochs, policies, auctions, bids and GDA from events; API == chain at the same block | ✅ | `/v1/auctions/{1,2,3}` == `auction(id)` (lot, R, p*, qPool, proceeds); the 4 settlements == `PositionSettled`; `/v1/pool/equity == pool at block 4376: NAV 291844610396, share price 1024016176827985908`; `/v1/pool/equity/epochs[3] == pool.epoch(3)`; `/v1/risk lists 3 cleared auctions and 2 pool(s)` |
| 6 | The notifier e2e covers every §10.5 event with exact amounts | ✅ | In the run, each job below is `sent` with the chain's amounts: J2 heads-ups (Priya, Maya), auto-cover (premium == `AutoCoverApplied.premium`), 4 × auction settled (== `PositionSettled`), 3 × queued at the reopen, 2 × epoch settled (== `EpochSettled.sharePriceAfter`, in the template's unit), withdrawal claimable. `notification_log failures 0, dead jobs 0` |
| 7 | Report with ADRs for every deviation | ✅ | This file; ADR-0011 (S3 update), ADR-0012 (scenario A on the devnode) |

## 3. What was built
- **Keeper** (`services/keeper`):
  - `core.rs`: bindings from `credence-bindings`;
  - `txjob.rs`: restart-safe tx jobs;
  - `auction_jobs.rs`: J5 / J6;
  - `pool_jobs.rs`: J9, J11, J8 pool, J5 `completeReopen`;
  - `core_jobs.rs`: J3 live, J4 live, the J2 fix;
  - `sigma_runner.rs`: `sigmaAt`;
  - `keeper_failed_txs_total`, `KEEPER_GAS_MULTIPLIER_X10`, batch sizes from BE-chain (J3 10, flag and settle 128).
- **Bidder bot** (`services/bidder`): commit / reveal / place / claim from a JSON config (honest, low-ball and non-revealing profiles), a persisted salt, and a `canHold` pre-check.
- **Relayer** (`services/relayer/src/vendor/redstone.rs`): `PRINT_SOURCE=redstone`, 3-of-5 verification, the D1 OPEN/CLOSE rules, and recordings with a time shift.
- **Indexer** (`indexer/src/risk.ts`, `ponder.schema.ts`): `pool`, `epoch`, `cover_policy`, `pool_flow`, `pool_request`, `pool_holder`, `backstop_inventory`, `auction`, `bid`, `lot_position`, `gda`, `open_print`.
- **API** (`services/api/src/rt.ts`, `stream.ts`, `core.ts`): the pool, epoch, auction and risk routes, the vault `cushion`, `/bell` `epochId`, WS `auctions` and `bell:<owner>`. OpenAPI and zod on every route.
- **Notifier:** `producer.ts` (indexer-triggered events, idempotent dedupe keys) and the four new §10.5 templates.
- **Scenario toolkit** (`services/api/scripts/scenario-a/`):
  - calendar export, replay recording, seeding, mock providers, `kill-watch.sh`, `check.ts`, `run.sh`, `tx-summary.ts`;
  - the runner writes `check.log` itself;
  - **a watchdog** writes `ABORTED: <reason>` and stops the run when any of these fail: the devnode RPC or clock, Postgres, any service, or the host staying awake;
  - the run is started with `setsid nohup` inside `systemd-inhibit`.

## 4. Test results
Final `check.log` of the passing run (`target/be/scenario-a/check.log`; milestones with their UTC times):
```
scenario A runner started 2026-09-29T11:19:14Z
seed end block 240
scenario A: Friday close 1790689916, Monday open 1790690816
  ✓ the Friday Bell window (T−2h) with the −1% drift in                        11:52
  ok  /bell for priya == market.bellStatus at block 854: status 1, repay 139424111, collateral 1043203226711560045, premium 500000 (API 500000)
  ok  /bell for maya == market.bellStatus at block 854: status 1, repay 191661545, collateral 1434055707070707071, premium 500000 (API 500000)
  ✓ Priya auto-covered at the Bell (AutoCoverApplied)                          13:37:09
  ✓ Maya's pre-close sale settled (PRECLOSE auction)                           13:51:35
  ✓ the open prints: NVDA and TSLA in REOPEN                                   14:07:10
  ✓ Dev settled at the REOPEN auction with a shortfall
  ✓ the pool paid the shortfall and bought the unsold lot (ShortfallPaid, BackstopBought)
  ✓ J11 listed the backstop inventory (GdaStarted)
  ✓ J9 settled the epoch (EpochSettled)
  ok  no manual transaction after seeding (blocks 241..4374)
  ok  the keeper sent 0 failed txs (ops.keeper_tx reverted: 0)
  ok  keeper killed between fixLots and clear, then restarted (14:09:02 killed the keeper (pid 942123) between fixLots and clear; 14:09:22 restarted the keeper (pid 1716821))
  ok  after the restart every REOPEN auction cleared (2 J5 clear steps done) with no J5 step mined twice
  ok  /v1/auctions/1 (PRECLOSE) == auction(1): lot 4679260273798880202, R 176418000000000000000, p* 177300090000000000000, qPool 467926027379888021, proceeds 829220515
  ok  /v1/auctions/2 (REOPEN) == auction(2): lot 543162887446954431862, R 148652500000000000000, p* 149395762500000000000, qPool 54316288744695443187, proceeds 81105862472
  ok  /v1/auctions/3 (REOPEN) == auction(3): lot 100000000000000000000, R 252588000000000000000, p* 253850940000000000000, qPool 10000000000000000000, proceeds 25372464600
  ok  settlement of 0x194852a1A5c9bdBfCbeCC61Defa9750CCe4Ee149 in auction 1 == PositionSettled
  ok  settlement of 0x194852a1A5c9bdBfCbeCC61Defa9750CCe4Ee149 in auction 2 == PositionSettled
  ok  settlement of 0x225f8b5660CB5BACCa87F2A9182945dDD81e0629 in auction 2 == PositionSettled
  ok  settlement of 0x86a536f36f4DcFA5Da09ED92BdbD78480302d903 in auction 3 == PositionSettled
  ok  /v1/pool/equity == pool at block 4376: NAV 291844610396, share price 1024016176827985908
  ok  /v1/pool/equity/epochs[3] == pool.epoch(3): premiums 500000, losses 2155726104, NAV after 296964691106, share price 1024016176227503392
  ok  /v1/risk lists 3 cleared auctions and 2 pool(s)
  ok  J2 Bell heads-up for priya; delivered, status sent, 2 deliveries
  ok  J2 Bell heads-up for maya; delivered, status sent, 2 deliveries
  ok  auto-cover applied: premium == AutoCoverApplied.premium, status sent, 2 deliveries
  ok  auction settled for 0x1948…e149 (auctions 1 and 2), 0x225f…0629 (auction 2), 0x86a5…d903 (auction 3): proceeds/penalty/shortfall/refund == PositionSettled, status sent, 2 deliveries each
  ok  queued at the reopen: 0x1948…e149, 0x225f…0629 [REOPENQ:2], 0x86a5…d903 [REOPENQ:3], status sent, 1 delivery each
  ok  epoch settled for uma: share price == EpochSettled.sharePriceAfter (the template's unit: loan base units per share), status sent
  ok  epoch settled for sara: share price == EpochSettled.sharePriceAfter (the template's unit: loan base units per share), status sent
  ok  withdrawal claimable for Sara == the epoch's reserved assets, status sent
  (notification_log failures 0, dead jobs 0)
OK: scenario A ran keeper-only from the Friday Bell to epoch settlement; indexer/API == chain; every notification sent with the chain's amounts
keeper tx summary (ops.keeper_tx): job | mined | reverted | replaced | dropped | pending
  J1 | 558 | 0 | 0 | 0 | 0
  J11 | 2 | 0 | 0 | 0 | 0
  J3 | 1 | 0 | 0 | 0 | 0
  J5 | 9 | 0 | 0 | 0 | 0
  J6 | 3 | 0 | 0 | 0 | 0
  J8 | 8 | 0 | 0 | 0 | 0
  J9 | 2 | 0 | 0 | 0 | 0
  total | 583 | 0 | 0 | 0 | 0
PASSED: scenario A at 2026-09-29T14:18:35Z
```
The raw log also shows `keeper_failed_txs_total: none recorded`. That line comes from the runner's grep of a bare metric name, while the service exports `credence_keeper_failed_txs_total` (see "The runs", run 3). The runner is fixed after the run. The authoritative figure is `ops.keeper_tx` above: 0 reverted.

### The runs, honestly
1. **Run 1 (S3 night):** started 00:52 UTC and died with the laptop at 01:24 UTC, 13 min before the Bell. It left no line in `check.log`. That is why the watchdog and `systemd-inhibit` exist.
2. **Run 2 (08:08–11:08 UTC, fresh devnode):** every chain step passed, with 570 keeper txs and 0 reverted. **But 2 checker assertions failed.**
   - `check.ts` compared the `epoch_settled` share price (the notifier's documented unit: USDC base units per share, 1004277 = $1.004277) with the pool's WAD value.
   - The runner's cleanup line swallowed the process list, so the services were left running.

   Both were bugs in my test tooling, not in the stack; both are fixed in `1765464`. A partial run doesn't count, so the whole scenario ran again. Logs: `target/be/scenario-a-run-0808/`.
3. **Run 3 (11:19–14:18 UTC, fresh devnode): PASSED.**
   - It ran HEAD at the time, including BE-chain's QA fixes (ADR-0113), frozen v3 and my S4 keeper changes (Bell times from the chain, unpriced markets logged once).
   - Under ADR-0113, the low-ball bot's open bid below the reserve fails at gas estimation, so no tx is sent, as intended.
   - Found in this run, fixed in S4: no keeper or relayer alert rule matched the exported `credence_`-prefixed metric names (`c62962d`).
   - The cleanup stopped every service; none was left afterwards.

## 5. Deviations from the Build Guide
- **§10.3, market and position rows:** still read at the event's block. Borrow shares change without appearing in any event. → ADR-0011 (S3 update).
- **§10.2, J8 claim helpers:** the pool pays only `msg.sender`, so there is a `withdrawal_claimable` notification instead (PM: accepted).
- **S3 F, "Appendix A amounts":** checked against the chain's own events on the devnode → ADR-0012 (PM: accepted).
- **§10.2 gas margin:** ×1.3 as specified, but configurable (`KEEPER_GAS_MULTIPLIER_X10`).

## 6. Spec issues found
All four were ruled by the PM in `sprint-3-pm-review.md`:
1. ADR-0012.
2. J2 "binding".
3. J8 claim helpers.
4. J3 = 10 per tx.

## 7. Interfaces changed or published
- **API:** `/v1/pool/{stack}`, `/v1/pool/{stack}/epochs`, `/v1/auctions`, `/v1/auctions/{auctionId}`, `/v1/risk`; `/bell` `closure.epochId`; vault `cushion`; WS `auctions`, `bell:<owner>`.
- **Indexer views:** the S3 tables in §3.
- **Notifier events:** `reopen_queued`, `auction_settled`, `epoch_settled`, `withdrawal_claimable`.
- **Keeper env:** `KEEPER_J3_BATCH`, `KEEPER_FLAG_BATCH`, `KEEPER_SETTLE_BATCH`, `KEEPER_AUCTIONS`, `KEEPER_GAS_MULTIPLIER_X10`.
- **Relayer env:** `PRINT_SOURCE`, `REDSTONE_RECORDING`, `REDSTONE_SHIFT_S`, `REDSTONE_GATEWAYS`.
- **Metric:** `credence_keeper_failed_txs_total`.

## 8. Known gaps and TODOs
- **Relayer-side RedStone submission:** there is no relayer mode that submits to `RedStonePriceSource`, because it isn't in the deployed stack. → S5.

## 9. Needs from the user or the PM
- **Still open from S2:** rotate the vendor keys; ADR-0009 D2/D3.

## 10. How to verify from a clean checkout
```sh
make backend-install backend-build backend-test backend-lint
make infra-up db-migrate
make keeper-e2e keeper-core-e2e keeper-j7-e2e relayer-redstone-e2e indexer-core-e2e
ACCOUNT_SALT=$RANDOM make api-bell-e2e
make devnode-deploy-engine
make local-deploy-core CALENDAR=synthetic SYNTH_ARGS='--regular-minutes 155 --closure-minutes 15 --session-minutes 150' LOCAL_RPC=http://127.0.0.1:8547
setsid nohup systemd-inhibit --what=idle:sleep:handle-lid-switch --who=credence --why="scenario A e2e" make scenario-a-e2e &   # ≈ 3 h, real time
tail -f target/be/scenario-a/check.log
```
