# Indexer down, lagging, or a reindex (IndexerDown, IndexerLag)

Each chain has its own Ponder indexer (`indexer-46630`, `indexer-421614`), its tables in schema `indexer_<id>` and the API's views in `ix_<id>`. Its query API stays on the private network (OFF-07).

1. State: `make testnet-ps | grep indexer`, `make testnet-logs SVC=indexer-46630`. Ready means caught up: `docker compose -p credence-testnet -f infra/prod/docker-compose.yml exec indexer-46630 curl -s 127.0.0.1:42069/ready`.
2. **Down / crash-looping on an RPC error:** see [rpc-outage.md](rpc-outage.md). On a Postgres error: [disk-full.md](disk-full.md).
3. **Lagging:** usually the RPC's rate limit. It catches up by itself; check the provider in `make ops-rpc-check`.
4. **A reindex** (bad rows, a new book or ABI): drop the chain's indexer schemas and restart; Ponder re-syncs from the book's start block (`START_BLOCK` in `infra/prod/generated/<id>/chain.env`).
   ```sh
   make db-backup
   DC="docker compose -p credence-testnet -f infra/prod/docker-compose.yml --env-file infra/prod/.env.prod"
   $DC stop indexer-46630
   $DC exec -T postgres psql -U credence -d credence -c 'drop schema if exists indexer_46630 cascade; drop schema if exists ix_46630 cascade;'
   $DC up -d indexer-46630
   ```
   The API and the keeper read `ix_46630`: they answer "not indexed yet" for that chain until the views are back (minutes on testnet).
5. **The pruned-RPC fallback:** free testnet RPCs are not archive nodes. A read pinned to an old event's block fails with `missing trie node`; the indexer then reads the latest state instead (`7b3182c`, logged as a pinned-read fallback). That is expected during a reindex. Values derived that way are current, not historical; they converge as new events arrive.
6. Done when `/ready` answers 200 and `make testnet-services-check` is green.
