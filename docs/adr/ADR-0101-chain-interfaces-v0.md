# ADR-0101 · BE-chain · Interfaces v0: the choices the Build Guide leaves open

Status: Accepted · Date: 2026-09-27 · Owner: BE-chain

BE-chain numbers its ADRs from 0101 so that it never collides with another role's numbers in the shared tree.

## Context

Sprint 1 freezes the Solidity interfaces (`contracts/src/interfaces/`, `contracts/src/libraries/{Types,Errors,Events}.sol`) and their ABIs (`deployments/abis/v0/`). The guide (§8) fixes most signatures. A few things another team builds against are left open, or cannot compile exactly as written. This ADR records each one.

## Decisions

### 1. EIP-712 digest of a price-report batch (`CredencePriceFeed`, §8.3.1)
The guide gives `hashTypedData(keccak256(abi.encode(REPORTS_TYPEHASH, keccak256(abi.encode(reports)))))` but not the typehash string.

- `REPORTS_TYPEHASH = keccak256("Reports(bytes32 reportsHash)")`
- `reportsHash = keccak256(abi.encode(reports))`, where `reports` is one ABI value of type `Report[]`. The encoding is the offset word `0x20`, then the length, then 7 static words per report, in struct order `(assetId, kind, price, observedAt, sessionDate, marketStatus, seq)`.
- Domain: `name = "CredencePriceFeed"`, `version = "1"`, `chainId`, `verifyingContract`. There is no salt.

This is a valid EIP-712 struct with one `bytes32` member, so viem signs it with `signTypedData({ types: { Reports: [{ name: "reportsHash", type: "bytes32" }] }, primaryType: "Reports", message: { reportsHash } })`. `ICredencePriceFeed.hashReports(reports)` returns the final digest, so a test can check it on-chain.

Signatures are 65-byte `r ‖ s ‖ v`, and ordered by strictly ascending **recovered** signer address. High-s signatures are rejected (OZ `ECDSA`).

### 2. `Report.sessionDate`
`sessionDate = floor(regularOpenUtc / 86400)`, which is the UTC day index of the session's regular open. For XNYS (09:30 ET is 13:30 or 14:30 UTC) and for USBANK it equals the ET calendar date's day index. `officialOpen(asset, sessionOpen)` looks up the OPEN report stored for `sessionOpen / 86400`.

### 3. Batch validity
One invalid report reverts the whole `submit`. This covers a stale `seq`, a zero price, an unknown kind or status, and an `observedAt` more than 5 s in the future. `seq` is strictly increasing per (feed, asset) across all kinds. A STATUS report may carry `price = 0`, because it carries no price; every other kind needs `price > 0`.

### 4. Additions to the guide's interfaces (v0)
| Where | Addition | Why |
| --- | --- | --- |
| `IPriceSource` | `lastRegular(asset)` | The clock freezes `refPrice` at the close. The official CLOSE report lands seconds to minutes later. Until it does, the last REGULAR-status print of the session is the reference, and the official close replaces it once it arrives (event `ReferenceUpdated`). |
| `INavSource` (new) | `latestNav(asset)` → `(nav, at, prevNav, prevAt)` | The one-step 0.5% NAV drop rule needs the previous NAV. |
| `FeedHealth` | `statusHalted` | A single-stock halt on the STATUS feed must make the asset HALTED (fail closed, P8). The guide's struct has no field for it. |
| `IOracleAdapter` | `openPrint` also returns `fallbackUsed`; plus `haltReferencePrice`, `dexTwap`, `config`, `setAssetConfig`, `setSharesPerToken` (clock-only), `setClock` | The `OpenPrint` event carries `fallbackUsed`. The rest is wiring and governance. |
| `IAssetClock` | `calendarState`, `closureWindow`, `restriction`, `assetConfig`, `pokeMany`, `setOracle`, `initializeWiring` | `OracleAdapter.feedHealth` needs the calendar-only state for staleness. Markets need the next closure's `(closeAt, reopenAt, type)`. |
| `ClockData` | `closedSessions`, `nextCloseAt`, `corporateAction` | Exactly-once closure accounting (INV-CLK-01), and a clear split between the current closure and the next scheduled close. |
| `ICredenceMarket` | `marketParams`, `marketState`, `position`, `overlay`, `coveredCollateral` views | The guide declares these as public mappings. Declaring them as struct-returning views gives the SDK typed returns. |
| `IUnderwriterPool` | `epoch(e)`, `currentEpoch(venue)` | Indexer / API reads. |
| `IAuctionHouse` | `lotSettled(auctionId)` | The guide's `settlePositions` calls it, but the interface omits it. |
| `Auction` struct | defined here | The guide returns `Auction memory` without defining it. `deadlines` is the same `uint40[4]` as `AuctionCreated`. |
| New interfaces | `ICredencePriceFeed`, `INavSource`, `ITwapSource`, `IProtocolReserve`, `ITreasury`, `ICredenceGuardian`, `ISolverAuction`, `IComplianceRegistry`, `IFaucet` | Components in §8 that had no interface. |

### 5. Errors and events in every ABI
`Errors.sol` is `interface ICredenceErrors`, and `Events.sol` holds one `I<Component>Events` interface per component. Every component interface inherits both, so each exported ABI can decode every Credence revert and carries its own events.

### 6. Name clash in the guide
Appendix B's guardian event `BorrowPaused(bytes32)` and Appendix C's error `BorrowPaused(bytes32 id)` cannot share an ABI. The error keeps the user-facing name. The event is `BorrowPausedByGuardian(bytes32 id)`. This is listed under "Spec issues" in the sprint report.

### 7. Venue ids
A venue id is the ASCII name as a right-padded `bytes32`: Solidity `bytes32("XNYS")`, `bytes32("USBANK")`. For example `bytes32("XNYS") = 0x584e595300…00`. Asset ids stay `keccak256("NVDA:XNAS")` (§7.5).

### 8. Calendar ordering rule
`CalendarStore.appendSessions` requires `extOpen < open < close < extClose` and `s[i].extOpen >= s[i-1].extClose`. The second rule is stronger than the guide's `open > prev.close`, and matches the generator's invariants (BOARD, BE-backend READY 21:45).

### 9. Solidity dependencies are not vendored
`contracts/lib/` is git-ignored. `make contracts-deps`, which every contracts target depends on, installs the pinned tags OZ `v5.6.1`, forge-std `v1.16.2` and solady `v0.1.26` with `forge install --no-git`. Git submodules would need a root `.gitmodules`, which is outside BE-chain's paths. `Uniswap/v3-core` is not installed: its math libraries need solc < 0.8, so `UniV3TwapSource` carries its own minimal pool interface and a 0.8 tick-math port.

## Consequences
The backend's relayer, SDK and indexer build against `deployments/abis/v0/`. Any change after v0 gets a new `READY` entry on the board that says what changed.
