-- migrate:up
-- ADR-0014 (S5 Amendment 1): one keeper and one relayer per chain share one Postgres. Chain-bound ops rows are
-- keyed by chain id. Every service connection carries its chain in the `credence.chain_id` setting
-- (`credence_common::db::connect_chain`), and `ops.chain()` reads it. A connection without it fails on the first
-- insert or filter (no silent default): a keeper can never pick up another chain's `submitted` jobs.
create function ops.chain() returns bigint
  language sql stable
  as $$ select current_setting('credence.chain_id')::bigint $$;

-- keeper_job: (chain_id, key). Existing rows are the local devnode's.
alter table ops.keeper_job add column chain_id bigint;
update ops.keeper_job set chain_id = 412346;
alter table ops.keeper_job alter column chain_id set not null, alter column chain_id set default ops.chain();
alter table ops.keeper_tx drop constraint keeper_tx_job_key_fkey;
alter table ops.keeper_job drop constraint keeper_job_pkey, add primary key (chain_id, key);
alter table ops.keeper_tx alter column chain_id set default ops.chain(),
  add constraint keeper_tx_job_key_fkey foreign key (chain_id, job_key) references ops.keeper_job (chain_id, key);
drop index ops.keeper_job_due;
create index keeper_job_due on ops.keeper_job (chain_id, status, next_run_at);

-- relayer_report: feed labels ("A", "B", "NAV") repeat across chains.
alter table ops.relayer_report add column chain_id bigint;
update ops.relayer_report set chain_id = 412346;
alter table ops.relayer_report alter column chain_id set not null, alter column chain_id set default ops.chain();
alter table ops.relayer_report drop constraint relayer_report_pkey, add primary key (chain_id, feed, asset_id, seq);
drop index ops.relayer_report_pending;
create index relayer_report_pending on ops.relayer_report (chain_id, feed, status) where status in ('signed', 'submitted');

-- migrate:down
-- Refuses (primary key violation) if two chains share a key; a rollback is for a single-chain database.
drop index ops.relayer_report_pending;
alter table ops.relayer_report drop constraint relayer_report_pkey, add primary key (feed, asset_id, seq);
alter table ops.relayer_report drop column chain_id;
create index relayer_report_pending on ops.relayer_report (feed, status) where status in ('signed', 'submitted');

drop index ops.keeper_job_due;
alter table ops.keeper_tx drop constraint keeper_tx_job_key_fkey, alter column chain_id drop default;
alter table ops.keeper_job drop constraint keeper_job_pkey, add primary key (key);
alter table ops.keeper_job drop column chain_id;
alter table ops.keeper_tx add constraint keeper_tx_job_key_fkey foreign key (job_key) references ops.keeper_job (key);
create index keeper_job_due on ops.keeper_job (status, next_run_at);

drop function ops.chain();
