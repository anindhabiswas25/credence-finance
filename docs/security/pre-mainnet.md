# Pre-mainnet security backlog

Owner: QA-sec (list), PM (scheduling). Source: user decision 2026-09-29 (board DECISION 18:30): **the deep audit and
the long soaks happen before mainnet, not in the testnet sprints (S4–S6).** Until then, the QA bar is the edge-case
matrix (`docs/qa/edge-cases.md`).

Everything below was either started in S4 and stopped at that decision, or is an item an external audit would own. It
is ranked by what an auditor is most likely to find. Items are not dropped: each one names what "done" means.

## 1. External review

| # | Item | Done when | Notes |
| --- | --- | --- | --- |
| PM-1 | External audit of `contracts/src/**` (Solidity) | Report received; every High / Medium fixed and re-tested | Scope for the auditors: `threat-model.md`, `triage.md`, `invariant-map.md`, the matrix, and the list in §4 below |
| PM-2 | Dedicated audit of the Stylus risk engine (`stylus/`, §15.1 row 13) | Report received; fixes differential-tested | The engine holds no funds; every call fails closed |
| PM-3 | Off-chain review by a third party (relayer signing path, keeper keys, API auth) | Report received | QA-sec's read-only review is `offchain-review.md` |
| PM-4 | Bug bounty | Live before mainnet TVL | Out of the S4 scope |

## 2. Deep testing (deferred runs)

| # | Item | Done when | State at the deferral |
| --- | --- | --- | --- |
| PM-5 | Full §14.2 catalogue + QA-sec invariants at **512 runs × depth 256** | `make security-invariants` green locally, time recorded | Target and the detached wrapper exist (`security-invariants-bg`); never run (machine rules during the S3 scenario, then deferred) |
| PM-6 | **7 consecutive green nightlies** of `nightly-invariants` (`.github/workflows/security.yml`) | 7 green in a row on `main` | The job exists and may keep running; the count is not a sprint gate |
| PM-7 | Stylus differential at **10M inputs per function** (§14.3) | 0 mismatches | 10k done in S2 (`make stylus-diff`) |
| PM-8 | The ≈ 65-h recorded-weekend run (real time) | Green end to end | BE-backend's S4 plan; replaced in S4 by `make backend-edge` |
| PM-9 | Multi-weekend soak on the devnode | N weekends without an unhandled state | — |
| PM-10 | NAV settlement invariants (cash in = cash out, tokens conserved, floor respected, nothing while HALTED) at 512 × 256 | In the catalogue run | BE-chain landed 5 settlement invariants at 256 × 128 in S4 (their report); the deep run is PM-5 |
| PM-11 | INV-LIQ-02 on the real auction house (the handler never reaches EXTENDED) | Handler extended; invariant at depth | `invariant-map.md` "missing or weak" 2 |

## 3. Threat-model rows left "partly" (`docs/security/threat-model.md`)

| Row | Threat | What is missing |
| --- | --- | --- |
| 1b | Gap worse than history: caps, θ = 100 % loading | The backtest is QE's and lives outside this repo's tests; bring it into CI or record its result per release |
| 4 | Both feeds wrong the same way | **The open-print vs last close ± 50 % guardian page** (REQUEST to BE-backend 2026-09-29 18:02). *Suggest this one is done before public testnet, not deferred: it is small and is the only control for this row.* |
| 4a | Both feeds from one vendor | **Mainnet gate (PM, 2026-09-30 16:30):** on testnet, feed A and feed B on 46630 are both RedStone (`VENDOR=redstone`), as two separate committees, so the §10.1 A/B vendor independence is lost. Before mainnet, feed A and feed B need **two licensed vendors** |
| 10 | Keeper down | Chaos drill (kill keepers during a live Bell and REOPEN; a third party runs the jobs from the tips alone) |
| 13 | Stylus engine bug | PM-2 and PM-7 |
| 14 | Governance key compromise | Key custody: Safes on hardware wallets, signer runbook, timelock 48 h on mainnet (1 h on testnet) |
| 16 | Relayer / keeper key theft | **Balance caps on the hot wallets** (top-up service with a ceiling) and an alert on any unexpected outflow; KMS signers are enforced off dev chains already |

## 4. Remaining Low / Info findings and design questions

| ID | Sev. | Item | Owner | Why it can wait |
| --- | --- | --- | --- | --- |
| QA-11 | Low | Senior vault market list append-only, capped at 32 (market lists 64) | BE-chain / PM | Testnet lists 3–10 markets; fix (a remove path, or MAX_QUEUE = MAX_MARKETS) before the 33rd listing. If it is not fixed in S5, it moves here |
| OFF-06 | Low | Telegram chat id taken as given (alerts can be routed to any chat that started the bot) | BE-backend | Spam only; verify ownership with a `/start <nonce>` handshake |
| OFF-07 | Low | Ponder `/sql` and `/graphql` mounted on the indexer. **Code fixed in S5 (`535923e`: off by default, API statement timeout, read-only role with timeouts)** | Engineer C (network) | Only the network half is left: keep the indexer port on the private network in `infra/prod` |
| OFF-08 | Low | `/metrics` on the public API port and the relayer on 0.0.0.0. **Code fixed in S5 (`eb1f65a`: private listeners, public `/metrics` 404)** | Engineer C (network) | Only the network half is left: the metrics ports stay private in `infra/prod` |
| OFF-11 | Info | SIWE nonce consumed before the signature check, not bound to the client | BE-backend | A user's nonce can be burned (retry works) |
| QA-I1 | Info | The pool has no dead shares | PM (accepted risk?) | Fuzz: loss ≤ (a0 + donation)/1e12 + 2 units |
| QA-I2 | Info | Lazy loss recognition: a senior lender can exit between clear and `settlePositions` | PM / auditors | Keeper settles in the same minute; the audit should look at making settlement atomic with clear |
| E-O-06 | Design | A primary feed off by 1.5–5 % pauses borrowing but not liquidations (valued at the primary) | PM / auditors | The reserve (1 − κ)·V and bidders bound the sale price; ask the auditors whether liquidations should also use min(primary, secondary) under disagreement |
| E-P-07 | Design | Within one pool epoch, withdrawal claims under a cash shortage are first come, first served | PM | FIFO holds across epochs (QA-07); pro-rata within an epoch is a product call |
| TRIAGE | — | Slither / Aderyn Low / Info / Optimisation instances (318 Aderyn Low, the Slither Low set) | QA-sec | Not triaged by design (gate is High + Medium); an auditor-grade pass goes with PM-1 |

## 5. Before mainnet, also re-run
- Everything in `docs/qa/edge-cases.md` (contract side: `make security-test`; off-chain: `make backend-edge`).
- `make security-slither security-aderyn` on the audited commit (0 untriaged).
- The reentrancy and gas-griefing suites on the final `src/` (ADR-0109 sites and every new external call).

## 6. Moved out of S5 (Amendments 2, 3 and 4, 2026-09-30 / 2026-10-01)

The user's rulings: the testnet runs on the user's machine with in-app notifications (Amendment 2, board PM 2026-09-30
17:20); deep testing and all CI/CD move to pre-mainnet (Amendment 3, PM 2026-10-01 16:55); everything is built first,
without new tests (Amendment 4, PM 2026-10-01 17:10). Nothing below is dropped.

### 6.1 Hosting and alerting (Amendment 2)

| # | Item | Done when |
| --- | --- | --- |
| PM-12 | Telegram and email channels switched on (`NOTIFIER_CHANNELS`; code exists, off by default) | A user and an ops alert delivered on each, OFF-06's `/start <nonce>` handshake in place |
| PM-13 | A cloud host with TLS and a domain (Vercel frontend + Railway backend, the user's plan) | The services run there from env only; the testnet machine is retired |
| PM-14 | Alert delivery outside the app (Alertmanager → a pager channel, not only `/v1/ops/alerts`) | A firing `page` alert reaches an on-call person with the app down |

### 6.2 Engineer A's dropped S5 Phase 2 (Amendment 3)

| # | Item | Done when | State at the deferral |
| --- | --- | --- | --- |
| PM-15 | Edge rows E-V-04, E-B-11 (at J3 = 9), E-P-11, E-C-08, E-O-06, E-S-08 in `docs/qa/edge-cases.md` | Each row has a test and passes (`make security-test`) | Rows written, not implemented |
| PM-16 | New edge rows: TokenProbe (ADR-0120), the Chainlink stock source, tUSDG (6 decimals, faucet), the share multiplier (split / reverse split / dividend through `AssetClock` + `OracleAdapter`) | Rows written and green | Unit tests exist for each; no edge rows |
| PM-17 | Line coverage ≥ 95 % on every `contracts/src` directory (`make contracts-coverage`) | Green | Not measured on the S5 tree |
| PM-18 | Invariants at 256 runs × depth 128 on the S5 tree (the deep 512 × 256 run is PM-5) | `make contracts-invariant` green at that depth | The normal suite runs them at the profile default |
| PM-19 | **The static triage gate at 0** on the S5 tree: 17 Slither Medium + 4 Aderyn High keys untriaged (`make security-static`, `target/qa/{slither,aderyn}.json` of 2026-09-30 16:33). **Read first: the `AssetClock` / `OracleAdapter` multiplier path** (A-b917bc11 reentrancy-state-change `AssetClock.sol:151`; S-fa41ddce / S-e46dc918 / S-ce1a709d reentrancy-no-eth in `confirmCorporateAction` and `_poke`; S-605aa19e, S-c5949755, S-eb2ff8ac, S-1be5c4f6, S-bb24eaa9, S-82ee9522, S-8ce1c0f0), then the mainnet-only `ChainlinkStockPriceSource` (A-90690a58 reentrancy, **A-f041e938 storage array edited through a memory copy `:111`**, **A-79e93a28 unsafe cast `:121`**; S-9c3dafc6, S-9c3a08e4, S-f0f9e8eb, S-7f132300, S-363c1655, S-21344962, S-7f0a6f6b). The one-hour Aderyn read planned for S5 is part of this (A4) | Every key triaged in `triage.md`; anything real fixed with an ADR and a regression test | Untriaged. The Chainlink source is not deployed on testnet; the multiplier path is |
| PM-20 | `.github/workflows/deploy-testnet.yml` and any other CI/CD for the deploy (and B's `deploy-services.yml`) | A tagged commit deploys and verifies from CI | Not written; the deploy is run by hand (`make testnet-deploy`) |
| PM-21 | The two mainnet settlement venues `RedStoneSettleVenue` and `UpshiftClearVenue` (Build Guide §18) | Built, tested, audited (PM-1) | Not built; testnet uses `SolverAuction` only |

### 6.3 Engineer B's dropped tests (Amendment 4; B's list, board 2026-10-01 17:32)

| # | Item | Done when |
| --- | --- | --- |
| PM-22 | B's off-chain edge rows (`docs/qa/edge-cases.md`): **K-02** a keeper restart between every pair of steps of J3/J5/J9/J10/J11; **K-08** a lot over 128 positions; **K-09** no bids / no reveals / partial fills; **K-10** pool capacity, the withdraw queue, GDA unsold; **K-11** every NAV J10 path incl. holiday T+1; **K-12** a sequencer gap (R-20) in the keeper; **K-13** HALTED mid-cycle; **K-14** calendar coverage running out; **K-16** `EpochNotSettled` before the next Bell; **I-01** a restart and a full reindex give identical tables; **I-02** an anvil reorg; **I-03** several contracts' events in one block; **W-04** a WS reconnect and a session expiry; **N-04** a channel down → retry → dead letter; **N-05** a duplicate event gives one message; **N-06** the in-app inbox under a duplicate event and a reconnect; **X-03** one chain's RPC down (notifier, process level); **X-08** reindex one chain only; **D-01** a Postgres restart mid-cycle | Each row has a test, green in `make backend-edge` |
| PM-23 | `obs-up` with every §16.1 alert firing once into the in-app ops inbox | Each rule seen firing and resolving, recorded |
| PM-24 | A Postgres backup **and restore**, recorded | `db-backup` + `db-restore` round trip on real data |
| PM-25 | The three runbook drills (a keeper kill, the primary RPC down, an indexer reindex) in `docs/runbooks/drills/` | Each drill recorded with its alert and recovery |
| PM-26 | `services-deploy` then `services-rollback`, recorded | One recorded round trip |
| PM-26a | promtool unit tests for the new S5 rules: OpenPrintDeviation at exactly ±50 %, RPC / indexer down on one chain only, NavPrintMissing, KeeperWalletLow, TipsBudgetLow; `alerts.test.yml` updated to the new labels | `promtool test rules` green |

### 6.4 Deploy tooling findings (Engineer A, S5 build)

| # | Item | Done when | Notes |
| --- | --- | --- | --- |
| PM-27 | **Compiler profile of the deployed contracts.** The deploy script shares a compilation unit with `CredenceMarket`, so forge deploys almost every contract from the `size` profile (optimizer_runs 200, ADR-0107), not runs 10,000 | Mainnet deploys each contract from its intended profile (or the choice is recorded), and the gas numbers are re-measured | Found by `book_meta.sh` (artifacts `<Name>.size`); testnet keeps it, `testnet-verify` verifies with `--compilation-profile size` |
| PM-28 | **Reproducible Stylus deploy and explorer source verification.** Testnet deploys the programs with `cargo stylus deploy --no-verify` (local build, as `live-check.sh` proved) and checks them with `cargo stylus verify --no-verify` | Mainnet deploys in the reproducible docker image, and the source is verified on Arbiscan's Stylus verifier | R-24 (`stylus-repro`) shows the local build is reproducible |
| PM-29 | **A resumable deploy.** `deploy.sh` refuses a re-run once the book exists; a failure after step 1 leaves a half stack and needs a new deploy | Each step records its result and a re-run continues from the first undone step | Mitigated on testnet by the fork pre-flight (`testnet-fork-rehearsal`), which cannot run the Stylus step |
| PM-30 | **Governance signing on Arbitrum Sepolia.** Safe{Wallet} serves Robinhood Testnet (46630) and Arbitrum One, not Arbitrum Sepolia (Safe config service, 2026-10-01), so the 421614 Safes sign through `gov.sh sign/exec` | Mainnet (42161) Safes use Safe{Wallet} with hardware wallets; the CLI path stays as the fallback | Threat-model row 14 |
| PM-31 | **Service keys are file keystores on one machine** (`make testnet-keys`: committees, submitters, keeper, issuer, solver) | KMS signers (`<PREFIX>_KMS_KEY_ID`) for every role, keys split across machines for each committee | Threat-model row 16 |
