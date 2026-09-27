# ADR-0001 · One migration tool for the repo: dbmate

Status: accepted · Role: BE-backend · Date: 2026-09-27 · Sprint 1 item 3

## Context
The Build Guide names Drizzle for the API's `app` tables (§6.4, §11.2) and sqlx for the Rust services (§6.3), but the `ops` schema (§11.3) is shared by the keeper (Rust) and the relayer (Rust), and the `app` schema by the API and the notifier (TypeScript). The brief asks for one tool for the whole repo.

## Decision
- **dbmate**, which uses plain SQL `-- migrate:up` / `-- migrate:down` files in `infra/db/migrations/`. It runs from its official container (`ghcr.io/amacneil/dbmate:2`) via `make db-migrate`, so no local install is needed.
- Drizzle and sqlx are used only as query layers. Neither generates or applies DDL.
- Rust tests apply the same files to a scratch database (`credence_common::db::scratch_database`), so tests and production share one DDL source.
- The Ponder indexer manages its own tables (`ponder start --schema …`). The API reads them through the `indexer` views schema (`--views-schema indexer`) and never writes there.

## Consequences
- Migrations are reviewable SQL in one directory, and both languages see identical schemas.
- Additions beyond the guide: `app.siwe_nonce` (single-use SIWE nonces); `ops.keeper_instance` (leader heartbeat, `backend_pid` for fencing); in `ops.keeper_job`: `payload`, `claimed_by`, `created_at`; in `ops.keeper_tx`: `chain_id`, `sender`; in `ops.relayer_report`: `session_date`, `market_status`, `status`, `created_at`; and a read-only role `credence_api_ro`. Every column from the guide is kept.
- Local Postgres listens on host port **5433** (`POSTGRES_PORT`), because 5432 is taken on the development machine. Inside compose it is 5432.
