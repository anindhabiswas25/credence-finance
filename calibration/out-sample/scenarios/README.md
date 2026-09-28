# Scenario sets (sample, data grade `synthetic`, through 2023-12-29)

Pooling rule and its effect on the tail: ADR-0203. z in thousandths of σ; i* = ceil(α N) − 1 at α = 0.1%.

| Asset | Closure | N | Pool | z at i* (pooled) | min (pooled) | own N | z at α (own only) | min (own) | padded with weekend | File |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| NVDA | OVERNIGHT | 3000 | 6072 | -6132 | -9833 | 1518 | -6404 | -12040 | — | `NVDA-OVERNIGHT-7dfccb10b64d28e6.json` |
| NVDA | WEEKEND | 1392 | 1392 | -8914 | -12172 | 348 | -4395 | -4395 | — | `NVDA-WEEKEND-f002c5beb3ea9d90.json` |
| NVDA | HOLIDAY_WEEKEND | 1644 | 1644 | -8914 | -12172 | 63 | -5071 | -5071 | NVDA, AAPL, MSFT, AMD | `NVDA-HOLIDAY_WEEKEND-2b9ed8b1355fa7f7.json` |
| AAPL | OVERNIGHT | 3000 | 6072 | -6132 | -9833 | 1518 | -8712 | -9833 | — | `AAPL-OVERNIGHT-f93f8201eb95006f.json` |
| AAPL | WEEKEND | 1392 | 1392 | -8914 | -12172 | 348 | -12172 | -12172 | — | `AAPL-WEEKEND-be6fa4f9b59e1f17.json` |
| AAPL | HOLIDAY_WEEKEND | 1644 | 1644 | -8914 | -12172 | 63 | -1900 | -1900 | AAPL, NVDA, MSFT, AMD | `AAPL-HOLIDAY_WEEKEND-279e65ae0686fe05.json` |
| TSLA | OVERNIGHT | 3000 | 5032 | -6132 | -11489 | 1518 | -7140 | -11489 | — | `TSLA-OVERNIGHT-6419721931f03ef5.json` |
| TSLA | WEEKEND | 1152 | 1152 | -4492 | -5449 | 348 | -5449 | -5449 | — | `TSLA-WEEKEND-3c1f9e4da9f49926.json` |
| TSLA | HOLIDAY_WEEKEND | 1355 | 1355 | -4492 | -5449 | 63 | -2247 | -2247 | TSLA, COIN, MSTR, AMD | `TSLA-HOLIDAY_WEEKEND-46edaa7ac4dfdfe9.json` |
| COIN | OVERNIGHT | 3000 | 5032 | -6132 | -11489 | 478 | -4397 | -4397 | — | `COIN-OVERNIGHT-bd7a92aaf7acc92d.json` |
| COIN | WEEKEND | 1152 | 1152 | -4492 | -5449 | 108 | -3798 | -3798 | — | `COIN-WEEKEND-3db733cbcb4e5c0c.json` |
| COIN | HOLIDAY_WEEKEND | 1355 | 1355 | -4492 | -5449 | 14 | -1831 | -1831 | COIN, TSLA, MSTR, AMD | `COIN-HOLIDAY_WEEKEND-f21c29c17376eae5.json` |
| MSFT | OVERNIGHT | 3000 | 6072 | -6132 | -9833 | 1518 | -4599 | -5470 | — | `MSFT-OVERNIGHT-1d02e251f593dba3.json` |
| MSFT | WEEKEND | 1392 | 1392 | -8914 | -12172 | 348 | -8914 | -8914 | — | `MSFT-WEEKEND-ac2213cb57b5bd92.json` |
| MSFT | HOLIDAY_WEEKEND | 1644 | 1644 | -8914 | -12172 | 63 | -2745 | -2745 | MSFT, NVDA, AAPL, AMD | `MSFT-HOLIDAY_WEEKEND-e021ac64b8faade2.json` |
| SPY | OVERNIGHT | 3000 | 3036 | -4709 | -6045 | 1518 | -4805 | -6045 | — | `SPY-OVERNIGHT-d17b754f949c16ae.json` |
| SPY | WEEKEND | 696 | 696 | -6609 | -6609 | 348 | -2855 | -2855 | — | `SPY-WEEKEND-508d0bc5ac69d973.json` |
| SPY | HOLIDAY_WEEKEND | 822 | 822 | -6609 | -6609 | 63 | -2562 | -2562 | SPY, QQQ | `SPY-HOLIDAY_WEEKEND-cedc4c61a1b3d347.json` |

## Joint stress set (`joint-ab5f9ab6cb67b7f4.json`)

K = 256 worst of 411 non-overnight closures (2016-04-25 → 2023-12-26), ranked by equal-weighted mean z of the six assets, ascending (worst first). Back-fill: OLS through the origin of z_a on z_SPY over non-overnight closures where both exist.

| Asset | β to SPY (z) | back-filled closures |
| --- | ---: | ---: |
| NVDA | 0.367 | 0 |
| AAPL | 0.418 | 0 |
| TSLA | 0.318 | 0 |
| COIN | 0.408 | 289 |
| MSFT | 0.447 | 0 |

Worst ten:

| # | Reopen session | Closure | basket mean z |
| ---: | --- | --- | ---: |
| 1 | 2018-04-23 | WEEKEND | -2.133 |
| 2 | 2017-02-06 | WEEKEND | -2.067 |
| 3 | 2019-04-08 | WEEKEND | -2.000 |
| 4 | 2020-03-16 | WEEKEND | -1.870 |
| 5 | 2021-08-30 | WEEKEND | -1.716 |
| 6 | 2019-09-23 | WEEKEND | -1.596 |
| 7 | 2020-11-09 | WEEKEND | -1.553 |
| 8 | 2017-08-14 | WEEKEND | -1.499 |
| 9 | 2017-08-28 | WEEKEND | -1.438 |
| 10 | 2021-06-28 | WEEKEND | -1.418 |
