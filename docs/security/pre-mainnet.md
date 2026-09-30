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
