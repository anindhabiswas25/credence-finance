# Sprint 1 report · BE-backend

Date: 2026-09-28 · Session model: Claude Opus 5.5 (`claude-opus-5-5`) · Commits: `b5ef7bd..HEAD` (backend commits: b5ef7bd, a6517b1, 1fa4c83, 905d589, fcd1f83, 8665345, 360f65b, e91d495, aa3d5df, bfd9cea, 4ff2ecd, b3383b8, and the commit that adds this report)

## 1. Summary
The backend foundation runs end to end on the local stack.
- `make infra-up` brings Postgres 17 and a bootstrapped, Stylus-capable nitro-devnode up healthy.
- `make db-migrate` applies the `ops` and `app` schemas with dbmate.
- The calendar generator produces 13 months of XNYS and USBANK `Session[]`, which BE-chain loads byte-for-byte.
- The **price relayer** is production-shaped: two licensed-vendor adapters (Polygon/Massive, Alpaca), a replay vendor, SIP trade-condition filtering with the NBBO check, the cadence rules, and 3 signer nodes + an aggregator with 2-of-3 EIP-712 signatures that match the contract.
  - Its digest is proven equal to viem's (cross-language vectors) and to the contract's `hashReports`.
  - On anvil and on the devnode, 2-of-3 batches are accepted, and 1-of-3, wrong-domain, unsorted, replayed and old-seq batches are rejected.
- The **keeper** pokes the real `AssetClock` at every calendar boundary, with a Postgres idempotency store, write-ahead transactions, nonce management, two-RPC failover and advisory-lock leader election. The failover test kills, hangs and crashes leaders without a duplicate transaction.
- The **Ponder indexer** and the **Hono API** serve `GET /v1/clock/:assetId` from indexed `StateChanged` / `ReportAccepted` events.

The live vendor smoke tests pass with the user's free keys (Polygon Basic, Alpaca IEX). A real Friday-close session recorded from Alpaca replays through the full relayer onto the devnode. What remains open is commercial: the free and individual vendor plans give no SIP real-time data on Polygon and IEX-only data on Alpaca, and they do not allow the on-chain redistribution that testnet needs (ADR-0002).

## 2. Acceptance checklist

| # | Item | Status | Proof (command + key output) |
| --- | --- | --- | --- |
| 1 | `make backend-install backend-build backend-test` passes from a clean checkout; `make infra-up` healthy; `make db-migrate` succeeds | ✅ | Clean export (`git archive HEAD`) → `make backend-install backend-build backend-test` → `EXIT 0` (Rust 11 + 5 + 51 + 1 passed, SDK 37, API 12, indexer 2, calendar 17). `make infra-up` → `Container credence-devnode-1 Healthy`, `Container credence-postgres-1 Healthy`, `devnode-init Exited (0)`. `make db-migrate` → `Applied: 20260927000001_ops_schema.sql … 20260927000004_keeper_leader.sql` |
| 2 | Calendar JSON for XNYS and USBANK (13 months) via `make calendar-gen`; every edge-case test passes; READY on the board | ✅ | `make calendar-gen` → `calibration/out/calendars/{XNYS,USBANK}-20261001-20271031.json`. `make calendar-test` → `17 passed` (Thanksgiving + Black Friday 13:00, Good Friday, July 4 on a weekday (2028) and on a Friday (2025), both DST weekends, New Year, Christmas, MLK, Fed rules). CI regenerates and diffs the committed files. READY 2026-09-27 21:45; BE-chain confirmed byte-for-byte |
| 3 | Relayer unit tests (filtering, cadence, median proposal, signing tolerance); cross-language test: Rust EIP-712 digest == SDK viem digest | ✅ | `cargo test -p credence-relayer` → `51 passed` (filter 6, cadence 5, ocr 6 incl. `node_signs_only_within_0_10_percent`, conditions 5, report 5, vendors 17, …). `cargo test -p credence-relayer --test eip712_vectors` → `1 passed` (the committed vectors equal the Rust output). `pnpm --filter @credence/sdk test` → `37 passed`: every digest, domain separator and reports hash equals viem, and viem `signTypedData` gives **byte-identical** signatures to the Rust signer (RFC 6979) |
| 4 | Relayer e2e on a local chain: accepted 2-of-3; rejected 1-of-3, stale `seq`, wrong domain | ✅ | `make relayer-e2e` (anvil, real `CredencePriceFeed` from `contracts/out`) → `test relayer_end_to_end_on_local_chain ... ok`. Asserts: on-chain `hashReports` == Rust digest; 3 nodes + aggregator on the replay vendor → **one** tx with STATUS+OPEN+LIVE for 2 assets **Accepted**; `NotEnoughSigners` (1-of-3), `UnknownSigner` (wrong chain id / wrong verifying contract), `SignersNotSorted`, `StaleReport` (replayed seq and older seq). Same test on the devnode: `E2E_RPC_URL=http://127.0.0.1:8547 …` → ok, and with Postgres every report is in `ops.relayer_report` (`accepted`, 3 signers, tx hash) |
| 5 | Both real vendor adapters compile, with recorded-response tests; live smoke test if keys are provided, else BLOCKED with the exact keys | ✅ (free tiers) | Recorded-response tests: Polygon 6, Alpaca 5, Nasdaq halts 3, plus a **real recorded session** test (`tests/replay_recorded.rs`, Alpaca IEX, Fri 2026-09-25 15:45–16:05 ET). **Live smoke** with the user's free keys (`make relayer-smoke VENDOR=…`, calendar covering Fri 2026-09-25): **Alpaca**: status OK, LIVE OK (1,000 IEX trades + NBBO; the newest odd-lot Form T print is correctly ineligible), official open 225.20 / close 225.04 (IEX daily bar). **Polygon**: status + halts OK; LIVE `NOT_ENTITLED` (Basic has no real-time trades/NBBO, as expected); official open 225.13 / close 225.07 (consolidated). The recorded session replayed through the full relayer on the devnode put NVDA 225.34 / AAPL 340.775 on-chain (2-of-3, one tx per tick). SIP-quality LIVE needs paid plans (ADR-0002) |
| 6 | Keeper: J1 pokes on schedule against a local `AssetClock`; leader-failover test (kill the leader, the follower takes over, no duplicate side effects) | ✅ | `make keeper-e2e` → `j1_pokes_on_schedule ... ok`, `leader_failover_no_duplicates ... ok`. J1: the real `AssetClock` (BE-chain's `DeployClockLocal` + the repo calendars), chain time at Wed 2026-10-07. Heartbeat poke at 09:29:30; the open boundary fires at **09:30:01** (block timestamp asserted), its receipt carries `StateChanged`; no poke within the same minute; the Bell-window boundary (14:00:01) pokes; exactly 1 tx per key. Failover: (a) kill → takeover < 15 s, and the follower re-runs the minute with **0** new pokes; (b) hung leader → fenced after **15 s** of missed heartbeats (asserted 14–20 s); (c) crash after broadcast → the new leader reconciles the recorded tx, **1** tx for the key |
| 7 | The indexer indexes `StateChanged` and `ReportAccepted` from a local run; `GET /v1/clock/:assetId` returns them | ✅ | `make indexer-e2e` (devnode) → `OK: StateChanged + ReportAccepted indexed and served by GET /v1/clock/:assetId`; the response shows `"state": {"code": 4, "name": "HALTED"}`, `transitions: [{from: CLOSED, to: HALTED}]`, `feeds: [{feed: "A", seq: "3", price: "181.33"}]` |
| 8 | Sprint report from the template, every deviation backed by an ADR | ✅ | This file; ADR-0001 … ADR-0007 in `docs/adr/` |

## 3. What was built

| Path | Purpose |
| --- | --- |
| `package.json`, `pnpm-workspace.yaml`, `turbo.json`, `packages/config/` | pnpm 10 + turbo workspace; shared tsconfig / eslint (flat) / prettier presets |
| `.env.example` | Every §12.1 variable plus the service-specific ones, documented |
| `mk/backend.mk` | `backend-install/build/test/lint/fmt`, `infra-up/down/reset/ps`, `db-migrate/rollback`, `calendar-gen/test`, `relayer-dev/smoke/e2e`, `keeper-dev/e2e`, `indexer-dev/e2e`, `api-dev`, `services-up` |
| `.github/workflows/ts.yml`, `services.yml` | TS build/typecheck/lint/test and calendar reproducibility; Rust fmt/clippy `-D warnings`/test, plus relayer and keeper e2e on anvil + Postgres |
| `infra/docker-compose.yml`, `infra/devnode/` | Postgres 17 (host 5433), nitro-devnode v3.7.1 with an idempotent bootstrap (chain owner, L1 price 0, CREATE2, cache manager, StylusDeployer), dbmate, and relayer/keeper service containers |
| `infra/db/migrations/` | `ops` (keeper_job, keeper_tx, keeper_instance, relayer_report), `app` (§11.2 + siwe_nonce), read-only API role |
| `infra/docker/rust-service.Dockerfile` | Release image for the relayer / keeper |
| `calibration/` | uv project (Python 3.13): `credence_cal/calendar.py`, tests, generated calendars |
| `crates/credence-common/` | Env config, JSON telemetry, ops server (`/healthz`, `/readyz`, `/metrics`), signers (AWS KMS / dev-only local key, low-s), calendar model, retry, Postgres + scratch-DB test helper |
| `services/relayer/` | `MarketDataVendor` (Polygon, Alpaca, replay), Nasdaq halt feed, SIP condition filter, NBBO check, cadence, OCR-lite (`ocr.rs`), signer node HTTP API, aggregator, chain client, `ops.relayer_report` store, metrics; binary `run` / `node` / `aggregator` / `smoke` / `sample-replay` |
| `services/keeper/` | Scheduler, calendar trigger source, J1 + J12, `ops.keeper_job` store, write-ahead tx manager (nonce, ×1.3 gas, +20% replacement after 3 blocks), 2-RPC failover, advisory-lock leader with fencing, metrics |
| `packages/sdk/` | ABIs generated from `deployments/abis/v0`, address-book loader (§13.2 + local flat), shared types/enums, EIP-712 `Report` builder (`reportsDigest`, `reportsTypedData`), `assetId`, `venueId` |
| `indexer/` | Ponder 0.17: `clock_state`, `clock_transition`, `price_point`; handlers for AssetClock and CredencePriceFeed (A/B); SQL/GraphQL API; `scripts/e2e.sh` |
| `services/api/` | Hono on Node 24: zod + OpenAPI (`/v1/openapi.json`), `/healthz`, `/readyz`, `GET /v1/clock/:assetId`, SIWE nonce/verify/session/logout with an httpOnly cookie, per-IP/per-session rate limits, CORS allowlist, pino logs |
| `docs/adr/ADR-0001…0007-backend-*.md` | Decisions (§5) |

## 4. Test results

All runs are on this machine (2026-09-28). The acceptance runs used the `make` targets.

```text
# make backend-test on a clean export (git archive HEAD), EXIT 0
credence-common        test result: ok. 11 passed; 0 failed
credence-keeper (unit) test result: ok. 5 passed; 0 failed
credence-relayer (unit) test result: ok. 51 passed; 0 failed
eip712_vectors         test result: ok. 1 passed; 0 failed
@credence/sdk          Tests  37 passed (37)     # incl. 30 cross-language EIP-712 checks over 6 vectors
@credence/api          Tests  12 passed (12)
@credence/indexer      Tests  2 passed (2)
calibration            17 passed in 14.88s

# make relayer-e2e (anvil)          test relayer_end_to_end_on_local_chain ... ok   (0.97 s)
#   same test on the nitro-devnode + Postgres (E2E_RPC_URL, TEST_DATABASE_URL) ... ok
# make keeper-e2e (anvil + postgres) j1_pokes_on_schedule ... ok
#                                     leader_failover_no_duplicates ... ok        (50.3 s, incl. the 15 s fence)
# make indexer-e2e (devnode)          OK: StateChanged + ReportAccepted indexed and served by GET /v1/clock/:assetId
# make backend-lint                   rustfmt --check, clippy -D warnings (3 crates, all targets), eslint + tsc: Tasks 7/7 successful
# docker build -f infra/docker/rust-service.Dockerfile --build-arg BIN=credence-relayer .   EXIT 0
```

Live run on the devnode (`make relayer-dev`: 3 nodes + aggregator, replay vendor, 2 assets): the first tick submits STATUS + OPEN + LIVE for both assets in **one** tx, then a LIVE heartbeat every 10 s. `/readyz` 200, and `/metrics` shows `credence_relayer_submits_total{result="ok"}`, `reports_accepted_total{kind=live|open|status}`, `node_spread_ppm`, `last_seq`, and report latency histograms.

No coverage tool is configured for the services yet. Gas snapshots and Stylus size belong to BE-chain.

## 5. Deviations from the Build Guide

| Guide section | What I did instead | Why | ADR |
| --- | --- | --- | --- |
| §6.3 / §6.4 (Drizzle, sqlx migrations) | One migration tool for the whole repo: **dbmate** (plain SQL), as the brief asks; Drizzle and sqlx are query layers only | One DDL source for Rust and TS | ADR-0001 |
| §11.2 / §11.3 tables | Extra columns and tables (`app.siwe_nonce`, `ops.keeper_instance`, status/claim/sender columns) | Single-use SIWE nonces, leader fencing, audit trail | ADR-0001 |
| §8.2.1 XNYS windows | Early-close days: post-market ends 17:00 ET | Real venue hours; the guide is silent on early closes | ADR-0003 |
| §8.2.1 USBANK | extOpen 08:00, open 09:00, close 17:00, extClose 18:00 ET | Strictly increasing timestamps are required; NAV strike 17:00 | ADR-0003 |
| §10.1 STATUS halt feed | Nasdaq Trader public halt feed for both feeds | No REST halt endpoint at either vendor; a halt only restricts | ADR-0002 |
| §13.1 replay guard | The replay vendor refuses **every** non-dev chain, not only 421614 | Stricter fail-safe | ADR-0004 |
| §10.4 `siwe` package | `viem/siwe` | Same EIP-4361 semantics without an ethers dependency | ADR-0007 |
| §10.4 rate limits | In-process fixed window per IP/session | Sprint 1 has one replica; a shared store comes with S5 | ADR-0007 |
| §11.1 `price_point.status` | Nullable | `ReportAccepted` has no status field | ADR-0007 |
| §6.4 TypeScript | Indexer on TS 5.9, others on 6.0 | Ponder 0.17 peers `typescript ^5` | ADR-0007 |

## 6. Spec issues found
1. **§6.1 vs §6.3 toolchain.** The example pin `channel = "1.91.0"` cannot build `alloy = 2.5.0` (every alloy 2.5 crate has `rust-version = 1.94.1`). Resolved by BE-chain pinning 1.95.0 (ADR-0102, ADR-0005). §6.1 should say ≥ 1.94.1.
2. **§6.3 `alloy` features `signer-aws` vs a direct `aws-sdk-kms`.** `alloy-signer-aws 2.5.0` pins `aws-smithy-types =1.6.1`, so a service cannot add a current `aws-sdk-kms`. Use the client alloy re-exports (ADR-0005).
3. **§10.1 vendor licensing.** "Any licensed real-time SIP source (Polygon.io, … Alpaca …)": the individual plans of both are personal-use only. On-chain publication needs business/redistribution agreements (ADR-0002). The guide should budget and name them.
4. **§8.3.1 `observedAt ≤ block.timestamp + 5 s` on chains that mine on demand.** Estimation against a stale head rejects fresh reports (seen on the devnode). The relayer handles it (ADR-0004 §9); worth a note for anyone else submitting reports.
5. **§11.1 `price_point.status`** is not derivable from `ReportAccepted(asset, kind, price, observedAt, seq)`. Either add `marketStatus` to the event (BE-chain, interface v1) or drop the column.
6. **§8.2.1** is silent on post-market hours for early-close days and on USBANK window times (ADR-0003 chooses).
7. **§10.2 J12 "Stylus `programTimeLeft`"** needs the engine address in the address book (`shared.riskEngine`). BE-chain's spike writes `deployments/devnode.engine.json` separately.

## 7. Interfaces changed or published
- **Calendar JSON** (`calibration/out/calendars/<VENUE>-<from>-<to>.json`, `formatVersion 1`): `sessions`, `sessionsAbiEncoded`, `coverageEnd`, `contentHash`. Consumed by BE-chain's `LoadCalendar` / `DeployClockLocal`. **Frozen at v1.**
- **DB:** `ops.keeper_job`, `ops.keeper_tx`, `ops.keeper_instance`, `ops.relayer_report`, `app.*` (§11.2 + `siwe_nonce`). Frozen for S2 (additive changes only).
- **Indexer views** (schema `indexer`): `clock_state`, `clock_transition`, `price_point`. Additive in S2.
- **API routes:** `GET /healthz`, `GET /readyz`, `GET /v1/openapi.json`, `GET /v1/clock/{assetId}`, `POST /v1/auth/siwe/nonce`, `POST /v1/auth/siwe/verify`, `GET /v1/auth/session`, `POST /v1/auth/logout`. v1 routes are stable.
- **Relayer node API** (internal): `GET /v1/observations`, `POST /v1/sign` (bearer token).
- **SDK** `@credence/sdk`: `abis`, `*Abi`, `parseAddressBook`, `normalizeAddressBook`, `loadAddressBook` (`/node`), `reportsDigest`, `reportsTypedData`, `reportsHash`, `encodeReports`, `assetId`, `venueId`, enums and types.
- **EIP-712 vectors:** `packages/sdk/test/vectors/eip712-reports.json` (anyone can cross-check against it).

## 8. Known gaps and TODOs
- The committed real recording is **IEX-only** (the free plan) and covers the 20 minutes around one close. A full Friday → Monday SIP recording (with `Q`/`M` official prints from the listing exchange) needs `ALPACA_FEED=sip` (Algo Trader Plus).
- Free-tier differences seen live: Alpaca's IEX daily open (225.20) differs from Polygon's consolidated official open (225.13) by 0.03%. Production must use SIP on both feeds.
- `smoke` needs a calendar containing a past session. Before 2026-10-01 that means `CALENDAR_FILES` pointing at a generated September calendar (`make calendar-gen FROM=2026-09-01`).
- Vendors are polled over REST (default 2 s). WebSocket streaming (Polygon trades/quotes/LULD, Alpaca trades/quotes/`statuses`) would give sub-second reaction to 0.10% moves; planned for S2 (`services/relayer/src/vendor/{polygon,alpaca}.rs`).
- Relayer node ↔ aggregator uses a bearer token over a private network; mTLS comes with the S5 deploy.
- Keeper: J2–J11 are out of scope. J12 `programTimeLeft` is stubbed (`skipped` rows) until the engine address is in the address book. REOPEN cross-read against the second RPC comes with J5.
- API: `/v1/me/notifications`, markets, positions, pool and auction endpoints are S2/S3. Rate limits are per replica.
- Indexer: only the clock and price feeds (the money contracts arrive in S2/S3).
- `infra/docker-compose.yml` has relayer and keeper service containers (profile `services`) built from `infra/docker/rust-service.Dockerfile`; the indexer and API containers come with S5.

## 9. Needs from the user or the PM
1. **Vendor keys (user): done.** The free keys are in `.env` (git-ignored, mode 600). They were pasted into chat once, so **rotate them** (Massive dashboard → Keys; Alpaca Paper → API Keys → Regenerate) before any shared or long-lived use. For SIP-quality data: Massive Stocks Advanced or Business, and Alpaca Algo Trader Plus (`ALPACA_FEED=sip`).
2. **Licensing (PM):** a Massive Business plan (or Stocks Advanced + a redistribution agreement) and an Alpaca SIP plan with redistribution rights before relayers publish on Arbitrum Sepolia (ADR-0002). Without them, feeds can only run on local chains.
3. **AWS (PM, by S5):** KMS keys (secp256k1 `ECC_SECG_P256K1`) for 3 × 2 relayer nodes, 2 submitters and the keeper, in separate accounts per feed (§10.1). The code path (`*_KMS_KEY_ID`) is implemented; it is untested against real KMS for lack of an account.
4. **RPC (PM, by S5):** two Arbitrum Sepolia provider endpoints (`ARB_SEPOLIA_RPC_URL`, `…_FALLBACK`).

## 10. How to verify from a clean checkout
```bash
make backend-install backend-build backend-test     # Rust + TS + calendar tests
make infra-up db-migrate                            # postgres 17 (:5433) + nitro-devnode (:8547), schemas
make calendar-gen calendar-test                     # 13-month XNYS/USBANK + 17 edge cases
make relayer-e2e                                    # anvil: 2-of-3 accepted; 1-of-3 / wrong domain / stale seq rejected
make keeper-e2e                                     # anvil + postgres: J1 on schedule; failover without duplicates
make local-deploy-clock LOCAL_RPC=http://127.0.0.1:8547   # BE-chain's clock stack on the devnode (once)
make indexer-e2e                                    # devnode → Ponder → GET /v1/clock/NVDA:XNAS
make relayer-dev                                    # optional: live relayer on the devnode (replay vendor)
# with keys in .env (and a calendar with a past session before 2026-10-01: CALENDAR_FILES=...):
make relayer-smoke VENDOR=polygon && make relayer-smoke VENDOR=alpaca
```
