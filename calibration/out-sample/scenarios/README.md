# Scenario sets (sample, data grade `synthetic`, through 2023-12-29)

Pooling rule and its effect on the tail: ADR-0203. Tail floor (the more severe of history and the t₃ stand-in below the 2.5% quantile): ADR-0204. z in thousandths of σ; i* = ceil(α N) − 1 at α = 0.1%.

| Asset | Closure | N | Pool | z at i* (set) | pooled history | t₃ | values moved by t₃ | min (set) | own N | z at α (own only) | min (own) | padded with weekend | File |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| NVDA | OVERNIGHT | 3000 | 6072 | -6276 | -6132 | -6276 | 4 | -10802 | 1518 | -6404 | -12040 | — | `NVDA-XNAS-1-b35c31e5.json` |
| NVDA | WEEKEND | 1392 | 1392 | -8914 | -8914 | -5749 | 2 | -12172 | 348 | -4395 | -4395 | — | `NVDA-XNAS-2-4e8e6fe1.json` |
| NVDA | HOLIDAY_WEEKEND | 1644 | 1644 | -8914 | -8914 | -6085 | 4 | -12172 | 63 | -5071 | -5071 | NVDA, AAPL, MSFT, AMD | `NVDA-XNAS-3-c0ce910d.json` |
| AAPL | OVERNIGHT | 3000 | 6072 | -6276 | -6132 | -6276 | 4 | -10802 | 1518 | -8712 | -9833 | — | `AAPL-XNAS-1-366013c4.json` |
| AAPL | WEEKEND | 1392 | 1392 | -8914 | -8914 | -5749 | 2 | -12172 | 348 | -12172 | -12172 | — | `AAPL-XNAS-2-43644d8c.json` |
| AAPL | HOLIDAY_WEEKEND | 1644 | 1644 | -8914 | -8914 | -6085 | 4 | -12172 | 63 | -1900 | -1900 | AAPL, NVDA, MSFT, AMD | `AAPL-XNAS-3-8dd9c757.json` |
| TSLA | OVERNIGHT | 3000 | 5032 | -6276 | -6132 | -6276 | 5 | -11489 | 1518 | -7140 | -11489 | — | `TSLA-XNAS-1-5776ae33.json` |
| TSLA | WEEKEND | 1152 | 1152 | -5389 | -4492 | -5389 | 14 | -7828 | 348 | -5449 | -5449 | — | `TSLA-XNAS-2-0558a953.json` |
| TSLA | HOLIDAY_WEEKEND | 1355 | 1355 | -5697 | -4492 | -5697 | 19 | -8268 | 63 | -2247 | -2247 | TSLA, COIN, MSTR, AMD | `TSLA-XNAS-3-72ba3183.json` |
| COIN | OVERNIGHT | 3000 | 5032 | -6276 | -6132 | -6276 | 5 | -11489 | 478 | -4397 | -4397 | — | `COIN-XNAS-1-8fab4d73.json` |
| COIN | WEEKEND | 1152 | 1152 | -5389 | -4492 | -5389 | 14 | -7828 | 108 | -3798 | -3798 | — | `COIN-XNAS-2-6b7e9bc1.json` |
| COIN | HOLIDAY_WEEKEND | 1355 | 1355 | -5697 | -4492 | -5697 | 19 | -8268 | 14 | -1831 | -1831 | COIN, TSLA, MSTR, AMD | `COIN-XNAS-3-d9ff9ef0.json` |
| MSFT | OVERNIGHT | 3000 | 6072 | -6276 | -6132 | -6276 | 4 | -10802 | 1518 | -4599 | -5470 | — | `MSFT-XNAS-1-f29e47a0.json` |
| MSFT | WEEKEND | 1392 | 1392 | -8914 | -8914 | -5749 | 2 | -12172 | 348 | -8914 | -8914 | — | `MSFT-XNAS-2-5d883784.json` |
| MSFT | HOLIDAY_WEEKEND | 1644 | 1644 | -8914 | -8914 | -6085 | 4 | -12172 | 63 | -2745 | -2745 | MSFT, NVDA, AAPL, AMD | `MSFT-XNAS-3-7f0c0796.json` |
| SPY | OVERNIGHT | 3000 | 3036 | -6276 | -4709 | -6276 | 13 | -10802 | 1518 | -4805 | -6045 | — | `SPY-XNAS-1-35a41612.json` |
| SPY | WEEKEND | 696 | 696 | -6609 | -6609 | -6600 | 4 | -6609 | 348 | -2855 | -2855 | — | `SPY-XNAS-2-db083a0f.json` |
| SPY | HOLIDAY_WEEKEND | 822 | 822 | -6983 | -6609 | -6983 | 5 | -6983 | 63 | -2562 | -2562 | SPY, QQQ | `SPY-XNAS-3-9c4d6b61.json` |

## Joint stress set (`joint-fe9059bb.json`)

K = 256 worst of 411 non-overnight closures (2016-04-25 → 2023-12-26), ranked by synthetic stress closures first (ADR-0204), then historical closures by equal-weighted mean z of the six assets, ascending (worst first). Back-fill: OLS through the origin of z_a on z_SPY over non-overnight closures where both exist.

| Asset | β to SPY (z) | back-filled closures |
| --- | ---: | ---: |
| NVDA | 0.367 | 0 |
| AAPL | 0.418 | 0 |
| TSLA | 0.318 | 0 |
| COIN | 0.408 | 289 |
| MSFT | 0.447 | 0 |

Synthetic stress closures (ADR-0204): POT/GPD return levels of the historical basket z; GPD over the worst 10% of basket z (41 exceedances, ξ = -0.1922, scale 0.5039, 53.59 closures/year, worst observed −2.1328). Shapes: the worst historical closure (2018-04-23) scaled, and all assets equal.

| Horizon | years | closures | basket z |
| --- | ---: | ---: | ---: |
| since2000 | 23.98 | 1285.4 | -2.33 |
| 40y | 40.0 | 2143.8 | -2.43 |

Worst ten:

| # | Reopen session | Closure | basket mean z |
| ---: | --- | --- | ---: |
| 1 | SYN-40y-worstHistorical | SYNTHETIC | -2.430 |
| 2 | SYN-40y-uniform | SYNTHETIC | -2.430 |
| 3 | SYN-since2000-worstHistorical | SYNTHETIC | -2.330 |
| 4 | SYN-since2000-uniform | SYNTHETIC | -2.330 |
| 5 | 2018-04-23 | WEEKEND | -2.133 |
| 6 | 2017-02-06 | WEEKEND | -2.067 |
| 7 | 2019-04-08 | WEEKEND | -2.000 |
| 8 | 2020-03-16 | WEEKEND | -1.870 |
| 9 | 2021-08-30 | WEEKEND | -1.716 |
| 10 | 2019-09-23 | WEEKEND | -1.596 |
