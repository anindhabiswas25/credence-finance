-- migrate:up
-- Application tables for the API and the notifier (Build Guide §11.2), verbatim plus not-null
-- defaults. Drizzle in services/api mirrors these; dbmate owns the DDL (ADR-0001).
create schema if not exists app;

create table app.account (
  address             bytea primary key check (length(address) = 20),
  created_at          timestamptz not null default now(),
  email               text,
  email_verified_at   timestamptz,
  telegram_chat_id    text,
  testnet_attested_at timestamptz
);

create table app.push_subscription (
  id         bigserial primary key,
  address    bytea references app.account,
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz default now()
);

create table app.notification_pref (
  address bytea references app.account,
  event   text not null,
  channel text not null,
  enabled boolean not null,
  primary key (address, event, channel)
);

create table app.notification_job (
  id         bigserial primary key,
  dedupe_key text unique not null,
  address    bytea not null,
  event      text not null,
  payload    jsonb not null,
  run_at     timestamptz not null default now(),
  attempts   int not null default 0,
  status     text not null default 'pending',
  last_error text
);
create index on app.notification_job (status, run_at);

create table app.notification_log (
  id          bigserial primary key,
  job_id      bigint references app.notification_job,
  channel     text,
  sent_at     timestamptz,
  provider_id text,
  ok          boolean,
  error       text
);

create table app.siwe_session (
  id         uuid primary key,
  address    bytea not null,
  nonce      text not null,
  expires_at timestamptz not null
);

-- SIWE nonces issued but not yet consumed (single use, short TTL).
create table app.siwe_nonce (
  nonce      text primary key,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

-- migrate:down
drop schema if exists app cascade;
