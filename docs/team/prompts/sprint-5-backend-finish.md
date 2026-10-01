# Sprint 5 brief · Engineer B: finish the whole backend and the local ops stack (Amendment 4)

From: PM · Date: 2026-10-01 · Repo: `/home/asus/Project/credence-finance` · Role name on the board: **BE-backend**

This brief **replaces Phase 2 and 3** of `sprint-5-platform.md` (B) and of `sprint-5-ops.md` (C). Their rules, Amendment 1 (two chains) and Amendment 2 (local hosting, in-app notifications) still apply.

## Amendment 4 (user, 2026-10-01 17:10): build everything first, without testing
The user: "first build everything without testing, build the full blockchain part and backend part e2e."
- **Two engineers:**
  - **A (blockchain):** brief `sprint-5-protocol-finish.md`;
  - **you, B: all the backend plus Engineer C's ops items.** C's session is closed and C's unfinished work is yours (below).
- **No new testing in this phase:**
  - Your Phase 2 edge rows (K-02, K-08..K-14, K-16, I-01..03, W-04, N-04..N-06, X-03, X-08, D-01) are dropped.
  - So are C's Phase 2 items (obs-up with every alert firing, the backup/restore recording, the three drills, the deploy/rollback recording) and the promtool unit tests.
  - **Post that list on the board for A to record in `docs/security/pre-mainnet.md`**; they all move to pre-mainnet.
- **Kept as a build check (minutes, not testing):** before each commit `make backend-build backend-lint` passes and the existing `make backend-test` still passes. For the ops files: `docker compose config`, `promtool check rules` (syntax only), and `docker build` of each image. Write no new edge suites.
- Frontend: still the user's (`apps/web/`). Don't touch it or `pnpm-lock.yaml`'s diff from it.

## Where things stand (PM check, 2026-10-01 17:00)
**Uncommitted in the tree (yours now, from B's and C's sessions that stopped at about 17:30–17:50 yesterday):**
- B's in-app inbox: `services/api/src/inbox.ts` (+ test), and changes in `app.ts`, `server.ts`, `stream.ts`, `multichain.ts`, `test/pg.test.ts`;
- the solver's `/healthz` (`services/bidder/src/bin/credence-solver.rs`);
- C's Dockerfiles in `infra/prod/docker/` (7 services + `entrypoint.sh`). There is no compose file, no `.env.prod.example` and no `mk/ops.mk` yet, and `infra/prometheus/alerts-pending.yml` was never written.

Read each file before you continue it. Commit them first, file by file (never `git add -A`).

## Read first
1. `docs/handoff/BOARD.md` from `2026-09-30 16:05` to the end: your interface REQUEST, the PM 16:30 rulings, Amendment 2, your 17:17 webhook contract, C's 17:20 plan, C's 17:30 RPC REQUEST and **C's 17:50 metrics REQUEST**, and the PM entries of 2026-10-01.
2. `docs/team/prompts/sprint-5-ops.md` (Phase 1 + Amendment 2): the ops scope you now own.
3. ADR-0014 (per-chain services), ADR-0122 (A's testnet deploy), Build Guide §10, §16.

## Build items, in order

### 1. Finish what's half-done
- **The in-app channel (Amendment 2):**
  - the inbox table + migration with rollback;
  - `GET /v1/me/inbox` (paged, `?unread=1`) and `POST /v1/me/inbox/read` (SIWE);
  - the `inbox:<owner>` topic on `/v1/stream`, with the OFF-04c session rules;
  - `POST /v1/ops/alerts` (Alertmanager v4 webhook, Bearer secret ≥ 32 bytes) and `GET /v1/ops/alerts` for `OPS_ADMIN_ADDRESSES`, plus the `ops` stream topic, as your 17:17 contract says.
- **The solver's `/healthz` + `/readyz`.** Post its port and env name.

### 2. The keeper metrics from C's 17:50 REQUEST (all per chain)
- `credence_keeper_open_print_deviation_ratio{asset}` (signed) + `credence_keeper_open_print_timestamp_seconds{asset}`;
- `credence_keeper_rpc_up{rpc}` / `credence_keeper_rpc_active{rpc}`, where the label is the host, never the URL;
- `credence_keeper_chain_head_age_seconds`;
- `credence_keeper_nav_print_overdue_seconds{asset}` + `credence_keeper_nav_last_print_timestamp_seconds{asset}`;
- wallet balances refreshed at least hourly;
- `credence_keeper_tips_budget_days{stack}`.

### 3. Small API/service gaps
- **STALE_EXTENDED in the API (PM 16:30 ruling 2):** each market shows why it's paused (MSFT/GOOGL/AMZN out of session), so testers don't read it as a bug.
- **RPC failover lists for the API and the solver** (C's finding 7a): the same ordered-list env as the keeper and indexer.

### 4. From A's address books to running services (`make services-config CHAIN=46630|421614`)
The glue between the deploy and the stack. It reads `deployments/<chainId>.json` (and the dry-run books `31337.{equity,nav}.dryrun.json` until the real ones exist) and writes each service's per-chain env:
- contract addresses and the indexers' start blocks (each contract's deploy block, which A puts in the book);
- the ABI tag A freezes (`v5-testnet`), which the SDK and the bindings pin to;
- the keystore paths per role.

It refuses a book from the wrong chain. **You own the keystore layout** (`KEYSTORE_DIR/<chainId>/<role>.json` + `.password`, 0600): agree the role names with A on the board. A's `make testnet-keys` generates them.

### 5. The local testnet stack (`infra/prod/`, was C's Phase 1; Amendment 2 shape)
- **`docker-compose.yml`** as its own compose project:
  - per chain: the indexer, the keeper, and the relayer. On 46630 that's the feed A and feed B committees (3 nodes + an aggregator each, `VENDOR=redstone`). On 421614 there's no price relayer, only the `nav-strike` timer.
  - the solver bot where the NAV stack needs it;
  - one API, bound to `127.0.0.1` only (:8787);
  - one notifier (`NOTIFIER_CHANNELS=inapp`);
  - Postgres with no host port, plus the nightly `pg_dump` with retention (`infra/backup/`);
  - Prometheus, Alertmanager → your `/v1/ops/alerts` webhook, and Grafana on `127.0.0.1`.
- Private network, `restart: unless-stopped`, secrets from 0600 files, `.env.prod.example`. Host ports away from the dev ones (:5433, :8547, :9090, :3001).
- **Alert rules:** every §16.1 rule with a `chain` label, `severity`, `priority` and `annotations.runbook`, in `infra/prometheus/alerts.yml`, using the item 2 metrics. That includes the ±50 % open-print page, a keeper wallet low per chain, one chain's RPC/indexer down, a NAV print missing, and no page for MSFT/GOOGL/AMZN stale out of session. `promtool check rules` only.
- **The `nav-strike` timer**, once per USBANK session on 421614 (PM 16:30 ruling 3).
- **`mk/ops.mk`:**
  - `ops-secrets-init` (creates `infra/prod/secrets/rpc.env` from the template, chmod 600);
  - `ops-rpc-check` (prints the chain id + head per endpoint, never the URL);
  - `services-deploy` / `services-rollback` (local image tags, migrations first, health gate);
  - `db-backup` / `db-restore`;
  - **`testnet-up` / `testnet-down`:** one command that runs `services-config` for both chains and brings the whole stack up;
  - **`testnet-services-check`:** the steady-state check after the deploy. Feeds publishing on 46630, the indexers caught up on both chains, the keepers healthy and idle, the API answering for both chains, and the first NAV print landed (or TBILL HALTED with a reason until it does). It exits non-zero on any failure. **Build it now; it runs at deploy time.**
- **Railway-ready:** a Dockerfile per service (C's 7, finished), env-only config, a health endpoint each, no host paths. `docs/runbooks/railway.md` is a stub.
- **Runbooks** in `docs/runbooks/`, for local operation with the exact commands per chain: the keeper is down, a stale feed or both feeds disagree, the sequencer is down, HALTED, an RPC outage, a hot wallet is low, the disk is full, a Postgres restore, a key rotation, a manual `keeper enforce` (RB-01), an indexer reindex (with the pruned-RPC fallback), the open-print page, a corporate action (ERC-8056), and the NAV print missing.

### 6. One user REQUEST (merge with A's)
C's 17:30 RPC REQUEST stands: Alchemy + Chainstack, 2 per chain, in `infra/prod/secrets/rpc.env`. Point A's consolidated REQUEST to it, and add anything the stack needs that isn't there yet (e.g. `OPS_ADMIN_ADDRESSES`: the address(es) that can read the ops inbox).

Post a **BUILD READY** when items 1–6 are done and the build checks above pass. Include the dry-run proof that matters: `make testnet-up` against A's two dry-run books on a local anvil reaches `testnet-services-check` green. That is the only end-to-end run in this phase, ≤ 30 min. Use your own compose project name and ports; don't touch the devnode or the dev Postgres.

## Deploy (after A's deploy READY with the real address books)
1. `make ops-rpc-check` (the user's keys in place).
2. `make testnet-up` against `deployments/46630.json` and `421614.json`.
3. `make testnet-services-check` green. The first `nav-strike` lands and TBILL leaves HALTED.
4. A backup runs once.
5. Post the final READY (the API at `http://127.0.0.1:8787` for the user's frontend) and the report `docs/handoff/sprint-5-backend-report.md` (template `REPORT_TEMPLATE.md`), with every dropped test listed as pre-mainnet.

## Acceptance (the PM re-runs these)
1. `make backend-install backend-build backend-lint backend-test` green from a clean clone.
2. `docker compose config`, `promtool check rules` and every image build pass.
3. `make testnet-up` + `make testnet-services-check` green against the dry-run books.
4. After A's deploy, the same two commands are green on 46630 + 421614.
5. The dropped tests are on the board for `pre-mainnet.md`; the report is final.

## Rules
- Charter §2, §2b, §2c. Stage only your paths, file by file. Never `git add -A`, `git add .`, `commit -a`, `stash`, `reset --hard`, `checkout -- .` or `clean`. Never edit A's contracts or deploy scripts; send a REQUEST.
- No run over ~30 min. Heavy builds with `nice -n 19` while A has a run live.
- Never print or commit a key, password, token or RPC URL with a key.
- Post a board entry at every READY, blocker, finding or REQUEST. When the PM or the user must decide, ask on the board and carry on.
