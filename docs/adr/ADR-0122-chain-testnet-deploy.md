# ADR-0122 · BE-chain · Testnet deploy: one script, two stacks, two chains

Status: accepted (S5 Phase 1; scripts dry-run on anvil only, the real deploys are Phase 3) · Date: 2026-09-30

## Context
S5 item D and Amendment 1: the equity (stock-token) stack deploys to **Robinhood Chain testnet (46630)**, and the NAV
(Treasury-fund) stack deploys to **Arbitrum Sepolia (421614)**. They are two independent stacks with no bridge (R-01).
Each has its own Safes, timelock (1 h on testnet), guardian, calendar, clock, feeds, oracle, σ oracle, Stylus engine
router, market, vault, pool, reserve, treasury, tips and faucet. No EOA may keep an admin role after the deploy
(§4, INV-GOV-01). The user supplies the deployer keystore, the Safe owners and the explorer key. Until Phase 3 the
scripts may run on plain anvil only (PM, 2026-09-30).

## Decision
**One entry point, two targets** (`contracts/script/testnet/`):
`make testnet-deploy STACK=equity|nav` runs `deploy.sh`, driven by `config/<chainId>.json`:

1. `DeployTestnet.s.sol`: the three Safes through the **canonical Safe v1.4.1 factory** (`0x4e1D…ec67`, singleton
   Safe L2 `0x29fc…C762`, fallback handler `0xfd07…Ec99`; the salt is fixed by stack and name, so the address follows
   from the owners). A `CredenceTimelock` at delay 0 with the deployer as its only proposer and executor, then every
   contract, the calendar and the listing, sent in timelock batches of 20. Markets are created against
   `ListingParamsEngine` (the bundle's `RiskParams` only), because forge's simulation cannot run WASM. The same batch
   then sets the engine to the router.
2. The Stylus programs (`cargo stylus deploy` + activation), each constructed with the router as its only writer.
3. `router.initializeWiring(pricing, auctionMath)`.
4. The risk bundles (`riskBundles` in the config: equity `cfbb86cb` + alias `9821d6d3` for RHTSLA; NAV
   `nav-5bdf292d`). Every call is scheduled and executed through the timelock, and every set, joint and params hash
   is read back.
5. `FinalizeTestnet.s.sol`: one timelock self-batch. The Gov Safe becomes proposer and canceller, execution opens to
   `address(0)`, the delay becomes 3,600 s, and the deployer's three roles are revoked. The book is marked `finalized`.
6. `postdeploy_check.sh` (also `make testnet-postdeploy-check`), which exits non-zero on any mismatch:
   - roles, timelock delay and admin;
   - each Safe's owners and threshold, and that it is a SafeProxy of the canonical factory (singleton slot, fallback
     handler slot, and the CREATE2 address for the configured owners);
   - every contract's timelock and the guardian's Safe;
   - every deployer-only one-shot wiring done (sequencer health, clock, oracle, guardian, σ oracle, reserve, pool,
     auction house or settlement, tips payers), so no deployer power is left;
   - the vault allocator, faucet and registry owners, and the token issuers;
   - the loan token: tUSDG with 6 decimals on 46630 (ADR-0120), the configured test USDC on 421614;
   - every configured existing token: the official Robinhood test TSLA is the one listed as RHTSLA;
   - calendar sessions and coverage (≥ 300 days);
   - feed and σ committees;
   - markets, caps and vault caps; engine = router; oracle wiring on the stack's own feeds (no DEX, no Chainlink
     source, no mock); faucet drips;
   - every bundle hash; on NAV, that the ADR-0116 local TBILL fixture is **not** loaded;
   - each program's activation time left (> 360 days).

   A failing Safe or contract is reported by name in the revert reason, because forge drops script logs on a revert.

**Refusals:** the script refuses:
- a re-run (the book exists), which would create a second stack;
- a missing input (a Safe owner list, a committee, the fund issuer), with `MissingConfig(<key>)` before anything is
  sent;
- any chain but the stack's own (`WrongChain`; plain anvil only with `DRY_RUN=1`);
- a `PRIVATE_KEY` in the env on a real chain (`KeyInEnv`). Real chains take `DEPLOYER_ACCOUNT` (an encrypted cast
  keystore) and `DEPLOYER_PASSWORD_FILE`. `cargo stylus` reads the password file verbatim, while foundry trims it, so
  `deploy.sh` hands it a newline-free temporary copy (a trailing newline failed with "Mac Mismatch" in the 46630
  check).

**User inputs** are placeholders in the configs:
- `safes.<gov|guardian|ops>.owners`: Gov 3-of-5, Guardian 2-of-4, Ops/Issuer. The same owners on both chains is fine
  for testnet (PM);
- Engineer B's committees (`relayers.*`, `sigma.signers`), `navSolvers`, `registryOperators`, `fund.*`.

The deploy refuses to start while any of these is empty.

**Dry run** (`make testnet-dry-run`, `DRY_RUN=1`) runs the whole path on a fresh plain anvil (chain 31337):
- the canonical Safe factory, singleton and handler contracts are copied from the stack's real chain (`anvil_setCode`,
  read-only RPC);
- `DryRunPrograms.sol` stands in for the two Stylus programs. They keep exactly what the deploy writes and reads back:
  set and joint hashes, params, σ, and σ floors;
- the official Robinhood test TSLA is replaced by its behavioural copy (`MockRobinhoodStock`, ADR-0120);
- anvil accounts stand in for the user and Engineer B inputs.

The dry-run books are `deployments/31337.<stack>.dryrun.json` (git-ignored).

**Verification (Phase 3):** `forge verify-contract` against Arbiscan (Etherscan v2 key) for 421614 and against the
Blockscout explorer of 46630. `cargo stylus verify` for both programs on both chains.

## Consequences
- Phase 1 result (2026-09-30): both targets pass twice in a row from a fresh anvil, the post-deploy check included:
  equity 165 checks + 36 hashes, NAV 87 checks + 4 hashes, and a re-run is refused each time. A corrupted Safe
  singleton and a removed tips payer are reported by name.
- The Stylus live check on 46630 (`stylus/risk-engine/scripts/live-check.sh`) shows the programs deploy, activate and
  match risk-cli there. The Stylus part of one stack costs about 0.00055 ETH on 46630 at 0.01 gwei.
- The dry run cannot prove the WASM engine (anvil cannot run it). The Phase 3 fork rehearsal cannot either, because a
  fork does not execute Stylus. The real engine is proved by the live check and by the post-deploy check's hash
  read-back and `programTimeLeft` on the real chain.
- The same owner set on both chains means one compromised owner set affects both testnet stacks. Accepted for testnet
  only; mainnet needs its own ruling.
