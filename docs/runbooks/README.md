# Runbooks: the local testnet stack

Owner: BE-backend (was DevOps). The stack runs on this machine (Amendment 2): `infra/prod`, compose project `credence-testnet`. Chains: **46630** Robinhood Chain testnet (equity stack) and **421614** Arbitrum Sepolia (NAV stack). Alerts arrive in the API's ops inbox (`GET /v1/ops/alerts` for `OPS_ADMIN_ADDRESSES`, and the `ops` stream topic), each with a `chain` label and a `runbook` annotation that names one of these files. Grafana is on http://127.0.0.1:13001, Prometheus on :19090 and Alertmanager on :19093.

| Alert / situation | Runbook |
| --- | --- |
| KeeperDown, KeeperLeaderMissing, KeeperPaged, ServiceDown | [keeper-down.md](keeper-down.md) |
| FeedStale, FeedDisagreement(Severe), RelayerNodeDown (RB-04) | [feed-stale.md](feed-stale.md) |
| ChainHeadStale (RB-06) | [sequencer-down.md](sequencer-down.md) |
| An asset HALTED, ShortfallEscalated, PoolUtilisation (RB-03, RB-12) | [halted.md](halted.md) |
| RpcProviderDown, RpcAllDown | [rpc-outage.md](rpc-outage.md) |
| KeeperWalletLow, WalletLow, WalletBelowFloor, TipsBudgetLow | [wallet-low.md](wallet-low.md) |
| The disk is full | [disk-full.md](disk-full.md) |
| Restore Postgres from a backup | [postgres-restore.md](postgres-restore.md) |
| Rotate a service key (RB-11) | [key-rotation.md](key-rotation.md) |
| BellNotEnforced, ReopenStuck, EpochNotSettled (RB-01, RB-02) | [keeper-enforce.md](keeper-enforce.md) |
| IndexerDown, IndexerLag, a reindex | [indexer-reindex.md](indexer-reindex.md) |
| OpenPrintDeviation (±50 %, RB-05) | [open-print.md](open-print.md) |
| A corporate action (ERC-8056, RB-07) | [corporate-action.md](corporate-action.md) |
| NavPrintMissing | [nav-print-missing.md](nav-print-missing.md) |
| Hosting on Railway (stub) | [railway.md](railway.md) |

## Conventions used below
Run everything from the repo root. A command for one chain names it: replace `46630` with `421614` for the NAV stack.

```sh
make testnet-ps                         # every container and its health
make testnet-logs SVC=keeper-46630      # follow one service's log
make testnet-services-check             # the whole steady state, exits non-zero on a failure
BOOK=infra/prod/generated/46630/book.json; jq -r .shared.clock $BOOK   # a contract address
set -a; . infra/prod/secrets/rpc.env; set +a; RPC=$RPC_46630_PRIMARY    # an RPC for cast; never echo it
KS=~/.credence/keys/46630               # the service keystores (role.json + role.password)
```

A `cast send` as a service role signs with its keystore and never prints the key:
`cast send --rpc-url $RPC --keystore $KS/keeper.json --password-file $KS/keeper.password <to> '<sig>' <args>`.
