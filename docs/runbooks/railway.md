# Railway (stub, after the testnet: Amendment 2 step 4)

Not deployed now. Every service is already Railway-ready: one Dockerfile each (`infra/prod/docker/`), config from env only, a health endpoint, no host paths or host networking. On Railway every secret is a variable (the `FILE__<NAME>` and `RPC_ENV_FILE` indirections of `entrypoint.sh` are simply unused).

| Service | Dockerfile | Health | Per-chain instances | Key env |
| --- | --- | --- | --- | --- |
| api | `api.Dockerfile` | `/healthz`, `/readyz` on 8787 | one | `DATABASE_URL`, `API_CHAINS`, `RPC_URL_<id>` (list), `ASSETS_<id>`, `SESSION_SECRET`, `OPS_ALERT_WEBHOOK_SECRET`, `OPS_ADMIN_ADDRESSES`, `CORS_ORIGINS`, `SIWE_DOMAIN` |
| notifier | `notifier.Dockerfile` | `/healthz`, `/readyz` on 9103 | one | `DATABASE_URL`, `NOTIFIER_CHAINS`, `DEPLOYMENTS_FILE_<id>`, `INDEXER_SCHEMA_<id>`, `NOTIFIER_CHANNELS=inapp` |
| indexer | `indexer.Dockerfile` | `/health`, `/ready` on 42069 | one per chain | `PONDER_CHAIN_ID`, `PONDER_RPC_URL_<id>`, `DATABASE_SCHEMA`, `VIEWS_SCHEMA`, `DEPLOYMENTS_FILE` |
| keeper | `keeper.Dockerfile` | `/healthz`, `/readyz` on `METRICS_ADDR` | one per chain | `CHAIN_ID`, `RPC_URL`, `RPC_URL_FALLBACK`, `DATABASE_URL`, `DEPLOYMENTS_FILE`, `KEEPER_ASSETS`, `KEEPER_KMS_KEY_ID` or a keystore |
| relayer node ×3, aggregator | `relayer.Dockerfile` | `/healthz`, `/readyz` on `METRICS_ADDR` | per committee (46630: A, B) | `FEED_ID`, `FEED_ADDRESS`, `ASSETS`, `VENDOR=redstone`, `RELAYER_NODE_TOKEN`, `RELAYER_NODE_URLS` (aggregator) |
| solver | `solver.Dockerfile` | `/healthz`, `/readyz` on `SOLVER_OPS_ADDR` | 421614 | `SOLVER_CONFIG`, `RPC_URL`, `SOLVER_MAIN_KMS_KEY_ID` or a keystore |
| nav-strike | `relayer.Dockerfile` (a Railway cron: `credence-relayer nav-strike --publish`) | — | 421614 | `NAV_SIGNER_<n>_*`, `NAV_SUBMITTER_*`, `ISSUER_*` |

Open questions for then: keys in a KMS instead of keystore files (`<PREFIX>_KMS_KEY_ID`), Postgres as a Railway database with its own backups, and Prometheus / Alertmanager (or Railway's metrics) pointing at the API's ops inbox.
