# RPC outage (RpcProviderDown, RpcAllDown)

Each chain has an ordered failover list: the user's two keyed providers (`infra/prod/secrets/rpc.env`: `RPC_<chain>_PRIMARY`, `_SECONDARY`), then the keyless public endpoint. The keeper, the relayer, the solver, the indexer, the API and the notifier all fail over through it by themselves.

1. See every endpoint (the host only, never the URL): `make ops-rpc-check`.
2. **One provider down (RpcProviderDown, ticket):** the services already use the next one. Nothing to do unless it lasts. Check the provider's status page (Alchemy, Chainstack).
3. **Every provider down (RpcAllDown, page):** if the keyless public endpoint is also down, it is probably the chain itself: [sequencer-down.md](sequencer-down.md). Otherwise:
   - replace a dead key: edit `infra/prod/secrets/rpc.env` (keep it 0600), then restart the services that read it:
     ```sh
     docker compose -p credence-testnet -f infra/prod/docker-compose.yml --env-file infra/prod/.env.prod restart \
       keeper-46630 indexer-46630 relayer-a-agg relayer-b-agg relayer-a-node-1 relayer-a-node-2 relayer-a-node-3 \
       relayer-b-node-1 relayer-b-node-2 relayer-b-node-3 api notifier
     ```
     For 421614: `keeper-421614 indexer-421614 solver-421614 navstrike-421614 api notifier`.
   - a provider rate-limits us (HTTP 429 in the logs): move it to SECONDARY and put the other first.
4. **A pruned (non-archive) RPC during a reindex:** the indexer falls back to the head state for pinned reads (`7b3182c`); see [indexer-reindex.md](indexer-reindex.md).
5. Done when `make ops-rpc-check` is OK and RpcAllDown resolves.
