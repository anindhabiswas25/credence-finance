-- migrate:up
-- Amendment 2 (S5): notifications are in-app by default. The notifier's `inapp` channel writes every user event to
-- app.inbox (one row per chain, address and dedupe key, so a replayed job never writes twice); the API serves it
-- (GET /v1/me/inbox, POST /v1/me/inbox/read) and pushes new rows on /v1/stream (`inbox:<owner>`). Ops alerts arrive
-- as Alertmanager's webhook (POST /v1/ops/alerts) into ops.alert, one row per (fingerprint, startsAt).
create table app.inbox (
  id          bigserial primary key,
  chain_id    bigint not null,                    -- 0: account-level (e.g. email verification)
  address     bytea not null check (length(address) = 20),
  event       text not null,
  dedupe_key  text not null,
  subject     text not null,
  body        text not null,
  url         text,
  payload     jsonb not null,
  created_at  timestamptz not null default now(),
  read_at     timestamptz,
  unique (chain_id, address, dedupe_key)
);
create index inbox_by_address on app.inbox (address, id desc);
create index inbox_unread on app.inbox (address, id desc) where read_at is null;

create table ops.alert (
  id           bigserial primary key,
  fingerprint  text not null,
  starts_at    timestamptz not null,
  status       text not null check (status in ('firing', 'resolved')),
  alertname    text not null,
  chain_id     bigint,                            -- the alert's `chain` label, if any
  severity     text,
  summary      text,
  runbook      text,
  labels       jsonb not null,
  annotations  jsonb not null,
  ends_at      timestamptz,
  received_at  timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (fingerprint, starts_at)
);
create index alert_recent on ops.alert (status, id desc);

-- live push: the API's stream hubs LISTEN and read the new rows
create function app.inbox_notify() returns trigger language plpgsql as $$
begin
  perform pg_notify('inbox', new.id::text);
  return null;
end $$;
create trigger inbox_notify after insert on app.inbox for each row execute function app.inbox_notify();
create function ops.alert_notify() returns trigger language plpgsql as $$
begin
  perform pg_notify('ops_alert', new.id::text);
  return null;
end $$;
create trigger alert_notify after insert or update on ops.alert for each row execute function ops.alert_notify();

grant select on app.inbox to credence_api_ro;

-- migrate:down
drop trigger if exists alert_notify on ops.alert;
drop function if exists ops.alert_notify();
drop trigger if exists inbox_notify on app.inbox;
drop function if exists app.inbox_notify();
drop table if exists ops.alert;
drop table if exists app.inbox;
