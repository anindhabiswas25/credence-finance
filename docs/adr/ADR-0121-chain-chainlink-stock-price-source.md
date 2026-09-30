# ADR-0121 · BE-chain · A Chainlink price source for Robinhood Stock Tokens (mainnet only)

Status: accepted (S5, Amendment 1 point 6) · Date: 2026-09-30

## Context
On Robinhood Chain mainnet (4663) every Stock Token has a Chainlink feed. The Chainlink feed directory
(`reference-data-directory.vercel.app/feeds-robinhood-mainnet.json`) lists 58, e.g. "Robinhood TSLA / USD"
`0x4A1166a659A55625345e9515b32adECea5547C38`: 8 decimals, heartbeat 86,400 s, deviation 0.5 %, market hours
`us_equities_24/5`. Chainlink defines the price as the token's total-return value: underlying price × the token's
ERC-8056 `uiMultiplier`. While the market is closed the feed "may hold the last published price". Chainlink lists these
feeds on mainnet only, so the testnet keeps the relayer feeds.

Recorded (read-only, 800 rounds, 2026-07-29 → 2026-09-30): the median time between rounds is 21 min in trading hours.
Over each weekend the feed holds its price well past the 24 h heartbeat: Friday ~19:00Z to Monday 00:00Z, and 77.8 h
over Labor Day. It resumes at Monday 00:00Z, the start of the overnight session.

## Decision
`ChainlinkStockPriceSource : IPriceSource`, one contract per venue (the calendar store and venue are immutable), with
feeds wired per asset by the timelock (`setFeed(asset, aggregator, token, maxAge)`).
- **Unit.** `IPriceSource` prices are WAD per share, so the source returns answer × 10^(18 − decimals) ÷ the token's
  live multiplier. The token price is continuous across a corporate action, so this is right whether or not the feed
  has printed since. The adapter multiplies back with its cached multiplier, and ADR-0119's corporate-action rules
  apply unchanged.
- **Freshness.** A push feed only prints on 0.5 % deviation or its heartbeat. A round younger than `maxAge` (the
  heartbeat) is reported as current (`observedAt` = now): the true price is within 0.5 % of it. An older round keeps
  its own time, so the adapter sees it stale.
- **Market status** comes from the venue calendar (REGULAR / PRE / POST / CLOSED), not from the feed.
- **Official prints** (Chainlink has none; ADR-0009 D1's rule):
  - `officialOpen`: the first round within 30 min of the regular open, else not ok, and the adapter falls back to its
    TWAP;
  - `officialClose` / `lastRegular` (outside regular hours): the round in force at the last regular close;
  - `twap`: time-weighted over rounds.

  Each walks back at most 64 rounds of the current aggregator phase, which is about a trading day.
- **Not deployed on testnet.** It is exported in ABIs v4 for the mainnet deploy. A mainnet equity stack would pair it
  (primary) with the relayer feed (secondary) for the adapter's cross-check.

## Consequences
- A quiet open (no round in the first 30 min, because the price moved < 0.5 %) takes the adapter's TWAP fallback.
- `maxAge` = heartbeat means a feed that stops updating in regular hours is treated as live for up to 24 h. On mainnet
  the relayer secondary is what catches it: > 1.5 % disagreement pauses borrowing, > 5 % halts. The keeper's
  staleness alert (Engineer B) should page on a round older than ~1 h in regular hours.

## Tests
`contracts/test/unit/ChainlinkStockPriceSource.t.sol`, with the 800 recorded rounds
(`test/fixtures/chainlink/rhtsla-rounds.json`) and an XNYS calendar for those weeks:
- regular-hours freshness and the per-share unit, including after a 2:1 split;
- the Labor Day weekend: the held price is stale and the official close is Friday's;
- three recorded opens;
- the TWAP against an independent computation.
