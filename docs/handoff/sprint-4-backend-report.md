# Sprint 4 report · Senior Backend Engineer (BE-backend)

Date: 2026-09-29 · Session model: Claude Opus 5.5 · Commits: `62235eb..HEAD` (BE-backend paths only)

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
- **Not done:** the NAV settlement e2e on the devnode (G) is carried over (§8).

## 2. Acceptance checklist
| # | Item | Status | Proof (command + key output) |
| --- | --- | --- | --- |
| 1 | S3 closed: `make scenario-a-e2e` passes at real time with 0 failed keeper txs and the kill-watch restart; S3 report final; final S3 READY | see S3 report | `target/be/scenario-a/check.log`, S3 report §2 |
| 2 | `make backend-install backend-build backend-test backend-lint` from a clean clone | ✅ | Fresh `git clone` in a scratch dir, `CARGO_BUILD_JOBS=4 make backend-install backend-build backend-test backend-lint` → `EXIT 0` in 10 min 55 s. Tests: keeper 28, relayer 67, bidder/solver 10, API 44, SDK 44, notifier 27, indexer 7, feeds 9, calibration pytest (a later re-run follows in §4) |
| 3 | A done, with tests | ✅ | `cargo test -p credence-keeper --lib`: `unpriced_markets_are_logged_once_per_change` (NoReferencePrice and NoPrice), `bell_boundaries_follow_the_chain_offsets`, `targets_are_the_next_two_scheduled_closes`. Live in the S3 re-run: `Bell offsets window_s=7200 deadline_s=900` read from the clock; COIN / MSFT / SPY logged once each (the whole keeper log was 36 lines at seeding, against 11 MB in the first run); gauges `riskEngine.pricing` / `riskEngine.auctionMath` = 31,534,810 s, no RB-10 alert. Devnode test `keeper-j12-e2e` updated for the router (run after the S3 READY) |
| 4 | J10, solver bot, settlement indexer/API, notifier with unit tests; `make nav-settlement-e2e` if BE-chain's item E lands, else carried over with the reason | ✅ built / ⚠️ G carried over | Keeper `nav_jobs` tests (6): finalize only after the window, fill vs advance vs claim, `low` cursor, open batches (HF < 1, not in a lot, ≤ 128), keys, book. Solver `solver::tests` (4). Indexer `settlement-model.test.ts` (4). API `test/settlement.test.ts` (4). Notifier `test/navsold.test.ts` (3). G: §8 |
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
2. **Pool and auction ids can collide.** The market's NAV lot ids and the equity auction house ids share the indexer's `lot_position` key, and both start at 1. The notifier now joins on the market; the table key needs `market_id` in S5.

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
- **G, `make nav-settlement-e2e`: carried over.** Reasons:
  1. BE-chain's item E (NAV on the devnode, redeploying the main book) can only start after my final S3 READY.
  2. The devnode needs an issuer NAV-strike publisher, because the relayer refuses the NAV kind (`UnsupportedKind`). It must sign NAV reports with feed A's node keys, as DeployClockLocal's `navFeed` expects, and `publishNav` / `fulfillRedeem` as the issuer.
  3. At ≤ 0.5% per strike, reaching HF < 1 takes several USBANK cycles (§6.1).

  Plan:
  - a synthetic USBANK calendar with 20-min sessions;
  - seed at max LTV and let the publisher strike −0.45% per session;
  - J10 opens the REOPEN settlement; the solver fills it;
  - a second borrower on the next day, with the solver in its no-bid profile;
  - the issuer's T+1 `fulfillRedeem`, then J10's claim;
  - checks: indexer / API / notifier == chain.

  That is roughly 8 cycles × 35 min ≈ 5 h of real time, unless the PM accepts seeding positions closer to LT.
- **The Low / Info off-chain findings:** OFF-04…OFF-11 (WS origin and limits, push endpoint SSRF, Telegram chat id, indexer `/sql`, `/metrics` exposure, keeper fee ceiling, `esc` quotes, SIWE nonce burn) → S5.
- **`lot_position` key** needs `market_id` (§6.2).
- **The keeper's §16.1 gauges have not fired against a real Prometheus yet.** `make obs-up` against a live keeper is the next check; the promtool tests and the name regression test pass.

## 9. Needs from the user or the PM
- **G:** accept either a ~5-h real-time NAV run, or seeding NAV positions near LT (2 strikes) (§8).
- **Still open from S2/S3:** rotate the vendor keys; ADR-0009 D2/D3.

## 10. How to verify from a clean checkout
```sh
make backend-install backend-build backend-test backend-lint
docker run --rm -v $PWD/infra/prometheus:/etc/prometheus:ro -w /etc/prometheus --entrypoint promtool prom/prometheus:v3.6.0 test rules alerts.test.yml
make infra-up db-migrate && make devnode-deploy-engine keeper-j12-e2e
make local-deploy-core CALENDAR=synthetic SYNTH_ARGS='--regular-minutes 155 --closure-minutes 15 --session-minutes 150' LOCAL_RPC=http://127.0.0.1:8547
make scenario-a-e2e   # ≈ 2.5 h; the S4 keeper runs in it (Bell times from the chain, unpriced markets quiet)
```
