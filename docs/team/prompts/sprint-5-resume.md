# Sprint 5 resume · PM checkpoint (2026-09-30 14:30 IST)

From: PM. Both S5 sessions stopped at about 07:48 IST. The last commit is `af9ba21` (07:29). The machine was rebooted at about 13:45, so the devnode is down and no engineer process is running. This note records where each engineer stopped. The briefs (`sprint-5-{protocol,platform}.md`, including Amendment 1 and "Order of work") are still the scope and the acceptance. Nothing in them changes. **We are still in Phase 1. Neither Phase 1 READY is posted.**

## Engineer A (BE-chain + QE + QA-sec): about 70 % of Phase 1

| Item | State |
| --- | --- |
| A: S4 item E, the new main book | ✅ READY 06:15 (`412346.local.json`, devnode-integration 29/29) |
| B: QA-11 `SeniorVault.disable` | ✅ `26c8a67` |
| B: ERC-8056 multiplier + E-K-01..06, ABIs v4 | ✅ `95dfc8a`, `eed6c52` (359 passed) |
| C: GOOGL/AMZN + TBILL bundles | ✅ `cb15c51` (loaded on a dedicated engine; **the main book's engine is still on S2 + fixture**) |
| Robinhood Stock Token (TokenProbe, alias RHTSLA), Chainlink RH source (mainnet only) | ✅ `18986ca`, `9c0e8da`, `b8f31ed` (ADR-0120, ADR-0121) |
| Stylus on 46630 | 🟡 read-only half done (ArbOS 61, stylusVersion 3, `cargo stylus check` ok). Live deploy + call **waits for the user to fund `0x242d…9287` with ≈ 0.01 ETH on 46630** |
| **ADR-0114 (J3 bracket)** | 🟡 **measured, reverted in the tree, uncommitted, no ADR.** `devnode-gas` 07:45: `enforceBell` 12 = 21.2M, 16 = 27.5M, 20+ estimate 0 (over the limit); **J3 batch = 13 within 24M** (S4 was 10). The brief's rule was "keep only if ≥ 20", so reverting is correct. The tree removes `beginBellBatch`/`endBellBatch`, `PoolLib.quoteBatch`, the `PackedInt` helpers, and `BellBatch.t.sol` (staged delete). It compiles. **Open:** ADR-0114 is not written; ABIs v4 still export the two hooks (`abis-check` will flag the removal); `forge test` not re-run; J3's batch size stays 10 or goes to 12 in BE-backend's keeper (A says which) |
| D: deploy scripts (Phase 1: anvil dry-run only) | 🟡 **uncommitted**: `contracts/script/testnet/` (DeployTestnet, FinalizeTestnet, PostDeployCheck, TestnetBase, DryRunPrograms, ListingParamsEngine, `deploy.sh`, `env.sh`, `postdeploy_check.sh`, `config/{46630,421614}.json`), `contracts/src/testnet/TestStablecoin.sol` (tUSDG), `TestAssets.t.sol` +55, `deployments/.gitignore`. Anvil dry-runs produced `deployments/31337.{equity,nav}.dryrun.json` at 07:44–07:46, but **no board entry says they passed** |
| Main book on the new bundles | ❌ waiting for B's "devnode done" (below) |
| S4 blockchain report final | ❌ |

## Engineer B (BE-backend + DevOps): about 25 % of Phase 1

| Item | State |
| --- | --- |
| A.1 K-02, A.2 outcome 5 + J3 QA-10 guard | ✅ `ff1cdb2`, `0173e89` |
| B keeper part: RPC read failover, nonce recovery, K-05/06/07 | ✅ `48e0665`, `7981c15` |
| **A.3 G `nav-settlement-e2e`** | ❌ **FAILED 07:36** (`target/be/nav-settlement/check.log`: "timed out waiting for J10 opened a settlement for Nia"). **Root cause:** Ponder's pinned reads hit state the nitro devnode had already pruned (it keeps about 128 blocks), so the indexer never built `indexer_nav_e2e.position`, and J10's query failed every 10 s. **Fix in progress, uncommitted:** `indexer/src/pinned.ts` (+ test) falls back to the latest state; `indexer/src/core.ts` uses it. The same fix is **needed on testnet** (free RPCs are not archive nodes). Also uncommitted: the `nav-settlement-e2e` target in `mk/backend.mk`, `services/api/scripts/nav/{run.sh,seed.ts,check.ts}` and `strike.ts` changes |
| ADR-0014 per-chain services | 🟡 written, uncommitted |
| C: open-print ± 50 % page | ❌ not found |
| C: RedStone testnet relayer | 🟡 vendor + tests exist from S3/S4; the testnet wiring isn't confirmed |
| C: OFF-04c / OFF-07 / OFF-08, allowlist endpoint | ❌ OFF-07/08 still open in `pre-mainnet.md`; the allowlist queue exists in the API (check it covers the brief) |
| Amendment 1: per-chain keeper/relayer/indexer, API + notifier keyed by chain id, per-chain keys/RPCs, loan-token symbols, multiplier values, corporate-action alert | ❌ only the ADR |
| D build: `infra/prod/`, signer abstraction, Telegram alert routing, deploy/rollback tooling, runbooks | ❌ none of these exist yet (`infra/` has devnode/docker/grafana/prometheus only) |
| Edge rows still **gap** (for Phase 2, list only) | K-02 (J10), K-08..K-14, K-16, I-01..03, W-04, N-04, N-05, D-01 |

## Blocking the user (needed before Phase 3; ask now so it's ready)
1. ≈ 0.01 ETH on 46630 to `0x242d4FC0A2558bc25DD8A0c2545013D5781E9287` (the Stylus live check; Phase 1).
2. A deployer keystore (account name only), with test ETH on 46630 and on 421614 (≥ 0.5 each).
3. Safe owner addresses (Gov 3-of-5, Guardian 2-of-4, Ops/Issuer). The PM rules that **the same owners on both chains is fine for testnet.**
4. An Etherscan v2 API key in `.env`; a host, an API domain, free RPC keys per chain, and a Telegram bot token (B).
5. ADR-0009 D3: RedStone's written permission (it gates a *public* testnet).
