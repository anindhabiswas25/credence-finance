# Sprint 5 brief · Engineer A: finish the blockchain build and deploy (Amendment 3)

From: PM · Date: 2026-10-01 · Repo: `/home/asus/Project/credence-finance` · Role name on the board: **BE-chain**

This brief **replaces A's Phase 2 and Phase 3** in `sprint-5-protocol.md`. The rest of that brief (rules, paths, Amendment 1) still applies.

## Amendment 4 (user, 2026-10-01 17:10): build everything first, without testing
The user: "first build everything without testing, build the full blockchain part and backend part e2e". Two engineers again: you (A, blockchain) and **Engineer B (backend + ops; C's items merged into B, brief `sprint-5-backend-finish.md`)**. Where this brief says C, read B. Changes below are marked **(A4)**. Build first; the deploy comes after both BUILD READYs.

## Amendment 3 (user, 2026-10-01): build and deploy now, test before mainnet

The user: "I have not enough time to test the full product, we will do it before mainnet. Leave the long testing and all the CI/CD." So:
- **Dropped from S5, moved to pre-mainnet:**
  - A's Phase 2 edge-case rows (E-V-04, E-B-11, E-P-11, E-C-08, E-O-06, E-S-08, the TokenProbe / Chainlink / tUSDG / multiplier rows);
  - coverage ≥ 95 %;
  - invariants at 256 × 128;
  - the Slither/Aderyn triage gate at 0, including the one-hour Aderyn read **(A4: dropped from S5)**;
  - `.github/workflows/deploy-testnet.yml` and any other CI/CD work.
- **Kept:** the normal suites must stay green before every commit (`make contracts-test risk-test abis-check`). They are fast and they guard the deploy. Each new script gets a small test or a dry-run proof, nothing more.
- **Still out of scope for testnet:** `RedStoneSettleVenue` and `UpshiftClearVenue` (mainnet venues, Build Guide §18).

Phase 1 is complete (READY 2026-09-30 16:48). No new contracts are needed for testnet. What's left is deploy tooling, then the deploy.

## Read first
1. `docs/handoff/BOARD.md` from `2026-09-30 16:30` to the end: the NAV issuer EOA ruling, Amendment 2 (local hosting), C's keystore layout and RPC REQUEST.
2. `contracts/script/testnet/` (your deploy scripts), `config/{46630,421614}.json`, ADR-0122.
3. `docs/team/prompts/sprint-5-ops.md` (Engineer C's keystore layout and per-chain env).

## Build items, in order

### 1. Service keys into the configs (`make testnet-keys CHAIN=46630|421614`)
The deploy refuses to start today because `relayers.feedA/feedB` (46630), `relayers.nav`, `fund.issuer` and `fund.reserveWallet` (421614) are empty.
- One script generates every service keystore for a chain:
  - 46630: the feed A and feed B committee signers and the relayer submitters;
  - 421614: `nav-1..N`, `issuer`, the solver bot, and the registry operators if any;
  - either chain: the keeper wallets, if the deploy grants them anything.
- **Use C's layout exactly:** `KEYSTORE_DIR/<chainId>/<role>.json` + `.password` (0600), encrypted (`cast wallet new` / `import`). Agree the role names with **B** on the board **before** you write the script (A4: B owns the keystore layout now).
- The script writes the **addresses only** into the config. It refuses to overwrite an existing keystore and never prints a key or a password.
- Decide what `fund.reserveWallet` is (an EOA or the Ops Safe) and record it in ADR-0122.
- Dry-run proof: `make testnet-dry-run` passes with configs filled by the script (on anvil, with a throwaway `KEYSTORE_DIR`).

### 2. Contract verification (`make testnet-verify STACK=equity|nav`)
Today `deploy.sh` runs `cargo stylus deploy --no-verify`, and nothing calls `forge verify-contract`.
- Verify every Solidity contract in the address book: Blockscout on 46630 (the `verify` block in `46630.json` is already there; check whether it needs a key) and Arbiscan on 421614 (`ETHERSCAN_API_KEY`). Take the constructor args from the broadcast files.
- `cargo stylus verify` for both Stylus programs (pricing, auction-math) on each chain.
- Make it idempotent (skip what is already verified, retry what failed) and write each contract's verify status into the address book. A failure must not undo the deploy; it just leaves the target to re-run.

### 3. Deploy rehearsal on a fork (`make testnet-fork-rehearsal STACK=equity|nav`), ≤ 30 min per run
- `anvil --fork-url` of each chain's public RPC, then the whole `deploy.sh` + `FinalizeTestnet` + `testnet-postdeploy-check` against the fork.
- It proves what the plain-anvil dry run can't: the real canonical Safe v1.4.1 factory, the real official RHTSLA token (`0xC9f9…Bd4E`, its transfer rules) and the real Circle test USDC on 421614.
- **anvil can't run Stylus WASM:** keep the Solidity stand-ins for the programs on the fork. The real Stylus path is already proven by `live-check.sh` on 46630, and the real deploy proves it on 421614. Say so in the script's header.
- **(A4) Build the target now; don't run it yet.** It runs once per stack as the first deploy step, as a pre-flight, not a test suite.

### 4. Frozen testnet ABIs
- Add a `v5-testnet` tag under `deployments/abis/` (the ADR-0114 v5 set), checked by `abis-check`.
- If any ABI changes before the deploy, bump the tag. The final tag must match the deployed commit, and B's SDK pins to it. Post the tag on the board.

### 5. Governance scripts for after the deploy (`make gov-propose …`)
After `FinalizeTestnet` no EOA keeps admin, so every change goes Gov Safe (3-of-5) → timelock (1 h) → execute. Build the tooling for the changes we will need in the first weeks of testnet:
- **list a market** (the guide's `ListMarket.s.sol`: `listAsset` on the clock, the oracle config, `createMarket`, vault caps and queues; reuse `ListingParamsEngine.sol`);
- **change caps;**
- **load a new risk bundle** (reuse `load_risk_bundle.sh`'s schedule/execute logic);
- **extend calendar coverage**, if the timelock owns it (check which role does; if it's an ops/keeper role, say so and skip it);
- **Guardian pause / unpause.**
- Output: the timelock `schedule` and `execute` batches as **Safe Transaction Builder JSON**.
- Check whether Safe{Wallet} supports 46630. If it doesn't, also add a CLI path: owners sign with their keystores (`cast wallet sign`), and the script calls `execTransaction`. Prove each action once on an anvil dry-run book.

### 6. (A4) Dropped: the Aderyn read moves to pre-mainnet
Record the 4 Aderyn High and 17 Slither Medium keys in `pre-mainnet.md` as untriaged, naming the `AssetClock` / `OracleAdapter` multiplier path as the first to read.

### 7. `docs/security/pre-mainnet.md` rows
Add:
- **Amendment 2:** the Telegram/email channels switched on; a cloud host with TLS and a domain; alert delivery outside the app.
- **Amendment 3:** your dropped Phase 2 rows, coverage ≥ 95 %, invariants, the triage gate (17 Slither Medium + the remaining Aderyn keys), the CI deploy workflow, and the two mainnet settlement venues.
- **(A4) B's dropped tests:** B posts the list on the board (the edge rows, the drills, the obs-up firing, backup/restore and deploy/rollback recordings, promtool unit tests). You add them, because `pre-mainnet.md` is your file.

### 8. One consolidated user REQUEST on the board (post it as soon as item 1's role list is agreed)
- A deployer keystore with test ETH on 46630 (`faucet.testnet.chain.robinhood.com`) and 421614. State the amount per chain from your dry-run gas, plus a margin.
- The Safe owner addresses: Gov 5, Guardian 4, Ops ≥ 2 (the same owners on both chains is fine).
- `ETHERSCAN_API_KEY`, and the Blockscout key if one is needed.
- The RPC keys are C's REQUEST (17:30); reference it, don't repeat it.

Post a **BUILD READY** when items 1–7 are done, the suites are green, and the dry run with filled configs passes.

**(A4) Testing rule while building:** write no new tests or edge suites. Before each commit, the code must build and the existing fast suites must still pass (`make contracts-test risk-test abis-check`; they take minutes). That is a regression guard, not new testing. The dry run counts as the build check for the scripts. The `gov-propose` actions need only a dry-run on an anvil book, not a test.

## Deploy (after BUILD READY, the user's inputs, and a PM DECISION on the board)
1. `make testnet-fork-rehearsal` for both stacks (once each, as a pre-flight).
2. `make testnet-deploy STACK=equity` → **46630**, then `STACK=nav` → **421614**.
3. `make testnet-verify` for both stacks; `make testnet-postdeploy-check` green on both.
4. Freeze the final ABI tag. Commit `deployments/46630.json` and `deployments/421614.json`.
5. Post a **READY to B and C** with both address books, each contract's deploy block (the indexers' start blocks), the ABI tag, and the service-key role list.
6. Write the final report `docs/handoff/sprint-5-protocol-report.md` (template `REPORT_TEMPLATE.md`), with the dropped items listed as pre-mainnet.

## Acceptance (the PM re-runs these)
1. `make contracts-test risk-test abis-check` green from a clean clone.
2. `make testnet-dry-run` green with configs filled by `make testnet-keys`; `make testnet-fork-rehearsal` green once per stack at deploy time.
3. Each `gov-propose` action dry-run once on an anvil book.
4. Both stacks deployed, every contract verified (Solidity + Stylus), `make testnet-postdeploy-check` green on both books.
5. `pre-mainnet.md` holds every dropped item; the report is final.

## Rules (unchanged)
- Charter §2/§2b/§2c. Stage only your paths. Never `git add -A`, `git stash`, `git reset --hard` or `git clean`. Don't touch `apps/web/` or the `pnpm-lock.yaml` diff.
- No run over ~30 min. Never print or commit a private key or a password; keystores stay outside git.
- Post a board entry at every READY, blocker or finding. When the PM or the user must decide, ask on the board and carry on with the next item.
