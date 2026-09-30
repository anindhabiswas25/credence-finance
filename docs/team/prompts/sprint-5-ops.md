# Sprint 5 · Engineer C (DevOps / SRE) brief

From: PM · Date: 2026-09-30 15:30 IST · Repo: `/home/asus/Project/credence-finance` · Paths: charter §2c.

**Why you're here:** Engineer B (backend) has 1.5 times Engineer A's remaining work. You take the whole production-operations part of B's item D, so B can keep to the services. The scope is the same as `sprint-5-platform.md` items D and Amendment 1 point 7. Only the owner changes. Read that brief too: it is the source for these items.

**Two chains (Amendment 1):** the equity stack is on Robinhood Chain testnet (46630) and the NAV stack is on Arbitrum Sepolia (421614). Each chain has its own keeper, relayer (3 nodes + aggregator) and indexer. One API and one notifier serve both chains, keyed by chain id (ADR-0014). Every alert and dashboard carries a `chain` label, and every runbook command names the chain.

## Phase 1: build (post a Phase 1 READY when done)
1. **`infra/prod/`: the host-agnostic production stack on one Linux host.** Docker compose (or equivalent) with:
   - Postgres; the indexer ×2, the keeper ×2, the relayer 3 nodes + aggregator ×2 (one set per chain); the API; the notifier; Prometheus, Alertmanager and Grafana.
   - Versioned images, restart policies, resource limits sized for a free host (e.g. Oracle Cloud Always Free, 4 OCPU / 24 GB ARM: build multi-arch images).
   - A private network: only the API is public (TLS, e.g. Caddy with an automatic certificate for the API domain). Postgres, the indexer, `/metrics`, and the relayer and keeper ports stay private.
   - Secrets from files readable only by the service user (the keystore password files, the RPC keys, the Telegram token), never in the compose file or git. Provide an `.env.prod.example`.
2. **OFF-07, infra side:** the indexer's `/sql` and `/graphql` only on the private network, and a read-only Postgres role with `statement_timeout` for the indexer views. The migration for the role is B's path: send B a REQUEST with the SQL. **OFF-08, infra side:** scrape the metrics on the private listener that B's code will expose. Agree the port on the board.
3. **Alerts to Telegram:** Alertmanager → a Telegram receiver (free bot), routes by severity and `chain`. Every §16.1 alert rule exists with a `chain` label and a promtool unit test (`promtool test rules`). Includes:
   - **The open-print sanity check** (threat-model row 4, PM ruling): each REOPEN open print vs the previous official close, above ±50 % pages the guardian, with an edge test at exactly ±50 %. If the metric it needs doesn't exist, REQUEST it from B (name, labels).
   - A keeper hot wallet low on ETH per chain, and one chain's RPC or indexer down while the other is healthy.
4. **Deploy and rollback:** `make services-deploy` / `make services-rollback` in `mk/ops.mk` (versioned image tags, migrate up, health gate, and roll back to the previous tag plus a migration rollback), and `.github/workflows/deploy-services.yml` as a manual `workflow_dispatch` (no push to any remote).
5. **Backup and restore:** a nightly `pg_dump` with retention in `infra/backup/`, and `make db-backup` / `make db-restore`.
6. **Runbooks in `docs/runbooks/`** (§16), each with the exact commands per chain: the keeper is down, a feed is stale or both feeds disagree, the sequencer is down, HALTED, an RPC outage / failover, a hot wallet is low, the disk is full, Postgres restore, a key rotation (per chain), a manual `keeper enforce` (RB-01), an indexer reindex (including the pruned-RPC fallback, B's `7b3182c`), the open-print page, and a corporate action (the ERC-8056 multiplier).
7. **The user's inputs:** post one board REQUEST that lists exactly what the real deploy needs: a host (with a spec and a free default), the API domain / DNS record, free RPC keys per chain (at least 2 providers each, for failover), and a Telegram bot token and chat id. This replaces the host / domain / Telegram part of B's REQUEST: tell B on the board.

## Phase 2: test (starts when all Phase 1 READYs are on the board; each run ≤ 30 min)
- `make obs-up` with **every §16.1 alert firing once into Telegram** (a test bot is fine) against a live keeper on the devnode (post a DECISION before you use the devnode; A and B hold it at times).
- `infra/prod` brought up locally against the devnode with both chains simulated (two books) to steady state.
- **A Postgres backup and restore, done once and recorded.** **Three runbook drills recorded:** a keeper kill, the primary RPC down, and an indexer reindex.
- `make services-deploy` then `make services-rollback`, done once locally and recorded.
- Post a Phase 2 READY with the recordings (`docs/runbooks/drills/`).

## Phase 3: deploy (when both chains' address books are posted by A and the user's inputs are in)
- With B: the fork rehearsal of the full stack against both fork books, then the real deploy on the host, alerts reaching Telegram, a backup running. Post the final READY and a short report `docs/handoff/sprint-5-ops-report.md` (template `docs/handoff/REPORT_TEMPLATE.md`).

## Rules
- Charter §2, §2b, §2c. Stage only your own paths, file by file. Never `git add -A`, `git add .`, `commit -a`, `stash`, `reset --hard`, `checkout -- .` or `clean`. `pnpm-lock.yaml` and `apps/` are the user's.
- Never edit B's service code or migrations, or A's contracts; send a REQUEST on the board.
- No run longer than ~30 min. The machine is shared by three engineers (16 threads, 15 GB): run heavy builds with `nice -n 19`, and don't stop or reset the devnode or the compose `postgres` (:5433) others use. Use your own compose project name for `infra/prod` tests (`-p credence-prod-test`) and different host ports.
- Never print or commit a key, token or RPC key.
- Post a board entry at every READY, blocker, finding, REQUEST. When the PM or user must decide, ask on the board and go on.
