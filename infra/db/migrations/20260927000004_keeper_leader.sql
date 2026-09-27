-- migrate:up
-- Leader election (§10.2): the leader holds a session-level pg advisory lock on a dedicated connection and
-- heartbeats through that same connection. `backend_pid` lets a follower fence a hung leader (heartbeat
-- older than 15 s) with pg_terminate_backend, which releases the lock.
alter table ops.keeper_instance add column backend_pid int;
alter table ops.keeper_instance add column chain_id bigint;

-- migrate:down
alter table ops.keeper_instance drop column if exists chain_id;
alter table ops.keeper_instance drop column if exists backend_pid;
