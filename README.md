# Credence Finance
<img width="2850" height="1566" alt="Screenshot from 2026-09-29 01-25-13" src="https://github.com/user-attachments/assets/f926883d-a0be-42ec-9344-c82c63b902e6" />

A lending protocol for tokenized stocks and tokenized Treasury funds that follows each asset's market clock.

Stocks stop trading when their market closes, and Treasury funds price once a day. Lending protocols built for ETH assume a live price always exists, so they either liquidate on stale weekend prices or leave lenders silently carrying the Friday-to-Monday gap. Credence instead tracks every asset's market state, makes loans weekend-safe before the close (or insured), prices the reopen gap and sells it to a first-loss underwriter pool, and clears liquidations at the open in one uniform-price auction instead of a bot race.

> **Status:** live on testnet. Not audited. Do not use with real funds.

## How it works

| # | Mechanism | What it does |
| --- | --- | --- |
| 1 | **Asset Clock** | Tracks each asset's market state: open, extended hours, closed, halted, reopening |
| 2 | **Bell Check** | Before every close, each loan must be at a weekend-safe LTV or be insured |
| 3 | **Gap Cover + Underwriter Pool** | A first-loss pool sells insurance on the reopen gap and absorbs bad debt first |
| 4 | **Reopen Batch Auction** | Liquidations at the open clear in one uniform-price auction |
| 5 | **Settlement Adapter** | Treasury-fund collateral is liquidated through solvers who pay cash now and wait out redemption |

Only the Solidity money contracts (market, senior vault, underwriter pool, auction house) hold funds. All risk math (scenario pricing, capacity checks, auction clearing) runs in a Stylus (Rust) Risk Engine, which is a pure function and cannot move tokens. Inputs fail closed: if the clock, oracle or calendar disagree, the asset is treated as closed. Keepers are untrusted; every keeper action is checked on-chain.

The full design is in [`docs/Architecture.md`](docs/Architecture.md), and the binding implementation spec is [`docs/CREDENCE_BUILD_GUIDE.md`](docs/CREDENCE_BUILD_GUIDE.md). For a walk through one real week of money moving through the protocol, read [`docs/One week of money flow.md`](docs/One%20week%20of%20money%20flow.md).

## Deployments (testnet)

Two stacks run the same code, with no bridge between them.

| Stack | Chain | Chain ID | Markets |
| --- | --- | --- | --- |
| Equity | Robinhood Chain testnet | 46630 | AAPL, AMZN, GOOGL, MSFT, NVDA, TSLA, RHTSLA |
| NAV (Treasury funds) | Arbitrum Sepolia | 421614 | TBILL |

Key addresses:

| Contract | Equity (46630) | NAV (421614) |
| --- | --- | --- |
| Market | `0xe58B9870401A4dB8dc340AF8c4A85c12142f62Bf` | `0x22e66634001A266f279bC78816Df40229750d499` |
| Senior Vault | `0x149511106E3A2E9bA12a89e4b4b01F3d596fD7E8` | `0x7897570De25fb2355FA923dd70B827451159DFa7` |
| Underwriter Pool | `0x228236ED9BE9f7AF935412Db00d9A970Ef2944C6` | `0xEed693B799D807dC9d3a999538f98C9b4395cE52` |
| Auction House / Solver Auction | `0x053Bb76ca3b17A3A17966e519A79f9Cd81853032` | `0xF8De6bB7Df23EdDc6Ee34f5c6cb7EBF76Ce2c52E` |
| Risk Engine | `0xe5b94BF0e2C7Bb6ae0FC72ce1Fd42E07e84241C0` | `0x281374dD4E960E2Dbaf51B70Bcf997CD70787E50` |
| Asset Clock | `0x5EdBBd24554E699a47878951352d723667CF4615` | `0x28Cf4885D2B00971A0550509b85cD262c40C1Fa1` |
| Faucet | `0x8FBAefaFb49575c497eC42d9763e8F3F277821B8` | `0xf707aE5c681849EBE13697bD28bE36F28fD60C48` |

The complete address books, including tokens, Stylus programs and governance, are in [`deployments/46630.json`](deployments/46630.json) and [`deployments/421614.json`](deployments/421614.json). ABIs are in [`deployments/abis/`](deployments/abis/).

## Repository layout

| Path | What it is |
| --- | --- |
| [`contracts/`](contracts/) | Solidity contracts (Foundry): market, vault, pool, auction house, clock, oracle, settlement, governance |
| [`stylus/`](stylus/) | Stylus Risk Engine and auction math, plus a differential harness against the native core |
| [`crates/risk-core`](crates/risk-core/) | `no_std` fixed-point risk math shared by Stylus, the keeper, the CLI and calibration |
| [`crates/`](crates/) | `risk-core` for the CLI, Python (PyO3) and WASM, plus contract bindings and shared service plumbing |
| [`services/relayer`](services/relayer/) | Price relayer: licensed equity data → 2-of-3 signed EIP-712 reports → on-chain price feed |
| [`services/keeper`](services/keeper/) | Calendar-driven keeper jobs with Postgres idempotency, leader election and RPC failover |
| [`services/api`](services/api/) | Public API (Hono, Node 24), OpenAPI at `/v1/openapi.json` |
| [`services/notifier`](services/notifier/) | Notification queue consumer: email, Web Push, Telegram |
| [`services/bidder`](services/bidder/) | Test bidder bot so local auctions clear without a human |
| [`indexer/`](indexer/) | Ponder indexer for clock state, transitions and prices |
| [`apps/web`](apps/web/) | Web app (Next.js, wagmi, RainbowKit) |
| [`packages/sdk`](packages/sdk/) | TypeScript SDK: ABIs, typed address book, EIP-712 report builder, risk-wasm helpers |
| [`calibration/`](calibration/) | Historical backtest that calibrates the gap tables and risk parameters |
| [`infra/`](infra/) | Docker Compose stacks, Postgres migrations, Prometheus, Grafana |
| [`docs/`](docs/) | Architecture, build guide, ADRs, runbooks, security, QA, team and handoff notes |

## Getting started

Prerequisites: Rust 1.95 (pinned in `rust-toolchain.toml`; rustup installs it automatically), Node 24+, pnpm 10, Foundry and Docker.

```bash
pnpm install
make help                 # every target, with a one-line description
```

Contracts and risk math:

```bash
make contracts-build
make contracts-test
make risk-test            # risk-core unit tests
make stylus-test
```

Local stack (Postgres + Nitro devnode with Stylus on `:8547`):

```bash
make infra-up
make db-migrate
make local-deploy-core
make services-up          # relayer + keeper
```

Web app:

```bash
cd apps/web
cp .env.example .env.local
pnpm dev
```

Running the full testnet service stack locally (`make testnet-up`) needs RPC and signer secrets; see `make ops-secrets-init` and [`docs/runbooks/`](docs/runbooks/).

## License

MIT. See [LICENSE](LICENSE).
