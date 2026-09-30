# Sprint 5 brief · Engineer A: Protocol (BE-chain, also covering QE and QA-sec)

From: PM · Date: 2026-09-30 · Repo: `/home/asus/Project/credence-finance` · Target: **finish S4, then the whole blockchain side up to the Arbitrum Sepolia testnet (M9). No frontend this sprint (user, 2026-09-30).**

## Context

The user now runs **two engineers at a time** for all the work before testnet: you (**Engineer A**, role name on the board **BE-chain**) and **Engineer B** (role name **BE-backend**, brief `docs/team/prompts/sprint-5-platform.md`: services, edge suite, DevOps). QE and QA-sec are not staffed. **Their work that is needed before testnet is yours**, and so are their paths (charter §2b). The Frontend is **out of scope** (user decision).

Where S4 stopped (PM check, 2026-09-30 05:15 IST):
- **Item E is not done.** `target/chain/devnode-integration.log` started at 19:18Z and stops after the second bundle load. `devnode-gas.log` stops at "waiting for bellAt" (23:30), and the four N=32/N=40 runs before it aborted. No READY was posted. The devnode is not running now.
- **Uncommitted in your paths:** `contracts/script/devnode_gas.sh`, `contracts/script/devnode_integration.sh`, `mk/contracts.mk`, `contracts/test/fixtures/risk/tbill-local/`, `docs/adr/ADR-0116-chain-nav-engine-fixture.md`. Check them, then commit them first.
- **`apps/web/` is untracked**: the user's own UI work. **Do not touch, stage or delete it.** The same goes for the `pnpm-lock.yaml` diff it caused.
- The PM rulings on your S4 report §6 and QA-sec's §7 are on the board (2026-09-30 PM DECISION). Implement nothing new for them. They only close the questions.

The user's standing rules (do not argue them):
- **Free data APIs only.** No paid plan is a default.
- **No long test runs now (user, 2026-09-30).** Nothing over ~30 min of wall time per run. Prove behaviour with **edge-case tests** instead: forge, anvil time warps, and short devnode runs. A run needed only for a wall-clock property (the ≈ 65-h run, soaks) is pre-mainnet.
- **The deep audit and long soaks are pre-mainnet** (`docs/security/pre-mainnet.md`). Before testnet, test every probable edge case.

## Read first
1. `docs/team/TEAM_CHARTER.md` §2, **§2a, §2b (new: two engineers)**.
2. `docs/handoff/BOARD.md` from `2026-09-29 18:30` to the end, especially the PM DECISION of 2026-09-30.
3. Your S4 report `docs/handoff/sprint-4-blockchain-report.md`, QA-sec's `sprint-4-security-report.md`, `docs/qa/edge-cases.md`, and `docs/security/pre-mainnet.md`.
4. `docs/CREDENCE_BUILD_GUIDE.md`: §3.3, §4 (roles, timelock, Safes), §8.12 (testnet assets, faucet), §10.1 and ADR-0009 (RedStone), **§17.2 M9**, §18.

## Work items, in order

### A. Close S4 (first; it unblocks Engineer B)
1. Commit the uncommitted work above (`git add` your paths only).
2. **Item E on the devnode.** Post a board DECISION that you hold the devnode, then:
   - `make devnode-integration` with phase 6 (NAV fill plus pool advance through the Stylus router);
   - `make devnode-gas` for ADR-0114. Keep the J3 bracket if a Bell batch at least doubles (J3 10 → ≥ 20 positions), otherwise revert it. Write ADR-0114 with the numbers. If N = 32 keeps aborting, find out why (log, gas, or script) before you shrink N. Keep each run under ~30 min: use a synthetic calendar with short sessions, and don't wait hours for a real Bell;
   - redeploy the main book `deployments/412346.local.json` (real NAV settlement, the QA-10 fix), then the QE bundle and the ADR-0116 TBILL fixture.
   - Post **READY with the new book**. Engineer B runs `make nav-settlement-e2e` on it.
3. **Item G (was QA-sec):** re-run QA-sec's devnode checks on the new book, the security suite and the triage gate (`make security-findings security-slither security-aderyn`). Add the coverage-context skip to `test_enforceBell_gasCannotForceASale` (board 18:08). Then commit `docs/handoff/sprint-4-security-report.md` §2 item 6 and §4 filled.
4. Commit `docs/handoff/sprint-4-blockchain-report.md` final (acceptance 6). Post S4 READY.

### B. Contract changes needed for testnet
- **QA-11 (PM ruling):** `SeniorVault.disable(id)` for a market with 0 supplied, timelocked, with a test. Flip `test_E_V04_QA11_…` into a regression test.
- **Testnet equity set (ADR-0009 D2, PM default on the board):** RedStone does not carry COIN or SPY. Testnet lists **NVDA, AAPL, TSLA, MSFT, GOOGL, AMZN**. If the user gets a written "yes" from RedStone for COIN and SPY before your deploy, swap back. Everything that names the six assets (deploy config, fixtures, the synthetic book) follows the config, not code.
- Keep every existing suite green: `make contracts-test risk-test contracts-coverage abis-check`, coverage ≥ 95 % per `src/` directory, invariants at 256 × 128.

### C. Risk data for testnet (was QE; `calibration/**` is yours this sprint)
- **GOOGL and AMZN:** scenario sets, σ and σ floors, joint column. Use the existing pipeline (`make cal-all`) on Alpaca SIP from 2016 (`dataGrade: "free-2016"`), with Polygon/Massive free as a cross-check. No paid data.
- **TBILL (replaces the ADR-0116 fixture on testnet):** a real set, σ and a joint column for `TBILL:USBANK`. The proxy is a free T-bill ETF daily series (for example BIL or SGOV on Alpaca), with the NAV-versus-price difference stated. Write an ADR on the method. After this lands, the NAV pool can sell cover on a Stylus book (ADR-0116, Consequences).
- Produce a new signed risk bundle. It must load with `risk-load-set` on the devnode, and the backtest report must be updated for the new assets.

### D. Testnet deploy scripts (M9; `contracts/script/testnet/**`, `.github/workflows/deploy-testnet.yml`)
- One deploy path for **two independent stacks on Arbitrum Sepolia (421614)**: the equity stack and the NAV stack, each with its own vault, pool, reserve and treasury (R-01). Test collateral tokens, `CredenceTreasuryFund`, faucet (§8.12), calendars, feeds, the Stylus Risk Engine plus the router, timelock at **1 h**, roles to the Safes (§4). **No EOA keeps an admin role after the deploy.**
- The address book `deployments/421614.json`, and the frozen ABIs tagged `v…-testnet` in `deployments/abis/<tag>/`.
- Verification: Arbiscan (`forge verify-contract`) and `cargo stylus verify` for each Stylus program.
- **A post-deploy checklist script** (`make testnet-postdeploy-check`): every role and admin, the timelock delay, calendars and coverage end, feed signers and threshold, risk-set hashes, caps, the faucet limits, that `ChainlinkPriceSource` and the mock contracts are not wired, and that the ADR-0116 fixture is not loaded. It exits non-zero on any mismatch.
- **Rehearse the whole deploy on an anvil fork of Arbitrum Sepolia** (`anvil --fork-url` with a free public RPC), then run the post-deploy check on the fork. The rehearsal must pass twice in a row from a clean state.
- **The real deploy needs the user:** a funded deployer key, the Safe owner addresses, and an Arbiscan API key (free). Post a board REQUEST with the exact list as soon as D starts. Deploy only after the user has provided them and the PM has posted a DECISION. Hand the address book to Engineer B with a READY.

### E. Edge cases, contract side (was QA-sec)
This replaces the long runs: every contract-side row of `docs/qa/edge-cases.md` must have a passing test, and each thing you change (B, C, D) gets new rows. At least:
- `disable(id)` with 0 supplied, with dust supplied, while it is still in the withdraw queue;
- the GOOGL/AMZN and TBILL sets at their exact limits (σ floor, the worst scenario, a stale set hash);
- TBILL cover through the pool with the real joint column: capacity at the edge, the concentration limit at exactly 35 %, and a fallback advance when no solver bids;
- deploy edges: a re-run of the deploy script is idempotent or refuses, a missing Safe address fails loudly, and a wrong chain id refuses;
- the closure edges on the testnet calendars: DST switch, holidays, early close, calendar coverage ending.
 File a REQUEST to Engineer B for any off-chain gap you see.

## Amendment 1 (PM, 2026-09-30): two chains. The equity stack goes on Robinhood Chain; the NAV stack stays on Arbitrum

**Decision:** we follow the Architecture's split. The **equity (stock-token) stack deploys to Robinhood Chain testnet (chain id 46630, RPC `https://rpc.testnet.chain.robinhood.com`, explorer `explorer.testnet.chain.robinhood.com`)**. The **NAV (Treasury-fund) stack deploys to Arbitrum Sepolia (421614)**. Two independent stacks, with no bridge, as R-01 already says. Why: Robinhood Stock Tokens have lived on Robinhood Chain since its mainnet (1 July 2026), each with a Chainlink feed. There is almost no lending against them there yet, and the testnet faucet gives test Stock Tokens (TSLA, AMZN, PLTR, NFLX, AMD). The Treasury funds (BENJI, USTBL) are on Arbitrum.

Changes to your items (the rest of the brief stands):
1. **Day-one check (before D): Stylus on 46630.** Builders report ArbOS 61 / `ArbWasm.stylusVersion() = 3` there, but Robinhood's docs only show Solidity. Read `stylusVersion()`, then `cargo stylus deploy` the Risk Engine programs and call them through the router on 46630. Post the result on the board. **If Stylus is not usable**, stop and post a REQUEST to the PM. The fallback is the Architecture's Solidity port with smaller sets, and it needs a ruling.
2. **D, deploy scripts:** one script with two targets: `equity` → 46630 (address book `deployments/46630.json`) and `nav` → 421614 (`deployments/421614.json`). Rehearse both on anvil forks (`anvil --fork-url` each RPC), twice each. `make testnet-postdeploy-check` checks both books. Verification on the Robinhood Chain explorer (Blockscout-style, check which verifier it takes) and on Arbiscan. Each stack has its own Safes, timelock, vault, pool, reserve and treasury.
3. **Loan token:** the Architecture uses USDG on Robinhood Chain. On the testnet, use a test USDG (your 6-decimal test stablecoin, labelled "tUSDG") unless a USDG test token exists on 46630. Check the Robinhood docs and the faucet, and write down what you found. The NAV stack keeps test USDC.
4. **Equity asset set on 46630:** keep our own test collateral tokens (R-02; the faucet only gives 5 units a day). Use the tickers **NVDA, AAPL, TSLA, MSFT, GOOGL, AMZN** from the earlier decision. **Also list one official Robinhood test Stock Token (TSLA or AMZN)** as an extra market, capped low, to prove the integration with the real token contract, including whatever transfer rules it has. Record the token's interface (ERC-20, 18 decimals, the ERC-8056 multiplier) in an ADR.
5. **New in B, the ERC-8056 multiplier (required for real Stock Tokens).** Chainlink defines the token price = underlying price × multiplier, which covers dividends, splits and other corporate actions. Our contracts read no multiplier today. Add it in the collateral/oracle path so collateral is valued per token, not per share. A scheduled large multiplier update must put the asset in `CORP_ACTION` (no borrow, no liquidation) until it is applied. Our test tokens implement the same multiplier. Edge tests: 2:1 split, 1:3 reverse split, a small dividend update applied at once, a large update during an open position, and a multiplier change across a closure.
6. **New, mainnet adapter only (not deployed on testnet):** a Chainlink `IPriceSource` for Robinhood Stock Token feeds (24/5; last price held while closed; `updatedAt` staleness; the multiplier). Chainlink lists these feeds on mainnet only, so the testnet keeps our relayer feeds. Unit-test it against recorded feed data.
7. **User REQUEST, amend your 2026-09-30 list:** the deployer needs test ETH on **both** chains (Robinhood testnet faucet: `faucet.testnet.chain.robinhood.com`), and you need Safe owners for two sets of Safes (or the same owners for both; ask the user). The explorer API key for 46630, if its verifier needs one.
8. **Acceptance 4 changes:** both stacks pass the fork rehearsal twice, then deploy once on 46630 and once on 421614, with the post-deploy check green on both and every contract verified.

Time: about +1 day. Order stays A → B → C → D → E. The Stylus check (1) goes first because D depends on it.

## Acceptance (the PM re-runs each item from a clean clone)
1. S4 closed: item E READY with the new book, ADR-0114 with numbers, item G done, both S4 reports final.
2. QA-11 fixed. The GOOGL/AMZN and TBILL risk data are in a signed bundle, loaded on the devnode, and the backtest is updated.
3. `make contracts-test risk-test contracts-coverage abis-check security-findings` from a clean clone: green, coverage ≥ 95 %.
4. The testnet deploy passes twice in a row on an Arbitrum Sepolia fork, with `make testnet-postdeploy-check` green, and then **once on Arbitrum Sepolia** after the user provides the keys. Every contract is verified on Arbiscan, and the Stylus programs pass `cargo stylus verify`.
5. `docs/qa/edge-cases.md` has a test name on every row you own, and every one of those tests passes.
6. Final report `docs/handoff/sprint-5-protocol-report.md` (template `docs/handoff/REPORT_TEMPLATE.md`) and a final READY.

## Rules
- Charter §2 and §2b. Stage only your paths. Never `git add -A`, `git stash`, `git reset --hard` or `git clean`.
- The devnode is shared. Post a DECISION before you hold it, and a READY when you release it. While Engineer B has a devnode run live, run heavy jobs with `nice -n 19`, `forge --threads 4` and `CARGO_BUILD_JOBS=4`.
- No run longer than ~30 min. If a devnode run gets near that, use `setsid nohup` inside `systemd-inhibit`, with an `ABORTED` line if it dies.
- Never print or commit private keys. Testnet keys live in an encrypted keystore (`cast wallet import`), never in `.env` in git.
- Post a board entry at every READY, blocker, or finding. When the PM or the user must decide something, ask on the board and go on with the next item.
