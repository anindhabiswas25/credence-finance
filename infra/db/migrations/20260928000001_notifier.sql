-- migrate:up
-- Notifier queue mechanics (Build Guide §10.5, ADR-0010): additive to the §11.2 tables.
--  * status: pending → sending → sent | retry → … | dead (dead-letter) | expired (a heads-up past its deadline)
--    | skipped (the account has no deliverable channel for this event)
--  * delivered_channels / failed_channels make retries per channel: a retry never re-sends a channel that
--    already went out, and a permanently failed channel (bad address, 410 Gone) is not retried.
--  * locked_at/locked_by: a worker that died mid-send leaves the job in `sending`; it is reclaimed after
--    NOTIFIER_LOCK_TIMEOUT_S. Providers get an idempotency key per (dedupe_key, channel), so a reclaimed
--    job does not double-send on providers that honour it (Resend).
alter table app.notification_job
  add column delivered_channels text[] not null default '{}',
  add column failed_channels    text[] not null default '{}',
  add column locked_at          timestamptz,
  add column locked_by          text,
  add column created_at         timestamptz not null default now(),
  add column updated_at         timestamptz not null default now(),
  add constraint notification_job_status_chk
    check (status in ('pending', 'sending', 'retry', 'sent', 'dead', 'expired', 'skipped'));

create index notification_job_due on app.notification_job (run_at, id) where status in ('pending', 'retry');
create index notification_job_sending on app.notification_job (locked_at) where status = 'sending';

alter table app.notification_log
  add column attempt    int,
  add column created_at timestamptz not null default now();
create index notification_log_job on app.notification_log (job_id);

-- Email verification (the notifier only emails verified addresses; the verification mail itself is the
-- exception). The API stores sha256(token); the raw token only travels in the email link.
create table app.email_verification (
  token_hash bytea primary key,
  address    bytea not null references app.account,
  email      text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

grant select on app.email_verification to credence_api_ro;

-- Wake the notifier as soon as a producer (keeper J2, indexer triggers, API) inserts a job.
create function app.notify_notification_job() returns trigger language plpgsql as $$
begin
  perform pg_notify('notification_job', new.id::text);
  return null;
end $$;
create trigger notification_job_inserted after insert on app.notification_job
  for each row execute function app.notify_notification_job();

-- migrate:down
drop trigger if exists notification_job_inserted on app.notification_job;
drop function if exists app.notify_notification_job();
drop table if exists app.email_verification;
drop index if exists app.notification_log_job;
alter table app.notification_log drop column if exists attempt, drop column if exists created_at;
drop index if exists app.notification_job_sending;
drop index if exists app.notification_job_due;
alter table app.notification_job
  drop constraint if exists notification_job_status_chk,
  drop column if exists delivered_channels,
  drop column if exists failed_channels,
  drop column if exists locked_at,
  drop column if exists locked_by,
  drop column if exists created_at,
  drop column if exists updated_at;
