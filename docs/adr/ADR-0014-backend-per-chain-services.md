# ADR-0014 (BE-backend): one set of chain-bound services per chain, one API and one notifier

- Status: accepted (BE-backend, S5 Amendment 1, 2026-09-30)
- Context: PM Amendment 1. The equity stack goes to Robinhood Chain testnet (46630) and the NAV stack to Arbitrum
  Sepolia (421614). Until now every service assumed one `CHAIN_ID`.

## Decision

1. **Chain-bound processes run once per chain**, each configured only by env: `CHAIN_ID`, `RPC_URL` +
   `RPC_URL_FALLBACK` (≥ 2 RPCs per chain in prod), `DEPLOYMENTS_FILE` (`deployments/46630.json`,
   `deployments/421614.json`; the local devnode keeps `deployments/412346.local.json`).
   - **Keeper**: one per chain (its leader lock is already per chain, `leader::lock_key(chain_id)`).
   - **Relayer**: the equity committee (3 nodes + aggregator, feeds A/B, RedStone) on 46630. 421614 has only the NAV
     feed, whose print is the issuer's NAV strike, so it runs no equity relayer.
   - **Indexer**: one Ponder process per chain, with its own schema `indexer_<chainId>` and views schema
     `ix_<chainId>`. Reindexing one chain drops and rebuilds only that chain's two schemas.
2. **One Postgres** (one server, one database). Chain-bound state is keyed by chain id:
   - `ops.keeper_job` gets a `chain_id` column, and its primary key becomes `(chain_id, key)`. Every keeper
     query filters on its own chain. Without this, a keeper's start-of-tick `reconcile_submitted` would pick up the
     other chain's `submitted` jobs, find no receipt on its own chain, mark them failed, and let the other keeper
     send them again. `ops.keeper_tx` already has `chain_id`.
   - `ops.relayer_report` gets `chain_id` (it's keyed by feed address today, which can repeat across chains).
   - The indexer tables are separated by schema (point 1). The notifier's dedupe keys are prefixed `<chainId>:`.
3. **One API**, chain-scoped by a **query parameter** `?chain=<chainId>` on every chain-bound route (markets,
   positions, auctions, settlements, pools, clock, risk, the WS `subscribe` message). The API serves the chains
   listed in `API_CHAINS=46630:ix_46630,421614:ix_421614` (chain id → views schema). With one chain configured,
   `chain` is optional and defaults to it (the local devnode flow and today's tests are unchanged). With several,
   a missing or unknown `chain` is a 400 naming the served chains. Every chain-bound body carries `chainId`. The
   same wallet can have positions on both chains; `/v1/positions?owner=…&chain=…` never mixes them. SIWE accepts a
   signature for any served chain id.
   - *Why a query parameter rather than a `/v1/{chain}/…` prefix:* one OpenAPI route set; existing single-chain
     clients and tests keep working; CDN cache keys include the query anyway. The prefix was the alternative.
4. **One notifier**. It scans each chain's views schema and carries `chainId`, the market's **loan token symbol and
   decimals** (from the address book: tUSDG on 46630, USDC on 421614), and the chain name in every payload and
   template. Nothing hard-codes "USDC".
5. **Keys per chain and role.** The signer abstraction takes `(chainId, role)`. The free default is an encrypted
   keystore at `KEYSTORE_DIR/<chainId>/<role>.json`, unlocked from a password file readable only by the service
   user. A KMS backend is optional, behind the same interface.
6. **Metrics and alerts** carry a `chain` label (a Prometheus target label per chain-bound process), and runbooks
   name the chain in every command.

## Consequences

- One DB migration (`chain_id` on `ops.keeper_job` and `ops.relayer_report`, default `412346` for existing rows).
- The keeper's job queries all take the chain id; existing single-chain tests pass unchanged.
- The prod stack (`infra/prod/`) has two env files, one per chain, and runs the chain-bound services twice.
