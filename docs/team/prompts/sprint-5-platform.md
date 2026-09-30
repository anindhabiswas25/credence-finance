# Sprint 5 brief · Engineer B: Platform (BE-backend, also covering DevOps / SRE)

From: PM · Date: 2026-09-30 · Repo: `/home/asus/Project/credence-finance` · Target: **finish S4, then the whole off-chain side up to the Arbitrum Sepolia testnet (M9): services, edge suite, production deploy, monitoring and runbooks. No frontend (user, 2026-09-30).**

## Context

The user now runs **two engineers at a time** for all the work before testnet: you (**Engineer B**, role name on the board **BE-backend**) and **Engineer A** (role name **BE-chain**, brief `docs/team/prompts/sprint-5-protocol.md`: contracts, risk data, contract-side edge cases, the testnet contract deploy). DevOps / SRE is not staffed, so **the S5 DevOps work is yours** (charter §2b). The Frontend is out of scope.

Where S4 stopped (PM check, 2026-09-30 05:15 IST):
- S3 is accepted (scenario A passed at real time, 583 keeper txs, 0 reverted).
- Your S4 report `docs/handoff/sprint-4-backend-report.md` is committed. Item G (`make nav-settlement-e2e`) is carried over, and it waits for Engineer A's item E READY with the new main book.
- `e9db352` fixed `keeper-core-e2e` on the real pool. **`services/keeper/tests/edge_restart.rs` is uncommitted**: check it, finish it, and commit it first.
- QA-sec's 18:55 REQUEST lists the off-chain edge rows that are still missing (below, item B). QA-sec is not staffed now, so you close them yourself and write each test's name in its row of `docs/qa/edge-cases.md` §2 (you may edit only the off-chain rows of §2).
- **`apps/web/` and the `pnpm-lock.yaml` diff are the user's own UI work. Do not touch, stage, install over or delete them.** If a `pnpm install` of yours would rewrite the lock file, post on the board first.

The user's standing rules (do not argue them):
- **Free data and free tools only.** No paid plan as a default. Where a paid service would be normal (KMS, hosting), build the free option and list the paid one as an option.
- **No long test runs now (user, 2026-09-30).** Nothing over ~30 min of wall time per run. Prove behaviour with **edge-case tests**: unit tests, anvil time warps, synthetic calendars with short sessions, and killed or restarted processes. The ≈ 65-h run and the soaks are pre-mainnet.
- **The deep audit is pre-mainnet** (`docs/security/pre-mainnet.md`).

## Read first
1. `docs/team/TEAM_CHARTER.md` §2, **§2a, §2b (new: two engineers)**.
2. `docs/handoff/BOARD.md` from `2026-09-29 18:30` to the end, especially the PM DECISION of 2026-09-30.
3. `docs/qa/edge-cases.md` §2, `docs/security/offchain-review.md`, `docs/security/threat-model.md` row 4, `docs/security/pre-mainnet.md`.
4. `docs/CREDENCE_BUILD_GUIDE.md`: §10 (every service), §11 (API), **§16** (ops, alerts, runbooks), §4 (keys and roles), ADR-0009 (RedStone, D1), **§17.2 M9**, §18.

## Work items, in order

### A. Close S4
1. Commit `edge_restart.rs`.
2. **`BellEnforced.outcome = 5` (`SALE_TOO_LATE`, ADR-0115):** map it in the indexer and in the notifier's enum (`services/notifier/src/templates.ts`) as a "too late for a pre-close sale" alert, with a test. Keep the J3 guard (no pre-close candidates after `close − 5 min`).
3. **Item G, `make nav-settlement-e2e`, after Engineer A's READY with the new book.** PM ruling: **seed the NAV positions close to LT** so that 1–2 NAV strikes cross HF < 1, on a synthetic USBANK calendar with short sessions. The run must finish in **≤ 30 min**. It must cover: J10 opens the settlement, the solver fills it; a second borrower with the solver in its no-bid profile, so the pool's fallback advance runs; the issuer's T+1 `fulfillRedeem`, then J10's claim; and indexer / API / notifier == chain.
4. Commit your S4 report final, and post S4 READY.

### B. The off-chain edge-case suite (`make backend-edge`, ≤ 30 min in total)
Close every row in QA-sec's 18:55 REQUEST, each with a test that really triggers the case:
- **Keeper:** K-02 kill and restart between **every step** of J3, J5, J9, J10 and J11, with no step mined twice and none skipped; K-05 RPC error mid-batch; K-06 a position repaid between the pre-check and the tx; K-07 a Bell with 0 and with 35+ positions, and no pre-close candidate in a J3 batch after `close − 5 min`; K-08 tranches; K-09 no bids, no reveals, partial reveals; K-10 capacity exhausted, cash shortage, GDA unsold at the next closure; K-11 `RedemptionsGated` retry, a voided solver, holiday T+1; K-12/K-13 sequencer gap and HALTED on the jobs' own deadlines (not only the gauge); K-14 calendar coverage running out.
- **Indexer:** I-01 a restart and a full reindex give identical tables; I-02 an anvil reorg; I-03 several contracts' events in one block.
- **API/WS:** W-04 WS disconnect and reconnect, session expiry.
- **Notifier:** N-04 an explicit dead-letter assertion; N-05 a duplicate event gives one message.
- **Infra:** D-01 Postgres restarted mid-cycle.
- **New for testnet:** RPC failover (the primary RPC down, then back; two RPCs that disagree on the head); a keeper hot wallet low on ETH (alert, and it keeps working until empty); a clock skew between a relayer node and the chain; the relayer on RedStone with a stale package, a package from an unknown signer, and a missing asset.
Post a READY listing each row and its test.

### C. S5 service features
- **Threat-model row 4 (PM ruling):** the open-print sanity check. Each REOPEN open print vs the previous official close; above ± 50 %, page the guardian. It is a Prometheus rule or a keeper check, with a promtool or unit test, and an edge test at exactly 50 %.
- **Relayer on RedStone for the public testnet** (ADR-0009, D1 accepted): OPEN/CLOSE from the first/last RedStone package, flagged `OracleFirstRegular`. The free vendor keys (Alpaca/Polygon) are a **monitoring shadow only** on a public deployment; they never publish on-chain there (R-26). The testnet asset set is **NVDA, AAPL, TSLA, MSFT, GOOGL, AMZN** (PM default for ADR-0009 D2); use it from config.
- **The off-chain findings that matter once the stack is public**, even though the rest of Low/Info is pre-mainnet: OFF-07 (the indexer's `/sql` and `/graphql` only on the private network, and a `statement_timeout` role), OFF-08 (metrics on a private listener), OFF-04c (drop `bell:<owner>` on logout). OFF-06 and OFF-11 stay pre-mainnet.
- **The testnet allowlist endpoint** `POST /v1/testnet/allowlist` (§8.12, rate-limited), if it isn't built yet. The web app is out of scope, but the endpoint is part of the API.

### D. DevOps / SRE (was the DevOps role; S5)
- **Production stack, host-agnostic:** `infra/prod/` with a docker compose (or equivalent) that runs Postgres, the indexer, the API, the notifier, the keeper, the 3 relayer nodes plus the aggregator, Prometheus, Alertmanager and Grafana on **one Linux host**, with only the API/WS behind TLS on the public side. Everything else is on a private network.
- **Keys:** a signer abstraction. The free default is an encrypted keystore per key (the keeper hot wallet, the 3 relayer node keys, the ops issuer), unlocked at start from a file readable only by the service user. An AWS/GCP KMS backend is optional, behind the same interface, and not required for testnet. Separate keys per role. Never print a key, never commit one.
- **RPC failover:** at least 2 free Arbitrum Sepolia RPCs (the public endpoint plus a free-tier provider), with health checks and switching. B covers it with an edge test.
- **Alerts go somewhere:** Alertmanager to Telegram (free). Every §16.1 alert fires once in a test, against a real Prometheus: `make obs-up` against a live keeper on the devnode (open since S4).
- **Deploy and roll back:** `make services-deploy` (or a manual `workflow_dispatch` workflow), versioned images, DB migrations with a rollback path, and a backup and restore of Postgres **tested once**.
- **Runbooks** in `docs/runbooks/` (§16): the keeper is down, a feed is stale or both feeds disagree, the sequencer is down, HALTED, a RPC outage, a hot wallet is low, the disk is full, Postgres restore, a key rotation, and a manual `keeper enforce` (RB-01). Each has the exact command. **Drill three of them** on the devnode stack and record the result.
- **Rehearse the whole off-chain deploy** on a local host against Engineer A's Arbitrum Sepolia **fork** address book. The stack must reach its steady state: feeds publishing, the keeper idle and healthy, the indexer caught up, the API matching the chain.
- **The real testnet deploy needs the user:** a host (the PM default is a free one, for example Oracle Cloud Always Free; the user decides), a domain or subdomain for the API, the free RPC keys, and a Telegram bot token. Post a board REQUEST with the exact list as soon as D starts. Deploy only after the user provides them and Engineer A posts READY with `deployments/421614.json`. Then run the post-deploy checks, and hand over with a READY.

## Amendment 1 (PM, 2026-09-30): two chains. The equity stack goes on Robinhood Chain; the NAV stack stays on Arbitrum

**Decision:** the **equity stack deploys to Robinhood Chain testnet (chain id 46630, RPC `https://rpc.testnet.chain.robinhood.com`)**. The **NAV stack deploys to Arbitrum Sepolia (421614)**. Engineer A owns the contract side (brief `sprint-5-protocol.md`, Amendment 1). The off-chain stack must now run **one set of chain-bound services per chain**.

Changes to your items (the rest of the brief stands):
1. **Per-chain services:** a keeper, relayer committee and aggregator, and indexer for each chain, driven by config (`CHAIN_ID`, RPC list, address book `deployments/46630.json` or `deployments/421614.json`). Equity feeds (feed A/B, the RedStone relayer) run on 46630. The NAV feed and the J10 jobs run on 421614. **One API and one notifier** serve both chains, with the chain id in every route, table key and message (`/v1/markets?chain=…` or a path prefix; pick one and write an ADR). DB tables are keyed by chain id. Keep the local devnode flow working as it is.
2. **Keys:** separate keeper and relayer node keys per chain. The signer abstraction takes a chain id.
3. **RPC failover per chain:** at least 2 RPCs for 46630 (the public RPC plus a free-tier provider, if one offers Robinhood Chain testnet: check Alchemy, QuickNode, Chainstack) and 2 for 421614.
4. **Loan token naming:** the equity stack lends **tUSDG** (USDG on Robinhood Chain), and the NAV stack lends USDC. The API, notifier templates and SDK must use each market's own loan token symbol, never a hard-coded "USDC".
5. **Multiplier (ERC-8056):** Engineer A adds a per-token multiplier (token price = share price × multiplier) and a `CORP_ACTION` pause for large updates. The relayer publishes **per-share** prices as today. The indexer and API must show the collateral value per token, with the multiplier, and the notifier must send a corporate-action alert. Edge tests: split, reverse split, and a dividend update on an open position, all shown correctly in the API. Wait for A's READY with the new ABI first.
6. **Edge suite additions:** one chain's RPC down while the other chain's services keep working; the same wallet address with positions on both chains (the API keeps them apart); the indexer reindexing one chain without touching the other chain's tables.
7. **D, deploy:** the fork rehearsal runs the stack against **both** fork address books at once and reaches steady state on both. Alerts and dashboards carry a `chain` label. Runbooks name the chain in each command.
8. **User REQUEST, amend your list:** RPC keys for both chains. The host must be able to run both service sets (roughly double the chain-bound processes; one Postgres).

Time: about +1 day.

## Order of work (PM, 2026-09-30, from the user; it overrides the item order above)

Work in **three phases**, in this order. Don't start a phase until your part of the one before is done and posted as a READY on the board.

**Phase 1: build everything that's left.** Finish all the remaining code in your items, including Amendment 1. Write the unit tests with the code as usual (the normal suites stay green). No testnet deploys.

**Phase 2: edge-case testing.** When **both** engineers have posted their Phase 1 READY, run the full edge-case suites against the finished code and fix what they find. Every row of `docs/qa/edge-cases.md` must name a passing test. Each run ≤ 30 min. Post a Phase 2 READY with the results.

**Phase 3: deploy to testnet.** When both Phase 2 READYs are on the board and the user's inputs are in (keys, test ETH on both chains, Safe owners, host, RPC keys):
1. rehearse on forks of both chains;
2. deploy the **equity stack to Robinhood Chain testnet (46630)** and the **NAV stack to Arbitrum Sepolia (421614)**;
3. verify the contracts, bring up the services on both chains, run the post-deploy checks;
4. post the final READY and report.

Your items by phase:
- **Phase 1:** A (S4 close; G as soon as it can run), C (open-print page, RedStone relayer, OFF-04c/07/08, allowlist endpoint), Amendment 1 (per-chain services, keys, RPC failover, loan-token symbols, multiplier values and the corporate-action alert), D's **build work**: the `infra/prod/` stack, the signer abstraction, alert routing, the deploy/rollback tooling, the runbooks written.
- **Phase 2:** item B, the whole `backend-edge` suite (including Amendment 1's cross-chain rows), `make obs-up` with every alert firing, the Postgres backup and restore, the three runbook drills.
- **Phase 3:** the fork rehearsal against both books, then the real services deploy on the host for both chains, and the post-deploy checks.

## Acceptance (the PM re-runs each item from a clean clone)
1. S4 closed: `outcome = 5` mapped; `make nav-settlement-e2e` passes in ≤ 30 min on the new book; the S4 report final.
2. `make backend-install backend-build backend-test backend-lint backend-edge` green from a clean clone, `backend-edge` ≤ 30 min, and every off-chain row of `docs/qa/edge-cases.md` §2 names its passing test.
3. The open-print ± 50 % page, the RedStone testnet relayer, OFF-04c/07/08, and the allowlist endpoint are done, each with tests.
4. The off-chain stack reaches steady state on the fork rehearsal. Every §16.1 alert has fired once into Telegram. A Postgres backup/restore and three runbook drills are recorded.
5. **Once the user has provided the host and keys:** the services run against the Arbitrum Sepolia contracts, feeds publish, the keeper and indexer are healthy, and the API matches the chain.
6. Final report `docs/handoff/sprint-5-platform-report.md` (template `docs/handoff/REPORT_TEMPLATE.md`) and a final READY.

## Rules
- Charter §2 and §2b. Stage only your paths. Never `git add -A`, `git stash`, `git reset --hard` or `git clean`.
- `CARGO_TARGET_DIR=target/be`. The devnode is shared: post a DECISION before you hold it, and a READY when you release it. Engineer A has the devnode first for item E.
- No run longer than ~30 min. If a devnode run gets near that, use `setsid nohup` inside `systemd-inhibit`, with an `ABORTED` line if it dies.
- Post a board entry at every READY, blocker, or finding. When the PM or the user must decide something, ask on the board and go on with the next item.

## Amendment 2 (PM, 2026-09-30 17:20, from the user): in-app notifications
The board entry "17:20 · PM · DECISION" is the spec. It adds the **in-app channel** to your Phase 2 build: the notifier's `inapp` channel writes to an inbox table; `GET /v1/me/inbox`, `POST /v1/me/inbox/read`; the `inbox:<owner>` stream topic; the ops-alert webhook `POST /v1/ops/alerts` and `GET /v1/ops/alerts` for `OPS_ADMIN_ADDRESSES`; a migration with rollback, tests, and edge row N-06. In-app is the default; email / push / Telegram stay in the code and are off by default. Do it before your remaining edge rows, because Engineer C's alert routing depends on the webhook.
