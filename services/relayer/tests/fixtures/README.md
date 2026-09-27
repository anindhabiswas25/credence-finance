# Recorded vendor responses

These are real response bodies used by the adapters' recorded-response tests (`cargo test -p credence-relayer`).

| Directory | Source | Licence |
| --- | --- | --- |
| `polygon/` | `polygon-io/client-python` (now `massive`) `test_rest/mocks/` at `master` (Sep 2026) | MIT |
| `alpaca/` | `alpacahq/alpaca-py` `tests/` at `c803f2d` (bodies copied verbatim from the request mocks) | Apache-2.0 |
| `nasdaq/tradehalts.xml` | `https://www.nasdaqtrader.com/rss.aspx?feed=tradehalts`, fetched 2026-09-27 16:14 UTC | public feed |
| `replay/` | sessions recorded with `credence-relayer record` (see `replay/README.md`) | vendor terms, ADR-0002 |

A live check with your own keys: `VENDOR=polygon credence-relayer smoke --out smoke-polygon.json` (see the sprint report).
