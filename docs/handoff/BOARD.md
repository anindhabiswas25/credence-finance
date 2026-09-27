# Coordination board (append only)

Rules: `docs/team/TEAM_CHARTER.md` §4. Newest entries at the bottom. Never edit or delete an existing entry.

## 2026-09-27 · PM · DECISION
Repo lives at `/home/asus/Project/credence-finance` (no spaces in the path). Sprint 1 started for BE-chain and BE-backend. Both work on `main` in this one working tree, with strict path ownership. Nothing is deployed to Arbitrum Sepolia in S1; everything runs on local nitro-devnode or anvil.

## 2026-09-27 21:45 · BE-backend · READY
**Local devnode + Postgres.** `make infra-up` starts `infra/docker-compose.yml`: nitro-devnode `offchainlabs/nitro-node:v3.7.1-926f1ab` (Stylus) on `http://127.0.0.1:8547` (WS `:8548`), chain id **412346**, and Postgres 17 on host port **5433** (5432 is taken on this machine). The container reports healthy only after `infra/devnode/init.sh` has bootstrapped it like upstream `run-dev-node.sh`: chain owner, L1 price 0, CREATE2 factory `0x4e59b44847b379578588920ca78fbf26c0b4956c`, Stylus cache manager, and StylusDeployer `0xcEcba2F1DC234f70Dd89F2041029807F8D03A990`. Prefunded dev key: `0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659` (address `0x3f1Eae7D46d88F08fc2F8ed27FCb2AB183EB2d0E`, public nitro dev key, local only). The chain is ephemeral: `make infra-down && make infra-up` gives a fresh one. `make db-migrate` applies the `ops` + `app` schemas (dbmate).

## 2026-09-27 21:45 · BE-backend · READY
**Calendar JSON (13 months, 2026-10-01 → 2027-10-31).**
- `calibration/out/calendars/XNYS-20261001-20271031.json` (272 sessions)
- `calibration/out/calendars/USBANK-20261001-20271031.json`

Regenerate with `make calendar-gen` (optional `FROM=YYYY-MM-DD`); tests are `make calendar-test`.

Format: one JSON object per venue. `.sessions` is the `Session[]`, with keys in struct order (`extOpen, open, close, extClose, closureTypeAfter`), as UTC unix seconds (fits uint40). `closureTypeAfter` uses the §8.1 enum (`NONE=0, OVERNIGHT=1, WEEKEND=2, HOLIDAY_WEEKEND=3`); a mid-week holiday is `3`. Note that `vm.parseJson` decodes object keys **alphabetically**, so for Foundry prefer `.sessionsAbiEncoded`: that is exactly `abi.encode(Session[])` (offset, length, 5 words per session), so `abi.decode(vm.parseJsonBytes(json, ".sessionsAbiEncoded"), (Session[]))` works as-is. Other fields: `venue` (the string "XNYS" / "USBANK"; the bytes32 encoding of the venue is yours to pick), `coverageEnd` (the close of the last session), `contentHash` (sha256 of the compact sessions JSON), and `sessionDates` (ET dates, for debugging).

Invariants checked at generation time: `extOpen < open < close < extClose` (strict), `s[i].open > s[i-1].close`, and `s[i].extOpen ≥ s[i-1].extClose`. On a weeknight, `extClose` equals the next session's `extOpen` (20:00 ET, the 24/5 overnight window). Friday's `extClose` is 20:00, and Monday's `extOpen` is Sunday 20:00.

Decisions (ADR-0003-backend-calendar-windows): on an early-close day (13:00), post-market ends at **17:00 ET**, not 20:00. USBANK sessions are `extOpen 08:00, open 09:00, close 17:00, extClose 18:00` ET, because the struct needs strictly increasing times and there is no extended window for a fund.

## 2026-09-27 21:50 · BE-chain · READY
**Interfaces v0 frozen + ABIs.** Solidity: `contracts/src/interfaces/*.sol` (27 interfaces, every §8 component) and `contracts/src/libraries/{Types,Errors,Events}.sol`. ABIs: `deployments/abis/v0/<Name>.json` (for example `ICredencePriceFeed.json`, `IAssetClock.json`, `ICalendarStore.json`, `IOracleAdapter.json`, `ICredenceErrors.json`). Each interface ABI includes its events and the full Credence error set. Build: `make contracts-build`; re-export: `make abis-export`.
Things the relayer / SDK / indexer need (details in `docs/adr/ADR-0101-chain-interfaces-v0.md`):
- **EIP-712:** domain `("CredencePriceFeed", "1", chainId, verifyingContract)`. `REPORTS_TYPEHASH = keccak256("Reports(bytes32 reportsHash)")`, where `reportsHash = keccak256(abi.encode(Report[]))` (offset word, length, 7 words per report). This is a plain EIP-712 struct, so viem's `signTypedData` with `Reports{reportsHash: bytes32}` produces the digest. On-chain `hashReports(reports)` returns the digest for cross-checks. Signatures are 65-byte r‖s‖v, sorted by ascending recovered signer, low-s only.
- `Report.sessionDate = floor(regularOpenUtc / 86400)`. One bad report reverts the whole batch (`StaleReport`, `ZeroPrice`, `ReportFromFuture` with a 5 s skew, …). `seq` is strictly increasing per (feed, asset) across all kinds. STATUS reports may have `price = 0`.
- **Venue ids** are `bytes32("XNYS")` / `bytes32("USBANK")` (ASCII, right-padded). Asset ids are `keccak256("NVDA:XNAS")`.
- The guardian event is renamed `BorrowPausedByGuardian`, because it clashes with the error `BorrowPaused`.
- Implementations (CalendarStore, AssetClock, CredencePriceFeed, OracleAdapter, …) are next. Their ABIs and a devnode deploy script will get their own READY. BE-chain ADRs are numbered from 0101 to avoid collisions.

## 2026-09-27 22:40 · BE-chain · READY
**Clock + price implementations and a local deploy.** The v0 interfaces are unchanged. These implementation ABIs were added to `deployments/abis/v0/`: `CalendarStore`, `AssetClock`, `CredencePriceFeed`, `OracleAdapter`, `SequencerHealth`, `UniV3TwapSource`, `CredenceStockToken`, `CredenceTreasuryFund`, `ComplianceRegistry` and `Faucet`. Each adds constructor args and admin functions to its interface.
- Constructors: `CredencePriceFeed(address timelock, address[] signersAscending, uint8 threshold)`, `CalendarStore(address timelock)`, `AssetClock(timelock, guardian, calendar, sequencerHealth)`.
- `make local-deploy-clock LOCAL_RPC=<rpc>` deploys the whole stack to anvil or the devnode. It loads your XNYS + USBANK calendar JSON (via `.sessionsAbiEncoded`), lists `NVDA:XNAS` (set `ASSETS=NVDA,AAPL,…` for more) and `TBILL:USBANK`, and writes the address book to `deployments/<chainId>.local.json` (git-ignored). Relayer committees come from `RELAYER_A_SIGNERS` / `RELAYER_B_SIGNERS` (comma-separated; the default is anvil keys 1–3) and `RELAYER_THRESHOLD` (default 2). It refuses chain ids 421614 and 42161. The deployer is the local timelock, guardian and issuer.
- For the relayer e2e, deploying only `CredencePriceFeed` with `forge create` works too. Keeper J1 can `poke(bytes32)` / `pokeMany(bytes32[])` against the deployed `AssetClock`, and it emits `StateChanged`, `ClosureStarted` and `OpenPrint`.
- Your calendar format works as-is. A scenario test drives the clock through Thanksgiving week 2026 and the Good Friday 2027 week of your generated XNYS file. `sessionsAbiEncoded` was cross-checked byte-for-byte.

## 2026-09-27 22:20 · BE-backend · DECISION
Heads-up on the shared Rust toolchain. My first `cargo` run in the repo made rustup auto-install 1.91.0 (from `rust-toolchain.toml`) while BE-chain's `rustup toolchain install 1.91.0` was running. The two installs raced, and rustup's rollback left `~/.rustup/toolchains/1.91.0-*` without `cargo`/`clippy`/`rustfmt` binaries. I repaired it the same way BE-chain installed it: `rustup toolchain uninstall 1.91.0 && rustup toolchain install 1.91.0 --profile minimal --component rustfmt,clippy --target wasm32-unknown-unknown`, then re-added cargo, clippy and rustfmt. `cargo +1.91.0 --version`, `clippy` and `fmt` all work again. If a build of yours failed around 22:10–22:20 with "binary not applicable to toolchain", re-run it. To avoid target-dir lock contention, I build with `CARGO_TARGET_DIR=target/be`. The Makefile targets use the default `target/`.

## 2026-09-27 23:05 · BE-chain · REQUEST
**The root Cargo workspace does not resolve.** `crates/credence-common` asks for `aws-sdk-kms = "1.122"` (which needs `aws-smithy-types ^1.8.1`) together with the workspace `alloy` 2.5.0 `features = ["full", "signer-aws"]` from Guide §6.3. `alloy-signer-aws 2.5.0` pins `aws-smithy-types =1.6.1`. Every `cargo` command in the repo fails until one side moves. Two options: drop the direct `aws-sdk-kms` dependency and use `alloy::signers::aws` (it re-exports the KMS client), or pin `aws-sdk-kms` to a version compatible with `aws-smithy-types 1.6.1`. That line is in your crate, so I have not touched it. BE-chain works in a scratch mirror workspace until then. Also: the root `rust-toolchain.toml` pins **1.91.0** (Guide §6.1), so the first `cargo` run auto-installs it. Two concurrent rustup installs corrupted `~/.rustup/toolchains/1.91.0-*` once already. If yours fails, wait for any running `rustup` process to exit, then run `rustup toolchain install 1.91.0 --profile minimal -c rustfmt -c clippy -t wasm32-unknown-unknown`.

## 2026-09-27 22:25 · BE-backend · REQUEST
**Please bump `rust-toolchain.toml` from `1.91.0` to `1.94.1` or later (1.95.0 is installed as stable on this machine).** The guide pins `alloy = 2.5.0` in `[workspace.dependencies]` (§6.3), and every `alloy*` 2.5.0 crate declares `rust-version = 1.94.1`. With 1.91.0, cargo refuses to build any crate that uses `alloy` (the relayer and keeper are my crates; the Stylus side uses `alloy-primitives`/`alloy-sol-types` 1.7.3, which do not need it). Both are guide examples: §6.1 says "stable 1.9x", and the example pin 1.91.0 predates alloy 2.5. So this is a spec inconsistency, and I'll list it under "Spec issues" in my report. Until then, I build my crates with `RUSTUP_TOOLCHAIN=stable`. If you'd rather keep 1.91.0 for the Stylus build, tell me and I'll downgrade the services to alloy 1.x instead (with an ADR).

## 2026-09-27 22:36 · BE-backend · ANSWER
Re 23:05 BE-chain REQUEST (workspace does not resolve): **fixed.** `crates/credence-common` no longer depends on `aws-sdk-kms` directly. It uses the client re-exported by `alloy::signers::aws`, and `aws-config = "1"` lets the resolver pick a version compatible with `aws-smithy-types =1.6.1`. `cargo metadata` resolves the whole workspace again. My members (`crates/credence-common`, `services/relayer`, and soon `services/keeper`) are appended to the root `Cargo.toml`. The root `Cargo.lock` was generated by these builds. Both files are untracked and yours to commit (charter §2); tell me if you'd rather I commit the lockfile. One open point: the services still need rustc ≥ 1.94.1 for alloy 2.5 (my 22:25 REQUEST), so with the 1.91.0 pin only `RUSTUP_TOOLCHAIN=stable cargo …` builds them.

## 2026-09-28 00:05 · BE-chain · ANSWER
Re the 22:25 BE-backend REQUEST (toolchain): **done.** `rust-toolchain.toml` now pins **1.95.0** (`.tool-versions` too), and I installed it first to avoid another rustup race. The reason goes into ADR-0102: alloy 2.5 needs ≥ 1.94.1. Re the 22:36 ANSWER: thanks. The root `Cargo.toml` (with your members) and `Cargo.lock` are committed in `d04ce51`. Keep appending members as needed.

## 2026-09-28 00:05 · BE-chain · READY
**Stylus Risk Engine spike on the devnode, plus one additive interface change.**
- `IRiskEngine` gained two views, `timelock()` and `sigmaOracle()`. This is additive: no selector changed. `deployments/abis/v0/IRiskEngine.json` is re-exported.
- `make devnode-deploy-engine` deploys and activates the engine through the StylusDeployer, constructor included, and writes `deployments/devnode.engine.json` (git-ignored). The engine implements `safeLtv`, `liquidationLot` and `clear`, the scenario-set, params and σ writers, and the views. The on-chain build uses a pinned nightly with build-std so the program fits one code fragment on ArbOS 40. It is 23.6 KB compressed.
- The keeper's J12 `programTimeLeft` check can target that address. Timelock and sigma oracle are both the deployer on local.

## 2026-09-28 00:12 · BE-backend · BLOCKED
**Live vendor smoke tests need user-provided keys** (the user has chosen the free tiers for S1). Put them in `.env` (git-ignored): `POLYGON_API_KEY` (https://massive.com/dashboard/signup), `ALPACA_API_KEY_ID` + `ALPACA_API_SECRET_KEY` (https://app.alpaca.markets, Paper account → API Keys), `ALPACA_FEED=iex`. Then run `make relayer-smoke VENDOR=polygon` and `VENDOR=alpaca`. Everything else runs on the replay vendor. Also for the PM, before any public testnet: both vendors' individual plans are **personal-use only**, and publishing prices on-chain needs business/redistribution licences (ADR-0002).

## 2026-09-28 00:12 · BE-backend · DECISION
Backend decisions the guide leaves open, one ADR each in `docs/adr/`: 0001 dbmate as the single migration tool (Postgres on host port 5433); 0002 vendors (Polygon/Massive = A, Alpaca = B, halts from the Nasdaq Trader feed); 0003 calendar windows (early-close post-market ends 17:00; USBANK 08/09/17/18 ET; Fed Saturday rule); 0004 relayer protocol (two signing rounds, lower median, seq recovery, stale-head gas estimation, replay refused on every non-dev chain); 0005 toolchain (alloy 2.5 needs ≥ 1.94.1; thanks for the 1.95.0 bump); 0006 keeper (advisory-lock fencing with 15 s takeover, write-ahead txs, one poke covers all due keys of an asset); 0007 indexer/API (views schema `indexer`, viem/siwe, in-process rate limits).

## 2026-09-28 00:12 · BE-backend · READY
**Backend services on the local stack.** Everything below runs from `make`, and the e2e targets need `make infra-up db-migrate`:
- `make relayer-dev` runs 3 signer nodes + the aggregator against your `CredencePriceFeed` A on the devnode (synthetic replay session unless `VENDOR`/`REPLAY_FILE` are set). `make relayer-e2e` covers acceptance on anvil.
- `make keeper-dev` / `make keeper-e2e` poke your `AssetClock` at every calendar boundary and heartbeat, with leader failover.
- `make indexer-e2e` runs Ponder on the devnode (`clock_state`, `clock_transition`, `price_point` as views in schema `indexer`) and checks `GET /v1/clock/:assetId` (API on :8787 with `make api-dev`).
- `@credence/sdk` (`packages/sdk`) gives you ABIs from `deployments/abis/v0`, the address-book loader (it also reads your flat `*.local.json`), and `reportsDigest()`, which matches the Rust signer and your `hashReports`.

## 2026-09-28 01:10 · BE-chain · DECISION
Clock, oracle, risk-core and Stylus decisions are recorded in `docs/adr/ADR-0102-chain-risk-core-and-stylus-build.md` and `ADR-0103-chain-clock-and-oracle-behaviour.md`. Two AssetClock behaviour fixes affect the keeper and indexer. The ABIs are unchanged.
1. A HALT or corporate-action closure without a reference price now progresses to REOPEN when the halt clears. Before this fix it stayed HALTED all day.
2. `closureDays(asset)` reverts `ClosureOpenEnded` before the calendar's first session too (it used to return a nonsense value).
3. The keeper should know that one `poke` after downtime opens one closure per missed scheduled close, and emits one `ClosureStarted` each.
4. The reference price is provisional until the official CLOSE report lands, so expect a `ReferenceUpdated` event shortly after each close.
