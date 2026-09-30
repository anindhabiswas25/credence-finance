-- migrate:up
-- ADR-0014: one API and one notifier serve both chains. Accounts, preferences, sessions and email are per
-- address and chain-agnostic. The two chain-bound app tables get a chain id (existing rows: the devnode's):
-- - allowlist_request: one ComplianceRegistry per chain; a self-attestation queues one row per served chain,
--   and each chain's keeper sends only its own (`chain_id = ops.chain()`).
-- - notification_job: the notifier scans each chain's indexer views; a dedupe key is unique per chain, so the
--   same event key on two chains is two messages, and a replay on one chain is still one. Account-level jobs
--   (email verification) carry chain 0. Every writer sets it (no default): the keeper `ops.chain()`, the
--   notifier and the API their chain.
alter table app.allowlist_request add column chain_id bigint;
update app.allowlist_request set chain_id = 412346;
alter table app.allowlist_request alter column chain_id set not null,
  drop constraint allowlist_request_pkey, add primary key (chain_id, address);
drop index app.allowlist_request_pending;
create index allowlist_request_pending on app.allowlist_request (chain_id, requested_at) where status = 'pending';

alter table app.notification_job add column chain_id bigint;
update app.notification_job set chain_id = 412346;
alter table app.notification_job alter column chain_id set not null,
  drop constraint notification_job_dedupe_key_key, add constraint notification_job_dedupe unique (chain_id, dedupe_key);

-- migrate:down
-- Refuses (unique violation) if two chains share an address or a dedupe key; a rollback is for one chain.
alter table app.notification_job drop constraint notification_job_dedupe,
  add constraint notification_job_dedupe_key_key unique (dedupe_key);
alter table app.notification_job drop column chain_id;

drop index app.allowlist_request_pending;
alter table app.allowlist_request drop constraint allowlist_request_pkey, add primary key (address);
alter table app.allowlist_request drop column chain_id;
create index allowlist_request_pending on app.allowlist_request (requested_at) where status = 'pending';
