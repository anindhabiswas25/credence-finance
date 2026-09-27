-- migrate:up
-- Read-only role for the API over the indexer schema and app tables (§10.4: "Ponder's tables (read-only role)").
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'credence_api_ro') then
    create role credence_api_ro nologin;
  end if;
end $$;
grant usage on schema app to credence_api_ro;
grant select on all tables in schema app to credence_api_ro;
alter default privileges in schema app grant select on tables to credence_api_ro;

-- migrate:down
revoke all on all tables in schema app from credence_api_ro;
revoke usage on schema app from credence_api_ro;
drop role if exists credence_api_ro;
