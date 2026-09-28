# Scenario sets (alpaca, data grade `free-2016`, through 2026-09-25)

Pooling rule and its effect on the tail: ADR-0203. Tail floor (the more severe of history and the t₃ stand-in below the 2.5% quantile): ADR-0204. z in thousandths of σ; i* = ceil(α N) − 1 at α = 0.1%.

| Asset | Closure | N | Pool | z at i* (set) | pooled history | t₃ | values moved by t₃ | min (set) | own N | z at α (own only) | min (own) | padded with weekend | File |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| NVDA | OVERNIGHT | 3000 | 32816 | -11144 | -11144 | -6276 | 0 | -16430 | 2051 | -3961 | -10068 | — | `NVDA-OVERNIGHT-cd955235876e28b1.json` |
| NVDA | WEEKEND | 3000 | 7552 | -7208 | -7208 | -6276 | 1 | -10802 | 472 | -8500 | -8500 | — | `NVDA-WEEKEND-7345c100a18da486.json` |
| NVDA | HOLIDAY_WEEKEND | 1472 | 1472 | -5860 | -5021 | -5860 | 2 | -8502 | 92 | -5355 | -5355 | — | `NVDA-HOLIDAY_WEEKEND-d593bb22b4517be1.json` |
| AAPL | OVERNIGHT | 3000 | 32816 | -11144 | -11144 | -6276 | 0 | -16430 | 2051 | -10421 | -10647 | — | `AAPL-OVERNIGHT-4af07b67372d0270.json` |
| AAPL | WEEKEND | 3000 | 7552 | -7208 | -7208 | -6276 | 1 | -10802 | 472 | -9318 | -9318 | — | `AAPL-WEEKEND-877bfe7915500b04.json` |
| AAPL | HOLIDAY_WEEKEND | 1472 | 1472 | -5860 | -5021 | -5860 | 2 | -8502 | 92 | -5021 | -5021 | — | `AAPL-HOLIDAY_WEEKEND-e1f8ace37d81d5da.json` |
| TSLA | OVERNIGHT | 3000 | 17171 | -9375 | -9375 | -6276 | 0 | -16496 | 2051 | -7607 | -9859 | — | `TSLA-OVERNIGHT-3cd959be03369e55.json` |
| TSLA | WEEKEND | 3000 | 3947 | -7208 | -7208 | -6276 | 0 | -11549 | 472 | -3968 | -3968 | — | `TSLA-WEEKEND-cc7795e6a35bef32.json` |
| TSLA | HOLIDAY_WEEKEND | 3000 | 4711 | -7324 | -7324 | -6276 | 0 | -11549 | 92 | -4805 | -4805 | TSLA, COIN, MSTR, MARA, RIOT, HOOD, PLTR, SHOP, ROKU, AMD, NFLX | `TSLA-HOLIDAY_WEEKEND-85eb16263ae2f79c.json` |
| COIN | OVERNIGHT | 3000 | 17171 | -9375 | -9375 | -6276 | 0 | -16496 | 1011 | -6561 | -11529 | — | `COIN-OVERNIGHT-8a1c5c50a66ae925.json` |
| COIN | WEEKEND | 3000 | 3947 | -7208 | -7208 | -6276 | 0 | -11549 | 232 | -8515 | -8515 | — | `COIN-WEEKEND-0df02d23518e0de1.json` |
| COIN | HOLIDAY_WEEKEND | 3000 | 4711 | -7324 | -7324 | -6276 | 0 | -11549 | 43 | -2348 | -2348 | COIN, TSLA, MSTR, MARA, RIOT, HOOD, PLTR, SHOP, ROKU, AMD, NFLX | `COIN-HOLIDAY_WEEKEND-5516f094d544c85a.json` |
| MSFT | OVERNIGHT | 3000 | 32816 | -11144 | -11144 | -6276 | 0 | -16430 | 2051 | -6665 | -11408 | — | `MSFT-OVERNIGHT-41f84cb1e8cfcd20.json` |
| MSFT | WEEKEND | 3000 | 7552 | -7208 | -7208 | -6276 | 1 | -10802 | 472 | -7528 | -7528 | — | `MSFT-WEEKEND-e0ab2e8fc534249e.json` |
| MSFT | HOLIDAY_WEEKEND | 1472 | 1472 | -5860 | -5021 | -5860 | 2 | -8502 | 92 | -4667 | -4667 | — | `MSFT-HOLIDAY_WEEKEND-55683710aa49c943.json` |
| SPY | OVERNIGHT | 3000 | 24612 | -6276 | -5994 | -6276 | 7 | -10802 | 2051 | -4841 | -8421 | — | `SPY-OVERNIGHT-d0c1fb2261401c7b.json` |
| SPY | WEEKEND | 3000 | 5663 | -6276 | -6121 | -6276 | 1 | -11084 | 472 | -6121 | -6121 | — | `SPY-WEEKEND-20b2b22679a49359.json` |
| SPY | HOLIDAY_WEEKEND | 1104 | 1104 | -5311 | -4404 | -5311 | 4 | -7716 | 92 | -2913 | -2913 | — | `SPY-HOLIDAY_WEEKEND-0c293541a41daab2.json` |

## Joint stress set (`joint-0eb9ef497f13a9cc.json`)

K = 256 worst of 564 non-overnight closures (2016-04-25 → 2026-09-21), ranked by synthetic stress closures first (ADR-0204), then historical closures by equal-weighted mean z of the six assets, ascending (worst first). Back-fill: OLS through the origin of z_a on z_SPY over non-overnight closures where both exist.

| Asset | β to SPY (z) | back-filled closures |
| --- | ---: | ---: |
| NVDA | 0.807 | 0 |
| AAPL | 0.813 | 0 |
| TSLA | 0.539 | 0 |
| COIN | 0.786 | 289 |
| MSFT | 0.843 | 0 |

Synthetic stress closures (ADR-0204): POT/GPD return levels of the historical basket z; GPD over the worst 10% of basket z (57 exceedances, ξ = 0.2872, scale 0.6551, 54.2 closures/year, worst observed −6.7344). Shapes: the worst historical closure (2024-08-05) scaled, and all assets equal.

| Horizon | years | closures | basket z |
| --- | ---: | ---: | ---: |
| since2000 | 26.72 | 1448.2 | -8.16 |
| 40y | 40.0 | 2167.9 | -9.33 |

Worst ten:

| # | Reopen session | Closure | basket mean z |
| ---: | --- | --- | ---: |
| 1 | SYN-40y-worstHistorical | SYNTHETIC | -9.330 |
| 2 | SYN-40y-uniform | SYNTHETIC | -9.330 |
| 3 | SYN-since2000-worstHistorical | SYNTHETIC | -8.160 |
| 4 | SYN-since2000-uniform | SYNTHETIC | -8.160 |
| 5 | 2024-08-05 | WEEKEND | -6.734 |
| 6 | 2020-02-24 | WEEKEND | -4.484 |
| 7 | 2020-03-09 | WEEKEND | -4.237 |
| 8 | 2020-09-08 | HOLIDAY_WEEKEND | -3.909 |
| 9 | 2020-03-16 | WEEKEND | -3.593 |
| 10 | 2020-01-27 | WEEKEND | -3.087 |
