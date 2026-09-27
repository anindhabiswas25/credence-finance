# Recorded vendor responses

These are real response bodies used by the adapters' recorded-response tests (`cargo test -p credence-relayer`).

| Directory | Source | Licence |
| --- | --- | --- |
| `polygon/` | `polygon-io/client-python` (now `massive`) `test_rest/mocks/` at `master` (Sep 2026) | MIT |
| `alpaca/` | `alpacahq/alpaca-py` `tests/` at `c803f2d` (bodies copied verbatim from the request mocks) | Apache-2.0 |
| `nasdaq/tradehalts.xml` | `https://www.nasdaqtrader.com/rss.aspx?feed=tradehalts`, fetched 2026-09-27 16:14 UTC | public feed |
| `replay/XNYS-20260925-close-NVDA-AAPL-iex.jsonl` | **Real** session: Alpaca IEX history, Fri 2026-09-25 15:45–16:05 ET, NVDA + AAPL. All 5,947 trades; quotes thinned to 1 per 500 ms per symbol. Recorded with `credence-relayer record --start 2026-09-25T15:45:00-04:00 --end 2026-09-25T16:05:00-04:00` | Alpaca terms (personal use; test fixture only, ADR-0002) |

A live check with your own keys: `make relayer-smoke VENDOR=polygon` / `VENDOR=alpaca`. Record another window with `VENDOR=alpaca credence-relayer record --start … --end … --out …` (IEX on the free plan, SIP with `ALPACA_FEED=sip`). IEX recordings have no `Q`/`M` official prints, because IEX is not the listing exchange.
