-- migrate:up
-- S2 API: testnet allowlist queue (§10.4 POST /v1/testnet/allowlist → "queues the ops allowlist tx").
-- The API inserts; the keeper's allowlist task (testnet only) sends ComplianceRegistry.setAllowedBatch
-- and records the tx. One row per address: re-attesting is idempotent.
create table app.allowlist_request (
  address      bytea primary key references app.account check (length(address) = 20),
  requested_at timestamptz not null default now(),
  status       text not null default 'pending' check (status in ('pending', 'sent', 'done', 'failed')),
  tx_hash      bytea,
  updated_at   timestamptz not null default now(),
  last_error   text
);
create index allowlist_request_pending on app.allowlist_request (requested_at) where status = 'pending';

-- migrate:down
drop table if exists app.allowlist_request;
