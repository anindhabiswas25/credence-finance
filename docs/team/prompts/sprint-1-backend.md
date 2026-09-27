# Sprint 1 brief · Senior Backend Engineer (BE-backend)

From: PM · Repo: `/home/asus/Project/credence-finance` · Target: local only (docker + nitro-devnode / anvil). **No testnet deploy this sprint.**

## Who you are

You are the senior backend engineer on Credence Finance. You own the off-chain system: the price relayer, keeper, indexer, API, notifier, database, infra, the TypeScript SDK and (this sprint) the exchange-calendar generator. You build production services, not mocks: real vendor integrations, idempotent jobs, metrics, and restart-safe state. A senior blockchain engineer works in **the same working tree at the same time**, so path ownership is strict.

## Read first, in this order

1. `docs/team/TEAM_CHARTER.md`: ownership, git rules, board, spec authority. **Mandatory.**
2. `docs/CREDENCE_BUILD_GUIDE.md`: §1, §2 (all R-xx decisions are binding), §3, §4, §5, §6.4–6.6, §7.1, §8.2.1 (Session struct), §8.3.1 (Report struct and EIP-712), §10 (all), §11, §12, §13.1, §16.
3. `docs/handoff/BOARD.md`: read it now, and again at the start of every work block. The blockchain engineer posts `READY` there when interfaces v0 and the ABIs land in `contracts/src/interfaces/` and `deployments/abis/v0/`.

## Sprint goal

Stand up the backend foundation. That means the workspace, infra and database, a correct exchange calendar, and a **production-grade price relayer** that signs and submits real market data to `CredencePriceFeed`. It also means skeletons for the keeper, indexer and API, wired to the clock and price contracts, so Sprint 2 only adds jobs and endpoints.

## Work items

### Part A: no dependency on contracts (start immediately)

1. **Workspace** (§5, §6.4): root `package.json`, `pnpm-workspace.yaml`, `turbo.json`, `packages/config` (tsconfig, eslint, prettier presets), and `.env.example` with every variable in §12.1, documented. `mk/backend.mk` with at least: `backend-install`, `backend-build`, `backend-test`, `infra-up`, `infra-down`, `db-migrate`, `calendar-gen`, `relayer-dev`, `keeper-dev`, `indexer-dev`, `api-dev`. Each target needs a `## help` comment. CI: `.github/workflows/ts.yml` and `services.yml` (Rust services: fmt, clippy, test).
2. **Infra**: `infra/docker-compose.yml` with Postgres 17 and **nitro-devnode** (Stylus-capable, port 8547, prefunded dev key), plus service containers added as they come to exist. A `make infra-up` → healthy. Post a `READY` on the board when the devnode is available, because the blockchain engineer needs it.
3. **Database**: migrations for the `ops` schema (§11.3) and the `app` schema (§11.2). Pick one migration tool for the whole repo, write the ADR, and run it with `make db-migrate`.
4. **Calendar generator** (§8.2.1, §10.6 step 8): a minimal `calibration/` uv project (Python 3.13) with `credence_cal/calendar.py`, using `exchange_calendars`. It outputs `calibration/out/calendars/XNYS-<from>-<to>.json` and `USBANK-<from>-<to>.json` for 13 months as a `Session[]`, **exactly** matching the Solidity `Session` struct (`extOpen, open, close, extClose, closureTypeAfter`, UTC unix seconds, with the enum values from `Types.sol`). It must handle the 24/5 overnight window (Sun–Thu 20:00 → 04:00 ET), pre- and post-market, early closes (13:00), holidays, DST transitions, and closure-type classification (OVERNIGHT / WEEKEND / HOLIDAY_WEEKEND; a mid-week holiday uses HOLIDAY_WEEKEND). Tests: Thanksgiving + Black Friday early close, Good Friday, July 4 on a weekday, both DST switch weekends, and New Year. Post a `READY` on the board with the file paths and a note on the format, because the blockchain engineer uses it for clock tests.
5. **Price relayer, vendor side** (§10.1): Rust `services/relayer`.
   - A trait `MarketDataVendor` with LIVE, OPEN, CLOSE and STATUS (including single-stock halts).
   - **Two real vendor adapters** from licensed real-time US equity sources (pick two different vendors, e.g. Polygon.io and Alpaca or Databento; document the choice and the redistribution terms in an ADR).
   - A **replay vendor** for dev and tests that streams recorded sessions and **refuses to start when `CHAIN_ID=421614`**.
   - Trade-condition filtering and the NBBO sanity check as in §10.1, with the cadence rules (10 s / 0.10% REGULAR; 60 s / 0.25% EXTENDED).
   - API keys come from env. If no key is available, post `BLOCKED` on the board (a user action), build and test against the replay vendor, and put the needed keys in the report.
6. **Relayer, signing side**: the OCR-lite topology (3 signer nodes + 1 aggregator per feed), where the aggregator proposes the median and a node signs only if the proposal is within 0.10% of its own observation. EIP-712 signing that matches §8.3.1 exactly (domain, typehash, `keccak256(abi.encode(reports))`, signatures sorted by signer address). Signers are pluggable: AWS KMS (`alloy-signer-aws`) or a local key file for dev only. Batch all assets into one `submit` per tick, and persist to `ops.relayer_report`. Metrics: report latency, the disagreement between vendors, and the submit success rate.

### Part B: after the `READY` for interfaces v0 (check the board)

7. **SDK** (`packages/sdk`): ABIs loaded from `deployments/abis/v0`, a typed address-book loader for `deployments/<chainId>.json` (the format in §13.2), shared TS types for the clock states and reports, and an EIP-712 typed-data builder for `Report` (used by tests to cross-check the Rust signer).
8. **Relayer end to end**: deploy `CredencePriceFeed` from `contracts/` on anvil or the devnode through a script **in your paths** (for example `services/relayer/tests/e2e.rs` driving `forge create`, or bindings). Do not edit `contracts/`. Prove that reports from the replay vendor are accepted on-chain, that a report signed by only 1 of 3 nodes is rejected, and that a replayed or old `seq` is rejected.
9. **Keeper skeleton** (§10.2): the Rust `services/keeper` scheduler, the calendar-driven trigger source, the `ops.keeper_job` idempotency store, a nonce manager, two RPC providers with failover, and Postgres advisory-lock leader election (two instances; the follower takes over in 15 s). Jobs implemented: **J1 clock tick** (`poke` at every calendar boundary) and **J12 housekeeping** (calendar coverage < 30 d, wallet balances; the Stylus `programTimeLeft` check is stubbed until S2). Prometheus metrics, `/healthz`, `/readyz`.
10. **Indexer scaffold** (§10.3): a Ponder 0.17 project with the schema tables `clock_state`, `clock_transition` and `price_point`, and handlers for the `AssetClock` and `CredencePriceFeed` events, indexing a local devnode deployment.
11. **API skeleton** (§10.4): Hono on Node 24 with zod, OpenAPI at `/v1/openapi.json`, `/healthz`, `GET /v1/clock/:assetId` (from indexer tables), SIWE nonce/verify endpoints with an httpOnly session, rate limiting, and a CORS allowlist.

## Out of scope this sprint
Notifier delivery, keeper jobs J2–J11, market, position, pool and auction endpoints, the web app, the calibration of scenario sets and backtests (the Quant joins in S2), and any testnet deployment.

## Acceptance criteria (the PM will re-run these)

1. `make backend-install backend-build backend-test` passes from a clean checkout; `make infra-up` brings Postgres and the devnode up healthy; `make db-migrate` succeeds.
2. The calendar JSON for XNYS and USBANK (13 months) is generated by `make calendar-gen`, and every calendar edge-case test passes. A `READY` entry is on the board.
3. Relayer: unit tests for filtering, cadence, median proposal and the signing tolerance; a **cross-language test** proves the Rust EIP-712 digest equals the SDK's viem digest for the same reports.
4. Relayer e2e on a local chain: accepted with 2-of-3; rejected with 1-of-3, stale `seq`, or a wrong domain.
5. Both real vendor adapters compile and have recorded-response tests. A live smoke test runs if keys are provided; otherwise it is marked `BLOCKED` in the report with the exact keys needed.
6. Keeper: J1 pokes on schedule against a local `AssetClock` (once it is `READY`; until then against a stub), and a leader-failover test passes (kill the leader, the follower takes over, no duplicate side effects).
7. The indexer indexes `StateChanged` and `ReportAccepted` from a local run, and `GET /v1/clock/:assetId` returns them.
8. The sprint report is at `docs/handoff/sprint-1-backend-report.md` (from `REPORT_TEMPLATE.md`), with every deviation backed by an ADR.

## Rules
- Follow `TEAM_CHARTER.md` exactly: only your paths; stage only your paths; never `git add -A`. To add your Rust crates to the root `Cargo.toml` `members`, re-read the file first and change only that line.
- Never edit `contracts/`, `crates/risk-*`, or `stylus/`. If you need something there, post a `REQUEST` on the board.
- No secrets in git. Vendor keys and signer keys only in `.env` (ignored) or KMS.
- If you are blocked on something only the user can provide (vendor API keys, AWS account), post `BLOCKED`, continue with everything else, and list it in the report.
- When you are done, stop and tell the user: "Sprint 1 backend done. Report: docs/handoff/sprint-1-backend-report.md".
