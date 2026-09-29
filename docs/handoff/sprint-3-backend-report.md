# Sprint 3 report · Senior Backend Engineer (BE-backend)

Date: 2026-09-29 · Session model: Claude Opus 5.5 · Commits: `4cacbf7..HEAD` (BE-backend paths only)

**Status: interim.** This report was written at 00:55 UTC. `make scenario-a-e2e` (acceptance 3, 4, 5, 6) is still running on the devnode and ends at about 02:25 UTC, because the devnode's clock cannot be sped up. Section 2 marks those rows ⏳ and gives the evidence collected so far. A final update of this file follows the run.

## 1. Summary
- **The S2 carry-over is closed.** `make api-bell-e2e` passes on the devnode with 0 mismatches over 100 positions, and again from scratch with 100 new positions created by the script.
- **The keeper can drive the whole closure cycle by itself.** It uses `credence-bindings` v2. J3 (batches of 10), J4, J5 (flag, `fixLots`, `clear`, `settlePositions`, `completeReopen`), J6, J8 (pool step), J9 (open, snapshot, settle) and J11 (GDA) run live, and every step is pre-checked with views plus an `eth_call`. Every tx job is restart-safe, and there is a test bidder bot.
- **The indexer serves pools, epochs, policies, auctions, bids, lots and GDAs** as pure projections of the v2 events. The API has the pool, epoch, auction and risk endpoints, the WS `auctions` and `bell:<owner>` channels, and the vault cushion.
- **The notifier sends every §10.5 event with exact amounts**, triggered from indexer rows.
- **The RedStone print mode (ADR-0009 D1)** is proven on real recorded packages, and BE-chain's `RedStonePriceSource` accepts the relayer's payloads on anvil and on the devnode.
- **Not finished yet:** the full keeper-only scenario A run on the devnode is in progress (see §2).

## 2. Acceptance checklist
| # | Item | Status | Proof (command + key output) |
| --- | --- | --- | --- |
| 1 | `make backend-install backend-build backend-test backend-lint` passes; e2e targets pass with `infra-up db-migrate` | ✅ (working tree; clean-clone re-run pending) | `make backend-build backend-test backend-lint` → exit 0. Tests: keeper lib 19, relayer 67 + `redstone_prints` 5, bidder 6, SDK 44, API 40 (+2 DB), notifier 24 (+3 e2e), indexer 3, feeds 9, calibration 42. E2e: `keeper-e2e` 4 tests (with the new `killed_mid_job_restart_resumes_without_duplicates` and `stuck_tx_is_replaced_after_3_blocks_at_plus_20_percent`), `keeper-core-e2e`, `keeper-j7-e2e` 2 (devnode σ through `SigmaOracle`), `indexer-core-e2e`, `relayer-redstone-e2e` 2 |
| 2 | `make api-bell-e2e` passes on the devnode, with the ANSWER posted | ✅ | `/bell vs chain: 100 positions checked (NEEDS_ACTION 13), mismatches 0`, `OK: /bell == CredenceMarket.bellStatus (status, cures) and engine.quoteCover (premium, E[L], ES)`, both on BE-chain's positions and from scratch (`ACCOUNT_SALT=s3-backend`, 34 min). Board ANSWER 00:40. On the real v2 pool, scenario A also checks `/bell` premium == `bellStatus` premium: `ok /bell for priya == market.bellStatus at block 12022: status 1, repay 139432073, … premium 500000 (API 500000)`, same for Maya |
| 3 | `make scenario-a-e2e` passes on the devnode with no manual tx after seeding; the keeper sends 0 failed txs | ⏳ running (ends ≈ 02:25 UTC) | So far: seeding ended at block 11364; since then only the keeper, the relayers and the bot have sent txs. J9 `openEpoch` at the Bell window. J2 T−2h heads-ups sent to Priya and Maya (6 `bell_headsup` jobs sent). **Keeper: 287 txs mined, 0 reverted.** Still to come: the Bell (01:37), the Friday close (01:52), the Monday open (02:07), the REOPEN auction, settlement and `settleEpoch` |
| 4 | Keeper restart test: killed between J5 `fixLots` and `clear`; completes with no duplicate tx | ⏳ in the same run | `kill-watch.sh` SIGKILLs the keeper right after its first `J5:…:fixLots` is done and restarts it 20 s later; `check.ts` asserts every J5 step is mined once. The generic mechanism is already proven by `keeper-e2e` (a real binary killed with its tx pending: `done, 1 tx, nonce delta == mined keeper txs`) |
| 5 | Indexer serves pools, epochs, policies, auctions, bids and GDA from events; API == chain at the same block | ⏳ (built; the devnode comparison runs in scenario A) | Handlers in `indexer/src/risk.ts` are pure projections (no RPC reads). The SQL of every API and notifier query was checked against a live Ponder run. `check.ts` compares every `/v1/auctions/:id`, every settlement row, `/v1/pool/equity` and `/v1/pool/equity/epochs` with the chain at the API's block |
| 6 | The notifier e2e covers every §10.5 event with exact amounts | ⏳ (unit ✅; the devnode run is in scenario A) | `test/producer.test.ts` + `test/templates.test.ts` (auto-cover, reopen queue with countdown, auction settled incl. the pre-close sale and a shortfall, epoch settled, withdrawal claimable), with the S-B numbers ($9,998.82). `notifier-e2e` covers email + push + Telegram, retries and dead-letters. `check.ts` asserts each job is `sent` with amounts equal to the chain's events |
| 7 | Report with ADRs for every deviation | ✅ (this file; final update after the run) | ADR-0011 (S3 update), ADR-0012 (scenario A on the devnode) |

## 3. What was built
- **Keeper** (`services/keeper`):
  - `core.rs`: bindings from `credence-bindings`.
  - `txjob.rs`: restart-safe tx jobs; every `submitted` key is reconciled each tick, orphaned `running` jobs are released on leadership, and a timeout stays `submitted`.
  - `auction_jobs.rs`: J5 flags and the J5/J6 auction driver.
  - `pool_jobs.rs`: J9, J11, J8 pool, J5 `completeReopen`.
  - `core_jobs.rs`: J3 live (batches keyed by their borrowers, a page at bellAt + 10 min), J4 live, J2 fix.
  - `sigma_runner.rs`: `sigmaAt`.
  - `keeper_failed_txs_total`, `KEEPER_GAS_MULTIPLIER_X10`, batch sizes from BE-chain (J3 10, flag and settle 128).
- **Bidder bot** (`services/bidder`): commit / reveal / place / claim from a JSON config (honest, low-ball and non-revealing profiles), a persisted salt, and a `canHold` pre-check.
- **Relayer** (`services/relayer/src/vendor/redstone.rs`):
  - `PRINT_SOURCE=redstone`: 3-of-5 verification like the connector, the D1 OPEN/CLOSE rules, the `OracleFirstRegular` flag, gateway history or recordings with a time shift.
  - The `redstone-record` CLI and the payload builder.
  - Fixtures: the real Mon 2026-09-28 open and close windows.
- **Indexer** (`indexer/src/risk.ts`, `ponder.schema.ts`): `pool`, `epoch`, `cover_policy`, `pool_flow`, `pool_request`, `pool_holder`, `backstop_inventory`, `auction`, `bid`, `lot_position`, `gda`, `open_print`; the market handlers are on v2 (`PositionSettled`, `AutoCoverApplied`).
- **API** (`services/api/src/rt.ts`, `stream.ts`, `core.ts`): `GET /v1/pool/:stack`, `/v1/pool/:stack/epochs`, `/v1/auctions`, `/v1/auctions/:id`, `/v1/risk`; the vault `cushion`; `/bell` with the pool `epochId`; WS `auctions` and `bell:<owner>` (the SIWE cookie is checked at the upgrade); OpenAPI and zod on every route.
- **Notifier**: `producer.ts` (indexer-triggered events, idempotent dedupe keys) and the templates for the four new §10.5 events.
- **SDK**: ABIs v2.
- **Scenario toolkit** (`services/api/scripts/scenario-a/`): on-chain calendar export, the replay recording, seeding, mock providers, `kill-watch.sh`, `check.ts`, `run.sh`.
- **Make targets**: `scenario-a-e2e`, `relayer-redstone-e2e`.
- **Observability**: the `KeeperFailedTx` alert, with a promtool test.

## 4. Test results
See the acceptance row 1. The scenario A output will be pasted here after the run.

## 5. Deviations from the Build Guide
- **§10.3, market and position rows:** still read at the event's block. Auto-cover and settlement change borrow shares without the shares appearing in any event, and debt accrues interest between events. All S3 tables are pure projections. → ADR-0011 (S3 update).
- **§10.2, J8 "`claimDeposit` / `claimWithdraw` helpers":** the pool pays only `msg.sender`, so the keeper cannot claim for underwriters. J8 releases due R-11 loss reserves instead, and underwriters get a `withdrawal_claimable` notification.
- **S3 F, "Appendix A amounts":** on the devnode, the amounts are checked against the chain's own events. → ADR-0012.
- **§10.2 gas margin:** ×1.3 as specified, but configurable. The devnode scripts use ×1.5 for Nitro's reentrancy-sentry refund (BE-chain 00:26).

## 6. Spec issues found
1. **Scenario A on the devnode (ADR-0012).**
   - A devnode can't warp time, so a compressed WEEKEND closure counts as 1 day for `closureDays`, not 3.
   - The Stylus engine prices with QE's calibrated sets, while Appendix A's scenario figures come from `MockRiskEngine`-injected premiums.
   - So the devnode e2e checks amounts against the chain. Cent-level Appendix A stays in BE-chain's forge scenario.
2. **§10.2 J2 "binding".** With QE's sets, the safe LTV is capped at the max LTV (75%) on every equity weekend. A market-level test (safe < max) therefore never sends a heads-up, although a position above 75% after a price move needs action at the Bell. I implemented "binding for any live position" and send one heads-up per NEEDS_ACTION position. I found this during the scenario run and fixed it in `3418d02`.
3. **J8 claim helpers:** see §5.
4. **J3 throughput (BE-chain's measurement):** 10 auto-covers per 24M-gas tx means a busy Friday needs many J3 txs inside the 15-minute Bell deadline.

## 7. Interfaces changed or published
- **API:** `/v1/pool/{stack}`, `/v1/pool/{stack}/epochs`, `/v1/auctions`, `/v1/auctions/{auctionId}`, `/v1/risk`; `/bell` `closure.epochId`; vault `cushion`; WS `auctions`, `bell:<owner>`.
- **Indexer views:** the S3 tables in §3.
- **Notifier events:** `reopen_queued`, `auction_settled`, `epoch_settled`, `withdrawal_claimable`.
- **SDK:** ABIs v2.
- **Keeper env:** `KEEPER_J3_BATCH`, `KEEPER_FLAG_BATCH`, `KEEPER_SETTLE_BATCH`, `KEEPER_AUCTIONS`, `KEEPER_GAS_MULTIPLIER_X10`.
- **Relayer env:** `PRINT_SOURCE`, `REDSTONE_RECORDING`, `REDSTONE_SHIFT_S`, `REDSTONE_GATEWAYS`.
- **Metric:** `keeper_failed_txs_total`.

## 8. Known gaps and TODOs
- **Scenario A result:** pending (§2, rows 3–6).
- **Run incident (00:52 UTC, honest note):** the first runner crashed at T−2h. The API refused to start because `CALENDAR_DIR` held non-calendar JSON; the runner's cleanup then stopped the relayers. For about 90 s the feeds were stale, and the three assets HALTED fail-closed, as designed. I restarted the services by hand, and the keeper returned the assets to REGULAR by itself (J5 `completeReopen` ×3, 0 reverted). The runner is fixed in `ae87352`. No chain tx was sent by hand.
- **J11 on the devnode:** only exercised if the REOPEN auction leaves `qPool > 0`; the scenario is designed for it.
- **Relayer-side RedStone submission:** there is no relayer mode that submits to `RedStonePriceSource`. Only the e2e test submits, because `RedStonePriceSource` isn't in the deployed stack.

## 9. Needs from the user or the PM
- Rulings on §6 items 1–3.
- From S2, still open: rotate the vendor keys; ADR-0009 D2/D3 (RedStone coverage and written permission; gates the public testnet).

## 10. How to verify from a clean checkout
```sh
make backend-install backend-build backend-test backend-lint
make infra-up db-migrate
make keeper-e2e keeper-core-e2e keeper-j7-e2e relayer-redstone-e2e indexer-core-e2e
ACCOUNT_SALT=$RANDOM make api-bell-e2e
make local-deploy-core CALENDAR=synthetic SYNTH_ARGS='--regular-minutes 155 --closure-minutes 15 --session-minutes 150' LOCAL_RPC=http://127.0.0.1:8547
make scenario-a-e2e          # ≈ 2.5 h on the devnode's wall clock
```
