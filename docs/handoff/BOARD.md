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
