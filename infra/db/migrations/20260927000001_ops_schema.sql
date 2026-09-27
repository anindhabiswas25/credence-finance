-- migrate:up
-- Service tables for the keeper and the relayer (Build Guide §11.3), plus the leader-election
-- heartbeat the keeper needs for §10.2 (two instances, advisory-lock leader, 15 s takeover).
create schema if not exists ops;

create table ops.keeper_job (
  key          text primary key,                 -- idempotency key from §10.2, e.g. "J1:<asset>:<boundary>"
  job          text not null,                    -- J1 … J12
  status       text not null check (status in ('pending', 'running', 'submitted', 'done', 'failed', 'skipped')),
  attempts     int not null default 0,
  next_run_at  timestamptz,
  last_error   text,
  payload      jsonb not null default '{}'::jsonb,
  claimed_by   text,                              -- keeper instance id holding the job while running
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index keeper_job_due on ops.keeper_job (status, next_run_at);

create table ops.keeper_tx (
  hash          bytea primary key,
  job_key       text references ops.keeper_job (key),
  chain_id      bigint not null,
  sender        bytea not null,
  nonce         bigint not null,
  gas_price     numeric,
  status        text not null check (status in ('pending', 'mined', 'reverted', 'replaced', 'dropped')),
  submitted_at  timestamptz not null default now(),
  mined_block   bigint
);
create index keeper_tx_sender_nonce on ops.keeper_tx (chain_id, sender, nonce);

-- Last-seen heartbeat per keeper instance (observability; the lock itself is pg_advisory_lock).
create table ops.keeper_instance (
  instance_id   text primary key,
  is_leader     boolean not null default false,
  heartbeat_at  timestamptz not null default now(),
  started_at    timestamptz not null default now()
);

create table ops.relayer_report (
  feed         text not null,                     -- "A" | "B"
  asset_id     bytea not null,                    -- 32 bytes
  seq          bigint not null,
  kind         smallint not null,                 -- 0 LIVE, 1 OPEN, 2 CLOSE, 3 NAV, 4 STATUS
  price        numeric not null,                  -- WAD per share
  observed_at  timestamptz not null,
  session_date integer not null,
  market_status smallint not null,
  signers      text[] not null,
  tx_hash      bytea,
  status       text not null default 'signed' check (status in ('signed', 'submitted', 'accepted', 'rejected')),
  created_at   timestamptz not null default now(),
  primary key (feed, asset_id, seq)
);
create index relayer_report_pending on ops.relayer_report (feed, status) where status in ('signed', 'submitted');

-- migrate:down
drop schema if exists ops cascade;
