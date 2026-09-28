# ADR-0009 · R-26: on-chain-licensed equity feeds for the public testnet

Status: **proposed** (needs a PM ruling on three points in "Decisions needed") · Sprint 2 · Owner: BE-backend · Guide R-26, §10.1 · Supersedes the "Redistribution" section of ADR-0002 for public deployments

## Context
R-26 makes market-data licensing a launch gate for any public deployment. The free vendor keys (Massive Basic, Alpaca Basic) are personal-use only (ADR-0002). The user will not buy a data plan (PM ANSWER 11:45), so the recommendation must favour feeds that are **already licensed for on-chain publication and free to use**. The candidates were Pyth, RedStone and Chainlink, each checked on Arbitrum Sepolia (421614) for the six testnet tickers (NVDA, AAPL, TSLA, COIN, MSFT, SPY) and for these properties:
- market-hours and status semantics;
- a regular-session **opening print** with a verifiable timestamp (§10.1 OPEN, used as the reopen reference);
- the update model, latency, cost and terms.

## Evidence (measured 2026-09-28 07:22–07:31 UTC, a Monday before the open)
Re-run: `make r26-probe` (writes `target/be/r26/probe.json`). The reader lives in `packages/feeds` (`@credence/feeds`), and its offline tests are in `make backend-test`.

| | RedStone `redstone-primary-prod` (pull) | Chainlink push Data Feeds | Chainlink Data Streams | Pyth Core |
| --- | --- | --- | --- | --- |
| NVDA / AAPL / TSLA / MSFT | ✅ all four | ❌ not on Sepolia (✅ on Arbitrum One) | testnet stream ids exist (`…RegularHoursEquityPrice-testnet-production`, v11) | ids exist, but the **Sepolia price is frozen at 2026-08-26 16:10 UTC** (32.6 days old) |
| COIN | ❌ not listed | ❌ Sepolia (✅ Arbitrum One) | ✅ id | frozen since 2025-11-21 |
| SPY | ❌ (only the `USA500.Y` index) | ✅ **`SPY / USD` `0x4fB4…0b06`**: 771.3425, updated 2026-09-27 16:18 UTC (24 h heartbeat). Friday's official close was 771.35 | ✅ id | frozen since 2026-06-01 |
| Access | Public gateway, **no key**: `oracle-gateway-{1,2}.a.redstone.finance/data-packages/latest/redstone-primary-prod` | Free on-chain `latestRoundData` | HMAC API key; **paid only, no free tier**; testnet on request | Hermes returns **HTTP 401** without a key (Core upgrade, completed 2026-08-26) |
| Trust model | 5 authorised signers, threshold 3, median (hard-coded in `PrimaryProdDataServiceConsumerBase`) | DON, push on 0.5% deviation or 24 h heartbeat | DON report + on-chain verifier | Wormhole-attested |
| Verified on Sepolia | ✅ RedStone's own Solidity verifier accepted a 12-package payload on Sepolia state (`eth_call` with a state override, block 313,535,159); **a tampered value reverts** | ✅ direct read | not run (no credentials) | ✅ read (stale) |
| Sessions | Separate feeds: `<T>` (regular), `<T>---PRE_AFTER`, `<T>---EXTENDED`, `<T>---24_7` | Regular hours only | Regular, extended and overnight streams; `marketStatus` 0–5 in each report | Regular only on Core (session feeds moved to Pro on 2026-06-15) |
| Market status in the data | ❌ none. The package timestamp is the **signing time** (every 10 s, also while closed) | ❌ | ✅ `marketStatus` | ✅ Hermes `market_hours` metadata (still public) |
| Official open/close print with an exchange timestamp | ❌ | ❌ | ❌ (Chainlink: "no single consolidated order book") | ❌ |
| Closed-market value vs Friday's official close (Alpaca SIP daily bar) | NVDA 225.0415 vs 225.07; AAPL 341.0324 vs 341.07; TSLA 372.0800 vs 372.11; MSFT 516.1326 vs 516.17 (about −1 bp: the last regular price, not the closing auction) | SPY 771.3425 vs 771.35 | n/a | n/a |

Notes on the evidence:
- **Pyth.** Since the Core upgrade, "accessing any Pyth Price Feeds API will require a Pyth data plan, which start at $500 per month", and US equities are in the $5,000/month Pro plan. The Sepolia contract still answers, but nobody pushes equity updates to it.
- **RedStone.** Coverage is NVDA, AAPL, TSLA, MSFT, AMZN, GOOGL and META; COIN and SPY are missing. The website terms forbid commercial use of "the Site and/or the Content" without written permission. The on-chain connector (`@redstone-finance/evm-connector` 1.0.0) is **BUSL-1.1** (`data-services/*.sol`). That is why the probe fetches it at run time into `target/` and never commits it.
- **Chainlink.** On Sepolia the only equity push feed is SPY/USD. Arbitrum One has push feeds for all six tickers (86,400 s heartbeat, 0.5% deviation).

## Decision (recommendation)
1. **Public testnet primary price: RedStone pull, `redstone-primary-prod`.** It is the only free option that covers most of the tickers, signs every 10 s, and is verifiable on Arbitrum Sepolia today with no key. Integration:
   - An on-chain adapter `RedStonePriceSource : IPriceSource` (BE-chain, REQUEST below) verifies the RedStone payload with the connector's rules: 3 of 5 signers, a 3 min delay window and a 1 min ahead window.
   - The relayer gains a `redstone` mode. It fetches the packages, verifies them off-chain first (`@credence/feeds` `aggregate`, same rules), and submits the payload to the adapter. It relays RedStone's own signed data and signs nothing itself, so Credence does not redistribute vendor data.
   - Session mapping: REGULAR LIVE comes from `<T>`, EXTENDED/overnight LIVE from `<T>---EXTENDED` (fallback `---PRE_AFTER`), selected by the on-chain clock state, not by the package timestamp.
2. **Relayer on the free vendor keys = monitoring shadow only** (§10.1 allows this). It keeps computing A/B observations off-chain, compares them with RedStone every tick, and pages ops (Prometheus alert `FeedDisagreement`) if they differ by more than 0.5%. It **never publishes** on a public chain. Local and devnode use of the free keys is unchanged (R-26).
3. **Chainlink push feeds as a sanity bound, not a price.** On Sepolia this covers SPY only. On Arbitrum One all six can serve as a mainnet secondary: a deviation guard, or a circuit breaker if RedStone and Chainlink differ by more than the 0.5% deviation threshold plus a margin. They cannot drive LIVE, because of the 24 h heartbeat.
4. **Pyth is rejected** for testnet (paid since 2026-08-26, and the Sepolia prices are frozen). It stays in the cost table.
5. **Chainlink Data Streams** is the best technical fit for mainnet (`marketStatus`, all sessions, all six tickers), but it is paid. It goes in the cost table for the mainnet licensing decision.

## Decisions needed (PM / user)
- **D1 · OPEN and CLOSE prints.** No free on-chain feed publishes the official auction prints with an exchange timestamp. Proposal for the public testnet only: OPEN = the first RedStone `<T>` package signed at or after `open + 5 s` whose value differs from the previous close value. It is timestamped with the package time and flagged as `PrintSource::OracleFirstRegular`. CLOSE = the last `<T>` package before `close + 60 s`. This deviates from §10.1 ("official opening auction print"), so it needs a PM ruling. Mainnet needs a licensed official-print source.
- **D2 · COIN and SPY.** RedStone does not list them. Options: (a) ask RedStone to list them (free to ask); (b) swap the testnet equity set for covered names (for example GOOGL and AMZN), which means QE recalibrates the sets (`make cal-all` with new tickers); (c) list COIN and SPY on the testnet without a live feed (market paused). Recommendation: **(a), with (b) as the fallback**; SPY can use the Chainlink push feed as a bound meanwhile.
- **D3 · RedStone terms.** The site terms reserve commercial use, and the connector is BUSL-1.1. A public testnet is non-commercial, but ask RedStone for **written confirmation** that relaying `redstone-primary-prod` to a public Arbitrum Sepolia deployment is permitted, and for the adapter's licence grant. This is free, and it gates the public testnet. Mainnet needs a commercial agreement.
- **STATUS** needs no new source: the clock state comes from the on-chain calendar (AssetClock), and single-stock halts from the public Nasdaq Trader halt feed (ADR-0002). Neither is vendor-licensed price data.

## Cost table (list prices on 2026-09-28; paid plans for the later licensing decision only)
| Option | Covers | Price | Licence for on-chain publication | Source |
| --- | --- | --- | --- | --- |
| RedStone pull, public gateway | NVDA, AAPL, TSLA, MSFT (+AMZN, GOOGL, META), all sessions | **$0** | Designed for on-chain use; written confirmation pending (D3) | probe; redstone.finance/terms-of-use |
| RedStone commercial (push feeds, SLA, new assets) | on request | contact sales | yes | redstone.finance/price-feeds |
| Chainlink push Data Feeds (read) | Sepolia: SPY; Arbitrum One: all six | **$0** to read | yes | reference-data-directory; probe |
| Chainlink Data Streams | all six, regular/extended/overnight, `marketStatus` | from **$150 per stream per month**; no free tier; 6 tickers × 3 sessions ≈ 18 streams ≈ $2,700/month list before bundle discounts | yes | docs.chain.link/data-streams/sign-up |
| Pyth Pro, US Equities | all six, all sessions | **$5,000/month** (All asset classes $10,000; Starter $500 excludes equities) | yes | pyth.network/blog/the-pyth-core-upgrade |
| Massive (Polygon) individual plans | SIP | $0–$199/month | **no** (individual use only) | massive.com/pricing |
| Massive Business | SIP, business use | business pricing (Stocks Business $2,499/month per QE's 02:40 board entry); redistribution on request | on request | massive.com/business-stocks |
| Alpaca Algo Trader Plus | SIP | $99/month | **no** (personal use) | alpaca.markets (ADR-0002) |
| Alpaca data redistribution | SIP | contact sales | on request | ADR-0002 |

## Consequences
- Local and devnode work is unchanged: the relayer keeps publishing replay or free-key data into `CredencePriceFeed` on 412346.
- **REQUEST to BE-chain (S3, not blocking S2):** `RedStonePriceSource : IPriceSource`, with the connector rules above and the 8-decimal to WAD scaling. Licence permitting (D3), it inherits RedStone's consumer base; otherwise it is a clean-room verifier of the documented payload format. `packages/feeds/src/redstone.ts` and its test fixture are the reference for the byte layout.
- The Prometheus alert `FeedDisagreement` compares the shadow relayer with the published price (see `infra/prometheus/alerts.yml`).
- Session behaviour at the open (how quickly `<T>` moves after 09:30 ET, and whether `---EXTENDED` stops at 20:00 ET) was not measured, because the probe ran before the open. Re-run `make r26-probe` during a session before D1 is ruled on.

## Sources
- Pyth: https://www.pyth.network/blog/the-pyth-core-upgrade · https://www.pyth.network/blog/extended-hours-us-equity-data-moves-to-pyth-pro · https://docs.pyth.network/price-feeds/core/upgrade/preparing · https://docs.pyth.network/price-feeds/core/market-hours
- RedStone: https://docs.redstone.finance/docs/dapps/redstone-pull/ · https://www.redstone.finance/price-feeds/ · https://www.redstone.finance/terms-of-use · npm `@redstone-finance/evm-connector` 1.0.0 (`contracts/data-services/PrimaryProdDataServiceConsumerBase.sol`)
- Chainlink: https://docs.chain.link/data-streams/rwa-streams/24-5-us-equities-user-guide · https://docs.chain.link/data-streams/market-hours · https://docs.chain.link/data-streams/sign-up · https://reference-data-directory.vercel.app/feeds-ethereum-testnet-sepolia-arbitrum-1.json · https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json
- Massive: https://massive.com/pricing · Alpaca / Massive redistribution: ADR-0002
