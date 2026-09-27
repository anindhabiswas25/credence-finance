# Sprint 2 brief · Senior Backend Engineer (BE-backend)

From: PM · Repo: `/home/asus/Project/credence-finance` · Target: local only. **No testnet deploy.**

## Context

Sprint 1 is **accepted**. Read `docs/handoff/sprint-1-pm-review.md` for the verification results and the ruling on each of your spec issues. The guide is **v1.1** (changelog, R-23..R-26). The charter changed:
- `calibration/**` moves to the new **Quant engineer (QE)**. Your calendar generator stays as it is, and its format is frozen at v1.
- New shared-machine rules in §2a.

**Security:** the free vendor keys were pasted into chat. **Tell the user in your first message to rotate them**, and don't use the old ones after rotation.

## Read first
1. `docs/team/TEAM_CHARTER.md` (§2, §2a).
2. `docs/handoff/sprint-1-pm-review.md`.
3. `docs/CREDENCE_BUILD_GUIDE.md` v1.1: changelog, §2, §4.4, §8.4–8.5 (market/vault behaviour you index and serve), §10.1–10.5, §11, §12, §16.
4. `docs/handoff/BOARD.md`. BE-chain posts `READY` entries for ABIs v1, `risk-wasm`, `credence-bindings`, `DeployCoreLocal` and the unified address book.

## Sprint goal
Serve and operate the lending core: index markets, positions and the vault; expose them through the API with exact Bell quotes; run the keeper jobs that do not need the pool or the auction house; build the notifier; and settle the market-data licensing question with evidence.

## Work items

### A. Starts immediately
1. **R-26 licensing spike.** Evaluate feeds already licensed for on-chain publication that could serve Credence's testnet (and mainnet secondary). Candidates: Pyth equity feeds, RedStone equity feeds, and Chainlink tokenized-equity feeds / Data Streams. Check each on Arbitrum Sepolia for:
   - ticker coverage (NVDA, AAPL, TSLA, COIN, MSFT, SPY);
   - market-hours and status semantics, and whether a **regular-session opening print** is available with a verifiable timestamp;
   - update model (push or pull), latency, cost, and terms.

   Also price the paid vendor plans with redistribution rights. Deliver an ADR with a recommendation and a cost table. Prototype an off-chain reader for the top candidate (no contract changes; if a contract adapter is needed, post a REQUEST to BE-chain).
2. **Notifier** (`services/notifier`, §10.5): a `notification_job` queue consumer (`FOR UPDATE SKIP LOCKED`) with Resend email, VAPID web push and Telegram adapters. It needs dedupe keys, retries, dead-letter handling and `notification_log`. It also needs templates with **exact amounts** for the Bell heads-up and for auto-cover or pre-close outcomes, following the copy rules in §10.7 (R-18). Test it with provider sandboxes or mocks at the HTTP boundary.
3. **Relayer upgrades:** WebSocket streaming for both vendors (trades, quotes, LULD/status), with REST as the fallback, and sub-second reaction to the 0.10% move rule.

### B. After the BE-chain READYs (ABIs v1, bindings, risk-wasm, DeployCoreLocal)
4. **Indexer:** `market`, `position`, `position_event`, `vault_state`, `vault_request`, `sigma_point`, plus `price_point.status` from the v1 `marketStatus`. Handlers are pure projections (§10.3).
5. **API** (§10.4):
   - `GET /v1/markets` and `/v1/markets/:marketId`, including the safe LTV for the next closure.
   - `GET /v1/positions/:owner`.
   - `GET /v1/positions/:marketId/:owner/bell`: exact cures and a live premium quote computed with **risk-wasm** against current chain state. It must equal the on-chain `bellStatus` / `quoteCover` (test it).
   - `GET /v1/vault/:stack`, and `GET/PUT /v1/me/notifications` (SIWE).
   - `POST /v1/testnet/allowlist` (rate-limited; it queues the ops allowlist tx).
   - A WebSocket `/v1/stream` with the `clock` and `prices` channels.
6. **Keeper** (switch to `credence-bindings`):
   - **J2 Bell heads-up**: 26 h and 2 h before a *binding* close, compute `bellStatus` for every position with risk-core natively and enqueue notifications.
   - **J3 enforceBell** and **J4 health watcher** in **dry-run mode** (they compute and log the exact calls and their expected outcomes, but don't send) until the S3 pool and auction house exist. A flag flips them to live.
   - **J7 σ update**: implement QE's σ methodology exactly (QE publishes a spec with test vectors), collect 2-of-3 committee signatures, and submit to `SigmaOracle`.
   - **J8** `claimFees` + `SeniorVault.processQueue`.
   - **J12** Stylus `programTimeLeft` from the unified address book.
7. **SDK:** add the v1 ABIs, the risk-wasm wrapper, and typed helpers for the market and vault.

### C. Operability
8. Grafana dashboards as code (`infra/grafana/`): relayer, keeper jobs, API latency, and indexer lag. Prometheus alert rules (`infra/prometheus/alerts.yml`) for the §16.1 alerts that are measurable today (feed stale, disagreement, keeper leader missing, wallet low, calendar coverage, Stylus activation).

## Out of scope
Pool, epoch and auction indexing and endpoints; keeper J5, J6, J9–J11 (S3); the NAV test issuer (S4); the web app (the Frontend engineer, S3); testnet deploy (S5).

## Acceptance criteria
1. `make backend-install backend-build backend-test` passes from a clean clone. The e2e targets pass with `make infra-up db-migrate`.
2. The licensing ADR recommends an option, with a cost table and a prototype reader run against Arbitrum Sepolia (or a documented reason it can't run).
3. The notifier delivers the Bell heads-up for the scenario A borrowers with the exact Appendix A amounts (G-10, G-11), through at least email and push, in an e2e test.
4. The API `/bell` quote equals the on-chain `bellStatus` / `quoteCover` for 100 random positions on the devnode.
5. Keeper e2e on the devnode with `DeployCoreLocal`: J2 enqueues correct notifications; J3/J4 dry-run logs match what `risk-cli` predicts; J7 submits σ that the engine accepts (and a too-fast drop is rejected); J8 runs; failover still holds.
6. The indexer and API serve markets, positions and the vault from a local scenario-A run (Monday to Friday Bell).
7. The dashboards and alert rules load in a local Grafana/Prometheus (`make obs-up`).
8. The report is at `docs/handoff/sprint-2-backend-report.md`, with ADRs for every deviation.

## Rules
The charter applies in full. Use `CARGO_TARGET_DIR=target/be`. Never edit `contracts/`, `crates/risk-*`, `stylus/` or `calibration/`; use board REQUESTs. When done, tell the user: "Sprint 2 backend done. Report: docs/handoff/sprint-2-backend-report.md".
