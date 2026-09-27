# ADR-0105 · BE-chain · One local address book per chain

Status: Accepted · Date: 2026-09-28 · Owner: BE-chain (charter §2a)

## Context

S1 wrote two local files: `deployments/<chainId>.local.json` (flat keys, clock stack) and
`deployments/devnode.engine.json` (the Stylus engine). The charter (§2a) now requires one file per chain, with
`shared.riskEngine` in it.

## Decision

1. **One file:** `deployments/<chainId>.local.json` (git-ignored). Every local deploy writes to it:
   `make devnode-deploy-engine` (Stylus), `make local-deploy-clock`, and `make local-deploy-core` (S2).
   `devnode.engine.json` is retired; the engine deploy deletes a leftover one.
2. **Shape = Build Guide §13.2**, which `@credence/sdk`'s `AddressBookSchema` already parses:
   ```json
   { "chainId": 412346, "startBlock": 329, "release": "local",
     "shared": { "calendar", "clock", "oracle", "feedA", "feedB", "feedNav", "riskEngine", "sigmaOracle",
                 "sequencerHealth", "timelock", "guardian", "registry", "faucet" },
     "equity": { "market", "vault", "reserve", "treasury", "tips", "markets": { "NVDA": "0x<marketId>", … } },
     "nav":    { "market", "vault", "reserve", "treasury", "tips", "markets": { "TBILL": "0x<marketId>" } },
     "tokens": { "tNVDA": "0x…", "tTBILL": "0x…", "usdc": "0x…" },
     "assetIds": { "NVDA": "0x…", "TBILL": "0x…" },
     "stylus": { "riskEngine": { "address", "deploymentTx", "compressedSizeBytes", "toolchain", "wasmSha256" } } }
   ```
   `registry` and `faucet` are extra `shared` keys (the SDK schema strips unknown keys, so this is compatible).
3. **Deprecated flat keys.** For S2 only, the S1 flat keys (`clock`, `calendar`, `feedA`, `feedB`, `navFeed`,
   `oracle`, `sequencerHealth`, `registry`, `faucet`, `t<TICKER>`, `usdc`, `assetId_<TICKER>`) are written as well,
   after a `"_deprecated"` marker, so existing scripts (for example `indexer/scripts/e2e.sh`) keep working. They are
   removed in S3; readers should move to `shared.*`, `tokens.*` and `assetIds.*`.
4. **Engine carry-over.** A deploy rewrites the whole file. It keeps `shared.riskEngine` and `stylus.riskEngine`
   from the existing file only if that address still has code on the chain, so a reset devnode drops a stale engine.
   The engine deploy (`stylus/risk-engine/scripts/deploy.sh`, jq) lifts a flat S1 book into the §13.2 shape before
   adding the engine, so `shared` is never partial.
5. **Readers.** `stylus/risk-engine-diff` reads `.shared.riskEngine` from `deployments/<chainId>.local.json`
   (`--book` / `--engine` override). Solidity scripts use `contracts/script/utils/LocalBook.sol`.
6. **Deploy order on the devnode:** `make devnode-deploy-engine` then `make local-deploy-core`. Anvil has no Stylus;
   there `local-deploy-core` uses a Solidity `MockRiskEngine` (`ENGINE=mock`), recorded as `shared.riskEngine`.
