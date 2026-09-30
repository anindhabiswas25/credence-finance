# Sprint 4 report · Senior Backend Engineer (BE-backend)

Date: 2026-09-29, final 2026-09-30 (G) · Session model: Claude Opus 5.5 · Commits: `62235eb..HEAD` (BE-backend paths only)

## 1. Summary
- **S3 status:** see the acceptance row 1 and `docs/handoff/sprint-3-backend-report.md` (final).
- **Keeper clean-ups (A):**
  - A market with no price is logged once, not 28,979 times.
  - The Bell times come from the AssetClock.
  - The `programTimeLeft 0 days` alert was a wrong read of the Solidity router; J12 now watches its two Stylus programs.
- **The NAV off-chain stack is built on BE-chain's frozen v3 interfaces:**
  - J10 in the keeper;
  - a test solver bot;
  - the `settlement`, `solver_bid` and `redemption_claim` tables;
  - `/v1/settlements`, and the redemption claims at cost in `/v1/pool/nav`;
  - the `nav_sold` notification.
- **Every §16.1 alert has a rule and a promtool test, and the dashboards are provisioned.** The scenario run exposed a real bug here: the common registry prefixes every Rust metric with `credence_`, and no keeper or relayer rule matched the exported name, so none could ever have fired. Fixed, with a regression test.
- **QA-sec's three Medium off-chain findings (OFF-01…03) are fixed.**
- **G, the NAV settlement e2e on the devnode, passed on 2026-09-30 (S5)**, in 13 min on BE-chain's new-bundle book, after two root-cause fixes (§8).

## 2. Acceptance checklist
| # | Item | Status | Proof (command + key output) |
| --- | --- | --- | --- |
| 1 | S3 closed: `make scenario-a-e2e` passes at real time with 0 failed keeper txs and the kill-watch restart; S3 report final; final S3 READY | see S3 report | `target/be/scenario-a/check.log`, S3 report §2 |
| 2 | `make backend-install backend-build backend-test backend-lint` from a clean clone | ✅ | Fresh `git clone` in a scratch dir, `CARGO_BUILD_JOBS=4 make backend-install backend-build backend-test backend-lint` → `EXIT 0` in 10 min 55 s. Tests: keeper 28, relayer 67, bidder/solver 10, API 44, SDK 44, notifier 27, indexer 7, feeds 9, calibration pytest (a later re-run follows in §4) |
| 3 | A done, with tests | ✅ | `cargo test -p credence-keeper --lib`: `unpriced_markets_are_logged_once_per_change` (NoReferencePrice and NoPrice), `bell_boundaries_follow_the_chain_offsets`, `targets_are_the_next_two_scheduled_closes`. Live in the S3 re-run: `Bell offsets window_s=7200 deadline_s=900` read from the clock; COIN / MSFT / SPY logged once each (the whole keeper log was 36 lines at seeding, against 11 MB in the first run); gauges `riskEngine.pricing` / `riskEngine.auctionMath` = 31,534,810 s, no RB-10 alert. Devnode test `keeper-j12-e2e` updated for the router (run after the S3 READY) |
| 4 | J10, solver bot, settlement indexer/API, notifier with unit tests; `make nav-settlement-e2e` if BE-chain's item E lands, else carried over with the reason | ✅ | Keeper `nav_jobs` tests (6): finalize only after the window, fill vs advance vs claim, `low` cursor, open batches (HF < 1, not in a lot, ≤ 128), keys, book. Solver `solver::tests` (4). Indexer `settlement-model.test.ts` (4). API `test/settlement.test.ts` (4). Notifier `test/navsold.test.ts` (3). **G: `make nav-settlement-e2e` PASSED 2026-09-30 09:54Z** (13 min; 10.9 min after seeding; keeper-only: settlement 1 FILLED by the solver bot, settlement 2 ADVANCED by the pool with the solver in its no-bid profile, the issuer's T+1 `fulfillRedeem`, J10's claim; 0 keeper txs reverted, no J10 step mined twice; `/v1/settlements/{1,2}` == `adapter.settlement(id)`, `/v1/pool/nav` claim == `RedemptionClaimed`, `nav_sold` sent to both with amounts == `PositionSettled`). Log `target/be/nav-settlement/check.log` |
| 5 | Every §16.1 alert has a rule and a promtool test; dashboards provisioned | ✅ | `promtool check rules alerts.yml` → `SUCCESS: 18 rules found`; `promtool test rules alerts.test.yml` → `SUCCESS`. New: BellNotEnforced, ReopenStuck, EpochNotSettled, PoolUtilisation, ShortfallEscalated (existing: FeedStale, FeedDisagreement(Severe), KeeperLeaderMissing, WalletLow, WalletBelowFloor, CalendarCoverage, KeeperFailedTx, StylusActivation, …). Dashboards `infra/grafana/dashboards/{keeper,relayer,pool,auctions,api,indexer}.json`. `cargo test -p credence-keeper --test alert_names`: every queried keeper / relayer metric is registered |
| 6 | Report with ADRs for every deviation | ✅ | This file; ADR-0013 |

## 3. What was built
- **Keeper** (`services/keeper`):
  - `schedule.rs` `BellLeads`: reads `AssetClock.BELL_WINDOW` / `BELL_DEADLINE`, with a startup self-check, for J1 boundaries and J2/J3 `bellAt`.
  - `core_jobs.rs` `ReadState`: a market with no price is "not live", logged once per state change. Gauges `keeper_markets_unpriced`, `keeper_market_read_errors_total`.
  - `tasks.rs` `stylus_targets`: the router's `pricing()` / `auction()` programs are what J12 watches.
  - `nav_jobs.rs` J10:
    - `openSettlement`, `finalize` and `claimRedemption`, keyed `J10:<adapter>:<id>:<step>`;
    - `completeReopen` for NAV assets;
    - every step pre-checked by `eth_call`; a `RedemptionsGated` wait sends no tx.
  - J4 skips the NAV market (a direct `flagForAuction` reverts in v3).
  - §16.1 gauges: `keeper_bell_unenforced_positions`, `keeper_reopen_pending_seconds`, `keeper_epoch_unsettled_seconds`, `keeper_pool_utilisation_ratio`, `keeper_shortfall_escalations{layer}`.
- **Solver bot** (`services/bidder/src/solver.rs`, binary `credence-solver`):
  - watches `SolverWindowOpened`;
  - first bid floor × (1 + premium), then re-bids `minBid` (≥ 1.0001 × best) up to a cap;
  - pre-checks `canHold` and `eth_call`;
  - a `bid: false` profile forces the pool advance.
  - The bidder bot now pre-checks `placeBid` (a bid below the reserve reverts since ADR-0113).
- **Indexer:** tables `settlement`, `solver_bid` and `redemption_claim` (`indexer/src/settlement.ts`, `settlement-model.ts`), from the SDK's v3 ABIs.
- **API** (`services/api/src/settlement.ts`):
  - `GET /v1/settlements?market=&status=&cursor=&limit=` and `/v1/settlements/{id}` (outcome: solver fill or pool advance, with bid list);
  - `/v1/pool/{stack}.redemptionClaims` (outstanding at cost, §8.6.1);
  - OpenAPI and zod.
- **Notifier:** `nav_sold` (email, push, Telegram): solver fill or pool advance, sold quantity, price and floor to 4 decimals, proceeds, penalty, repaid, refund, shortfall, HF after. The `auction_settled` scan now also matches the auction's market.
- **SDK:** ABIs from `deployments/abis/v3`.
- **Ops:**
  - `infra/prometheus/alerts.yml` group `credence-risk` and its promtool tests;
  - every rule and dashboard uses the exported `credence_keeper_*` / `credence_relayer_*` names;
  - dashboards `pool.json`, `auctions.json`.
- **Security (QA-sec OFF-01…03):**
  - relayer node `seq` window and `observedAt` check (`ocr::verify_seq`);
  - node bearer token required off dev chains, and the node listens on 127.0.0.1 by default;
  - the API reads `X-Forwarded-For` only from `TRUSTED_PROXIES`.
- **Scenario runner** (S3):
  - `check.log` is written by the runner;
  - a watchdog writes `ABORTED: <reason>` and stops the run when any of these fail: the devnode RPC or clock, Postgres, any service, or the host staying awake;
  - the keeper tx summary;
  - fixes to the relayer-B allowlist, the cleanup and the share-price unit.

## 4. Test results
(final numbers pasted at the end of the sprint)

## 5. Deviations from the Build Guide
- **§10.2 J12 "Stylus programTimeLeft":** the configured `shared.riskEngine` is a Solidity router (ADR-0108). J12 checks the two programs behind it. → ADR-0013 §4.
- **§16.1 alert inputs:** the pool, auction and shortfall alerts are computed from keeper gauges, because the keeper reads the chain every tick. The shortfall alert is a delta of a recounted gauge, so a restart can't fire it. → ADR-0013 §6.
- **S4 C "extend services/bidder or add services/solver":** a second binary of `services/bidder`, so the workspace needs no new member. → ADR-0013 §7.

## 6. Spec issues found
1. **The NAV e2e takes many real-time days.** The oracle refuses a NAV strike that drops more than 0.5% (`NAV_MAX_DROP`), and there is one strike per USBANK session. So a NAV position at max LTV (0.90, LT 0.93) needs about 8 strikes before HF < 1; BE-chain's forge scenario also uses 8. A devnode e2e at real time needs 8 USBANK cycles, unless the seeding places positions nearer LT (§8).
2. **Lot ids from two id spaces.** The NAV market's lot ids (= settlement ids) and the equity auction house's ids both start at 1. **Fixed** (`da70569`): `lot_position` is keyed by (market contract, id, owner); the auction routes read only the auction house's lots; the notifier joins on the market (`07fbebe`).

## 7. Interfaces changed or published
- **API:**
  - new `GET /v1/settlements`, `GET /v1/settlements/{id}`;
  - `/v1/pool/{stack}` gains `redemptionClaims`;
  - new env `TRUSTED_PROXIES`.
- **Indexer views:** `settlement`, `solver_bid`, `redemption_claim`.
- **Notifier event:** `nav_sold` (dedupe `NAVSOLD:<settlement>:<owner>`).
- **Keeper:**
  - env `KEEPER_NAV` (default 1);
  - metrics: the gauges in §3, all exported with the `credence_` prefix.
- **Relayer:** a standalone node needs `RELAYER_NODE_TOKEN` (≥ 32 bytes) off dev chains; `NODE_LISTEN` defaults to `127.0.0.1:8080`.
- **SDK:** ABIs v3.

## 8. Known gaps and TODOs
- **G, `make nav-settlement-e2e`: done on 2026-09-30 (S5).** The PM ruled for positions seeded near LT (≤ 30 min). Two root causes found on the way:
  1. **07:36 run: the indexer never built its position rows.** Ponder's pinned reads hit state the nitro devnode had pruned (it keeps about 128 blocks), so J10's query failed. Fix `7b3182c`: a pruned-state read retries at the head block (from a plain client, not Ponder's cached `latest`). Free testnet RPCs are not archive nodes either, so the fix matters there too.
  2. **15:09 attempt: a fresh book's TBILL is HALTED** until its first NAV print, which moves it to REOPEN, and the seed's `borrow` reverted (`ActionNotAllowedInState(0, 3)`). Fix `54e6c46`: the seed completes the reopen (120-s queue, `completeReopen`) before borrowing.
- **Off-chain findings:** OFF-04c (`ffd8b05`), OFF-07 (`535923e`) and OFF-08 (`eb1f65a`) are fixed in S5. OFF-06 (the Telegram `/start <token>` link) and OFF-11 (burn the SIWE nonce only after the signature verifies) stay pre-mainnet (PM, 2026-09-30).
- **Fixed:** OFF-01…03 (`de6d1bd`), and OFF-04 a/b, OFF-05, OFF-09 and OFF-10 (`3d23f80`).
- **The keeper's §16.1 gauges have not fired against a real Prometheus yet.** `make obs-up` against a live keeper is the next check; the promtool tests and the name regression test pass.

## 9. Needs from the user or the PM
- **Still open from S2/S3:** rotate the vendor keys; ADR-0009 D2/D3.

## 10. How to verify from a clean checkout
```sh
make backend-install backend-build backend-test backend-lint
docker run --rm -v $PWD/infra/prometheus:/etc/prometheus:ro -w /etc/prometheus --entrypoint promtool prom/prometheus:v3.6.0 test rules alerts.test.yml
make infra-up db-migrate && make devnode-deploy-engine keeper-j12-e2e
make local-deploy-core CALENDAR=synthetic SYNTH_ARGS='--regular-minutes 155 --closure-minutes 15 --session-minutes 150' LOCAL_RPC=http://127.0.0.1:8547
make scenario-a-e2e   # ≈ 2.5 h; the S4 keeper runs in it (Bell times from the chain, unpriced markets quiet)
# G (after BE-chain's main book, USBANK in session): ≤ 30 min
make nav-settlement-e2e
```
