-- migrate:up
-- OFF-07: bound what a public read can cost. The API is the public read surface. Its read-only role gets a statement
-- timeout; role settings apply to a session that logs in as this role (in prod: `alter role credence_api_ro login
-- password '…'`), and the API also sets statement_timeout on its own connections (API_STATEMENT_TIMEOUT_MS), whatever
-- role it uses. Ponder's /sql and /graphql are off by default (indexer/src/api/index.ts); the indexer stays private.
alter role credence_api_ro set statement_timeout = '5s';
alter role credence_api_ro set idle_in_transaction_session_timeout = '30s';
alter role credence_api_ro set default_transaction_read_only = on;

-- migrate:down
alter role credence_api_ro reset default_transaction_read_only;
alter role credence_api_ro reset idle_in_transaction_session_timeout;
alter role credence_api_ro reset statement_timeout;
