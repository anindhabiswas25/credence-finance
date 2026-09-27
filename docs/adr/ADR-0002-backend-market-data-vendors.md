# ADR-0002 · Market-data vendors: Polygon.io (Massive) for feed A, Alpaca for feed B

Status: accepted for testnet engineering; **licensing open (see "Redistribution")** · Role: BE-backend · Date: 2026-09-27 · Guide §3.3, §10.1

## Decision
| Feed | Vendor | Why |
| --- | --- | --- |
| A | **Polygon.io**, rebranded **Massive** in 2026 (`api.polygon.io` unchanged) | Consolidated SIP trades and quotes, condition-code metadata (`/v3/reference/conditions`) with CTA/UTP mappings, official open/close endpoint, market status |
| B | **Alpaca Market Data v2** | An independent SIP pipeline and company. Raw CTA/UTP condition codes. `iex` feed on the free plan, `sip` on Algo Trader Plus |

The two vendors run on different infrastructure and keys, so the on-chain A/B cross-check is meaningful (§10.1). Both adapters implement `MarketDataVendor` (LIVE / OPEN / CLOSE / STATUS), and a third, the **replay** vendor, serves dev and tests.

**Single-stock halts** (STATUS) come from the **Nasdaq Trader trade-halt feed** (`rss.aspx?feed=tradehalts`). It is public, covers halts and LULD pauses in every US-listed security, and has reason codes and resumption times. Neither vendor offers a REST halt endpoint (Polygon publishes LULD over WebSocket only; Alpaca's `statuses` stream needs SIP). Both feeds therefore share the halt source. That is acceptable because a halt only makes the clock *more* restrictive (fail closed).

**Trade eligibility** is classified by SIP sale-condition code (CTA/UTP), with the plan taken from the trade's tape. A trade is a regular LIVE print only if every code updates the consolidated last sale. Form T (`T`) is extended-hours only. Official open/close are `Q` / `M` **from the primary listing exchange**. Unknown codes are ineligible. Polygon's numeric ids are mapped through its conditions endpoint at start-up, with a built-in reference table as the fallback. That table was checked against Polygon's recorded conditions response.

**OPEN / CLOSE** come from the listing exchange's condition-coded auction print (`Q` / `M`) with its exchange timestamp. If the plan does not include trades (free tiers), the fallback is the vendor's official daily open/close, timestamped at the scheduled session open/close (`PrintSource::DailyBar`).

## Plans and limits
| | Free tier (keys the user is providing for S1) | Production (testnet launch) |
| --- | --- | --- |
| Polygon/Massive | Basic: 5 requests/min, reference + end-of-day. No real-time trades/NBBO (`NotEntitled`) | Stocks **Advanced** ($199/mo) for real-time SIP trades + quotes, or a **Business** plan (see below) |
| Alpaca | Basic: real-time **IEX only**; SIP history older than 15 min | **Algo Trader Plus** ($99/mo) for full SIP, or a data-redistribution agreement |

With free keys, the live smoke test (`make relayer-smoke VENDOR=polygon|alpaca`) proves authentication, parsing and entitlements. It cannot prove SIP-quality LIVE prices.

## Redistribution (must be resolved before public testnet)
Publishing prices on a public chain is **redistribution / customer-facing display**:
- Massive/Polygon **individual plans (Basic → Advanced) are licensed for personal, non-professional use only**. Redistribution or customer-facing display requires a **Business plan** (https://massive.com/business-stocks).
- Alpaca's Algo Trader Plus market data is **"only for personal use"** (https://alpaca.markets/elite). Redistribution needs a separate agreement with Alpaca (Broker/enterprise data).

So Sprint 1 uses these feeds only on local chains. Before relayers publish to Arbitrum Sepolia, the PM/user must sign business/redistribution terms with both vendors (or swap one for Databento or Nasdaq Basic under a redistribution licence). The adapters are behind `MarketDataVendor`, so a vendor swap is a new adapter and a config change.

## Consequences
- The relayer runs unchanged across free → paid → business tiers. Only keys and `ALPACA_FEED=sip` change.
- Rate limits are enforced client-side (`POLYGON_MAX_RPM`, `ALPACA_MAX_RPM`).
