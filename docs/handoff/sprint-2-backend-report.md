# Sprint 2 report · Senior Backend Engineer (BE-backend)

Date: 2026-09-28 · Session model: Claude Opus 5.5 (wave 2, resumed after the rate-limit cutoff; earlier S2 work kept: relayer WS `c498692`, notifier `4e78ea8`) · Commits (this session): `a766203..HEAD`

## 1. Summary
The backend now serves and operates the S2 lending core.
- **R-26 is settled with evidence (ADR-0009).** RedStone pull is the free, on-chain-verifiable testnet source, measured on Arbitrum Sepolia. Pyth is paid since 2026-08, and Chainlink has only SPY on Sepolia. Three decisions are left for the PM and the user.
- **Keeper J7** reproduces QE's σ vectors bit for bit and works on real contracts: SigmaOracle accepts the keeper's 2-of-3 committee, and the Stylus engine accepts the planned σ and rejects a too-fast drop.
- **Keeper J2, J3/J4 (dry-run), J8 and J12, plus a testnet allowlist sender**, are proven against BE-chain's `DeployCoreLocal`: the Bell amounts equal `CredenceMarket.bellStatus`, and the J3 dry-run's predicted outcomes equal the `BellEnforced` events.
- **Indexer** tables: `market`, `position`, `position_event`, `vault_state`, `vault_request`, `sigma_point` and `price_point.status`.
- **API endpoints**: `/v1/markets`, `/v1/positions`, `/bell` (risk-wasm), `/v1/vault`, `/v1/me/notifications` (SIWE), `/v1/testnet/allowlist` and the WS `/v1/stream`.
- **SDK**: v1 ABIs and the risk-wasm helpers.
- **Observability** as code: Prometheus and Grafana (`make obs-up`).

**Not done:** the market-level half of acceptance 4 (`/bell` == `CredenceMarket.bellStatus` for 100 positions on the devnode). It is written (`make api-bell-e2e`) and waits for BE-chain's `DeployCoreLocal` on the devnode against the new Stylus engine (announced as their next step). The engine-level half already passes with 0 mismatches.

## 2. Acceptance checklist
| # | Item | Status | Proof (command + key output) |
| --- | --- | --- | --- |
| 1 | `make backend-install backend-build backend-test` passes from a clean clone; e2e targets pass with `make infra-up db-migrate` | ✅ | Clean clone of `e7ca05c`: `make backend-install backend-build backend-test` → **EXIT 0 in 5 m 37 s**. E2e (devnode + Postgres up): `make relayer-e2e` (1 ok), `keeper-e2e` (2 ok), `keeper-core-e2e` (1 ok), `keeper-j7-e2e` (2 ok), `keeper-j12-e2e` (1 ok), `notifier-e2e` (3 ok), `indexer-e2e` (clock + prices + WS stream OK), `indexer-core-e2e` (OK), `api-db-test` (2 ok), `api-engine-e2e` (0 mismatches). `make backend-lint` clean |
| 2 | Licensing ADR recommends an option, with a cost table and a prototype reader run against Arbitrum Sepolia | ✅ | `docs/adr/ADR-0009-backend-onchain-licensed-feeds.md`; `make r26-probe` → RedStone NVDA/AAPL/TSLA/MSFT verified by RedStone's own connector through `eth_call` on Sepolia (block 313,535,159), `tamperedReverted: true`; Chainlink SPY/USD 771.3425; Pyth Sepolia prices frozen since 2026-08-26, Hermes 401 |
| 3 | Notifier delivers the Bell heads-up for scenario A (G-10, G-11) with exact amounts through email + push in an e2e | ✅ (built earlier in S2, re-verified) | `make notifier-e2e` → `test/e2e.test.ts (3 tests)` passed |
| 4 | API `/bell` quote equals on-chain `bellStatus` / `quoteCover` for 100 random positions on the devnode | ⚠️ partial | **Engine level ✅:** `make api-engine-e2e` → `100 positions checked over 18 sets (NEEDS_ACTION 47, safe LTV below max 29), mismatches 0`. The API's risk-wasm `safeLtv` / `bellStatus` / `quoteCover` equal the devnode Stylus engine with QE's bundle. **Market level ⏳:** `make api-bell-e2e` (100 positions, `/bell` vs `CredenceMarket.bellStatus` and `engine.quoteCover` at the API's block) is ready and needs `DeployCoreLocal` on the devnode (BE-chain). The market plumbing is already proven equal by the keeper (next row), which reads the same inputs |
| 5 | Keeper e2e with `DeployCoreLocal`: J2 enqueues correct notifications; J3/J4 dry-run logs match; J7 submits σ the engine accepts and a too-fast drop is rejected; J8 runs; failover holds | ✅ (see note) | `make keeper-core-e2e` → `J2 T-2h == bellStatus @150: repay 2885925447 collateral 22499812661111111112 premium 35950000`; `J3 predicted outcome 2 == BellEnforced 2`; `J4: healthFactor 835310615625033634, planned flags 1`; `claimFees` + `processQueue` + allowlist asserted. `make keeper-j7-e2e` → SigmaOracle accepts the 2-of-3 committee (1-of-3, unsorted and replayed updates revert); the Stylus engine accepts the planned σ, and a 20% drop reverts with `SigmaDropTooFast` (selector 0x808f14d5). `make keeper-e2e` → `leader_failover_no_duplicates ... ok`. **Note:** J3/J4 are checked against the contracts' own answers (the market's `BellEnforced` outcome, `healthFactor`), which is stronger than a risk-cli log comparison; the Bell math itself is cross-checked with risk-cli in the notifier e2e and with the Stylus engine in `api-engine-e2e`. `DeployCoreLocal` runs on anvil (the Solidity stand-in engine with the scenario A safe LTV injected). The Stylus-engine side of J7 runs on the devnode |
| 6 | Indexer and API serve markets, positions and the vault from a local scenario-A run | ✅ (scenario A's Friday) | `make indexer-core-e2e` → Ponder on `DeployCoreLocal`: 7 markets (6 equity + TBILL) with live rate and next closure; vault TVL 1,000,000; Priya 500 tNVDA / $67,000 (LTV 74.44%). At the Bell `enforceBell` → indexed `bell_enforced` (outcome 2) + `cover_bought` (35950000), and the API shows `coveredForNext: true`. The run covers Friday (borrow → Bell → auto-cover), not the whole Monday–Friday week: each overnight would need the S3 reopen driver (J5) |
| 7 | Dashboards and alert rules load in local Grafana/Prometheus (`make obs-up`) | ✅ | `make obs-up` → `prometheus: 12 alert rules loaded (want 12)`, `grafana: credence-api credence-indexer credence-keeper credence-relayer`, `grafana → prometheus: OK`; `promtool test rules alerts.test.yml` → SUCCESS; every dashboard query validated against Prometheus |
| 8 | Report, with ADRs for every deviation | ✅ | This file; ADR-0009 (R-26), ADR-0011 (indexer state reads) |

## 3. What was built
- `packages/feeds` (`@credence/feeds`): R-26 readers covering RedStone package verification and the payload builder (the connector's rules), Chainlink AggregatorV3 and Pyth. `src/probe.ts` is the Sepolia probe (`make r26-probe`).
- `services/keeper/src/sigma.rs`: σ methodology v1 (exact f64), snapshot resume, publish rule.
  - `sigma_job.rs`: gaps from on-chain prints, EIP-712 `SigmaUpdate`, committee signing, planning.
  - `sigma_runner.rs`: J7 on the chain (indexed OPEN/CLOSE prints, engine σ and last `SigmaUpdated`, oracle `lastAsOfDay`, `SigmaOracle.submit`).
- `services/keeper/src/core.rs`: core bindings from `deployments/abis/v1`, a one-block risk context, the native Bell (risk-core at the engine's safe LTV, cures converted like the market), and the next two scheduled closures from the calendar.
  - `core_jobs.rs`: J2, J3 and J4 (dry-run with recorded plans; `KEEPER_J3_LIVE` / `KEEPER_J4_LIVE` flip them), J8, the allowlist sender.
  - `tasks.rs`: J12 `programTimeLeft` (ArbWasm) plus independent J12 checks.
- `packages/sdk`: v1 ABIs, v1 code tables, and `@credence/sdk/risk` (Bell, cures, quote, rates over `@credence/risk-wasm`). The address-book schema accepts null stacks.
- `indexer/`: S2 tables and handlers (`src/core.ts`); v0 + v1 `ReportAccepted`; `scripts/core-e2e.sh` and `scripts/bell-e2e.sh`.
- `services/api/src`:
  - `chain.ts`: one-block chain reader.
  - `sets.ts`: ADR-0106 set store keyed by `scenarioHash`.
  - `core.ts`: markets, positions, `/bell`, vault.
  - `me.ts`: notifications, email verification, allowlist.
  - `stream.ts`: the WS hub.
  - `metrics.ts`: `/metrics`.
- `services/api/scripts`: `engine-bell-e2e.ts` and `bell-market-e2e.ts`.
- `services/relayer`: `relayer_last_live_timestamp_seconds` and `relayer_market_status` gauges (FeedStale alert).
- `infra/prometheus/{prometheus.yml,alerts.yml,alerts.test.yml}`, `infra/grafana/{provisioning,dashboards}`, compose profile `obs`.
- `infra/db/migrations/20260928000002_api_s2.sql`: `app.allowlist_request`.
- `mk/backend.mk`: `r26-probe`, `keeper-sigma-test`, `keeper-j7-e2e`, `keeper-j12-e2e`, `keeper-core-e2e`, `indexer-core-e2e`, `api-engine-e2e`, `api-bell-e2e`, `api-db-test`, `obs-up` / `obs-down` / `obs-check`. `backend-install` builds `@credence/risk-wasm` into `target/be`.
- `.github/workflows/ts.yml`: builds risk-wasm before the pnpm install.

## 4. Test results
- Rust: keeper unit tests 16, `sigma_vectors` 8 (every QE vector block: gapReturn 6, classify 10, keeperResume 3 × 40 steps, publish 7, the snapshot, plan), relayer 64 + e2e; ignored e2e suites run by their make targets (section 2).
- TS: SDK 44, API 33 (+2 DB tests via `make api-db-test`), feeds 9, indexer 3, notifier 13 (+3 e2e). Calibration pytest (QE's, run by `backend-test`): 42 passed.
- `make backend-test` in the working tree at `93e08bb`: EXIT 0 (the clean-clone run of `e7ca05c` is in section 2).
- Engine equality: 100 / 100 positions, 0 mismatches (`api-engine-e2e`). Keeper vs market: exact at the job's block (`keeper-core-e2e`).
- Alerts: `promtool test rules`: 6 test groups, SUCCESS.

## 5. Deviations from the Build Guide
- **§10.3 "handlers are pure projections"** → market, position and vault rows are the contracts' own views read at the event's block. The reason: auto-cover and settlement change debt and collateral without their own events. → ADR-0011.
- **§10.2 J2 "compute bellStatus with risk-core natively"** → the Bell status and cures are native risk-core. The safe LTV comes from the engine's `safeLtv` view (the exact number the market uses), and the premium from the pool's `previewCover` (the exact amount the borrower is charged). J2 targets each of the next two scheduled closes from the calendar: the T−26 h heads-up for Friday is sent while Thursday night is the next closure.
- **ADR-0010 J2 dedupe key** `J2:<closureId>:<borrower>:<stage>` → `J2:<marketId>:<closureId>:<borrower>:<stage>`. Closure ids are per asset, so one borrower in two markets would collide.
- **J7 corporate actions**: split = 1, dividend = 0 (no corporate-action source on testnet in S2).
- **`/v1/vault/:stack`**: APY = the supply-weighted senior rate of the stack's markets over total assets (a current rate, not a trailing yield); `cushion` is null until the S3 pool.
- **WS `/v1/stream`** polls the indexer views every second (per API process) rather than subscribing to the chain; `auctions` and `bell:<owner>` come with S3.
- **R-26 public-testnet OPEN/CLOSE print source**: proposed deviation from §10.1 (ADR-0009 D1), pending a PM ruling.
- **`/bell` premium on local stacks**: the on-chain reference is `engine.quoteCover(…, uAfter)`, because the S2 stand-in pool quotes a fixed `COVER_PREMIUM`.

## 6. Spec issues found
- **§10.1 / R-26:** Pyth Core is no longer free for equities (Core upgrade, 2026-08-26: Hermes needs a key; US equities are $5,000/month), and its Sepolia equity prices stopped on that day. Chainlink Data Streams has no free tier. No free on-chain feed publishes the official auction open/close prints that §10.1's OPEN report assumes (ADR-0009).
- **§10.2 J2 "26 h before a binding close"** is ambiguous when another closure lies in between (Thursday night before Friday's close). Implemented as "each of the next two scheduled closes"; the amounts for the later one project the current debt over that closure's days.
- **§10.4 `/bell` "must equal the on-chain quoteCover"**: with a pool stand-in that quotes a fixed premium, the market's `bellStatus` premium is not the engine's; the equality has to be stated against `engine.quoteCover` with the pool's `uAfter`.
- **ADR-0010's J2 dedupe key** collides across markets (above).
- **The contracts emit no event** for the auto-cover premium added to debt, or for settlement's collateral and share changes (ADR-0011). Worth adding before mainnet so indexers can be pure projections.

## 7. Interfaces changed or published
- **API (versioned, OpenAPI at `/v1/openapi.json`):**
  - `GET /v1/markets`, `/v1/markets/{marketId}`, `/v1/positions/{owner}`, `/v1/positions/{marketId}/{owner}/bell`, `/v1/vault/{stack}`
  - `GET`/`PUT /v1/me/notifications`, `GET /v1/me/email/verify`, `POST /v1/testnet/allowlist`
  - WS `/v1/stream` (`clock`, `prices`)
  - `/metrics`
- **Indexer views (schema `indexer`):** `market`, `position`, `position_event`, `vault_state`, `vault_request`, `sigma_point`; `price_point.status` filled from v1.
- **DB:** `app.allowlist_request` (migration `20260928000002`).
- **SDK:** `@credence/sdk` on v1 ABIs; `@credence/sdk/risk`; `FeedMarketStatus`, `BellOutcome`, `MarketAction` code tables.
- **Keeper env:** `KEEPER_CORE`, `KEEPER_J3_LIVE`, `KEEPER_J4_LIVE`, `INDEXER_SCHEMA`, `SIGMA_COMMITTEE_KEYS`, `SIGMA_SNAPSHOT`, `SIGMA_ORACLE_ADDRESS`, `RISK_ENGINE_ADDRESS`. API env: `SCENARIO_DIRS`, `API_PUBLIC_URL`, `ALLOWLIST_ENABLED`, `ALLOWLIST_PER_IP_PER_HOUR`.
- **Metrics:** `relayer_last_live_timestamp_seconds`, `relayer_market_status`, `keeper_stylus_program_time_left_seconds`, `credence_api_http_*`.
- **Address book:** BE-backend reads only the nested §13.2 keys; the flat keys can go.

## 8. Known gaps and TODOs
- **Acceptance 4, market level:** `make api-bell-e2e`, after BE-chain's `DeployCoreLocal` on the devnode (their announced next step).
- **The keeper still uses its own `sol!` over `deployments/abis/v1`** (`services/keeper/src/core.rs::abi`) instead of `crates/credence-bindings`. It's the same ABIs, and the switch is an import change. J7 reads the last update time from `SigmaUpdated` logs; the new `sigmaAt` view (BE-chain C) can replace that.
- **`keeper-j7-e2e`** declares `initializeWiring(address)` locally until `ISigmaOracle.json` v1 carries it.
- **`/v1/markets`** shows `live: null` for a market whose valuation-price read reverts (no price yet); the indexed fields are still served.
- **J7 committee keys are local env keys**; KMS signers before testnet (§10.1 rule).
- **Scenario-A run** covers Friday only; the full week needs the S3 reopen driver (J5).
- **`bell-market-e2e.ts` sends `epochId: 0`** to the stand-in pool's `previewCover`; the S3 pool may need the real one (exposed by `/bell` if so).
- The **S1 devnode feed** still emits the v0 `ReportAccepted` (status null) until BE-chain redeploys the clock stack.

## 9. Needs from the user or the PM
- **Rotate the free vendor keys** pasted into chat in S1 (Massive dashboard → Keys; Alpaca Paper → API Keys → Regenerate) and update `.env`.
- **ADR-0009 decisions:**
  - **D1:** OPEN/CLOSE print source for a public testnet.
  - **D2:** COIN/SPY are not on RedStone (ask RedStone, or swap tickers, which means a QE recalibration).
  - **D3:** written confirmation from RedStone that relaying to a public testnet is permitted (site terms, BUSL-1.1 connector).
- **Before testnet:** KMS keys for the σ committee (J7) and the keeper.

## 10. How to verify from a clean checkout
```sh
make backend-install backend-build backend-test backend-lint
make keeper-sigma-test                  # QE σ vectors, bit for bit
make r26-probe                          # needs internet: RedStone/Chainlink/Pyth on Arbitrum Sepolia
make infra-up db-migrate                # Postgres + nitro devnode (BE-chain's engine + QE bundle on it)
make relayer-e2e keeper-e2e notifier-e2e api-db-test
make keeper-core-e2e indexer-core-e2e   # DeployCoreLocal on scratch anvils
make keeper-j7-e2e keeper-j12-e2e api-engine-e2e indexer-e2e   # devnode
make obs-up                             # Prometheus :9090, Grafana :3001
# once BE-chain posts DeployCoreLocal on the devnode:
make api-bell-e2e
```
