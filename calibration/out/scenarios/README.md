# Scenario sets (alpaca, data grade `dev-unlicensed`, through 2026-09-25)

Pooling rule and its effect on the tail: ADR-0203. z in thousandths of σ; i* = ceil(α N) − 1 at α = 0.1%.

| Asset | Closure | N | Pool | z at i* (pooled) | min (pooled) | own N | z at α (own only) | min (own) | padded with weekend | File |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| NVDA | OVERNIGHT | 3000 | 32816 | -11144 | -16430 | 2051 | -3961 | -10068 | — | `NVDA-OVERNIGHT-f4c26bd42e71c2ea.json` |
| NVDA | WEEKEND | 3000 | 7552 | -7208 | -9318 | 472 | -8500 | -8500 | — | `NVDA-WEEKEND-cccca74141df9949.json` |
| NVDA | HOLIDAY_WEEKEND | 1472 | 1472 | -5021 | -5355 | 92 | -5355 | -5355 | — | `NVDA-HOLIDAY_WEEKEND-2d456512f6ed55e4.json` |
| AAPL | OVERNIGHT | 3000 | 32816 | -11144 | -16430 | 2051 | -10421 | -10647 | — | `AAPL-OVERNIGHT-048e60ecec3969ff.json` |
| AAPL | WEEKEND | 3000 | 7552 | -7208 | -9318 | 472 | -9318 | -9318 | — | `AAPL-WEEKEND-d560bcb3a88dafff.json` |
| AAPL | HOLIDAY_WEEKEND | 1472 | 1472 | -5021 | -5355 | 92 | -5021 | -5021 | — | `AAPL-HOLIDAY_WEEKEND-b820c3ec94692d7a.json` |
| TSLA | OVERNIGHT | 3000 | 17171 | -9375 | -16496 | 2051 | -7607 | -9859 | — | `TSLA-OVERNIGHT-fb4a4120fcde39b2.json` |
| TSLA | WEEKEND | 3000 | 3947 | -7208 | -11549 | 472 | -3968 | -3968 | — | `TSLA-WEEKEND-48a87bac78699f3d.json` |
| TSLA | HOLIDAY_WEEKEND | 3000 | 4711 | -7324 | -11549 | 92 | -4805 | -4805 | TSLA, COIN, MSTR, MARA, RIOT, HOOD, PLTR, SHOP, ROKU, AMD, NFLX | `TSLA-HOLIDAY_WEEKEND-b122413c34ab7652.json` |
| COIN | OVERNIGHT | 3000 | 17171 | -9375 | -16496 | 1011 | -6561 | -11529 | — | `COIN-OVERNIGHT-553093c74803b67e.json` |
| COIN | WEEKEND | 3000 | 3947 | -7208 | -11549 | 232 | -8515 | -8515 | — | `COIN-WEEKEND-1ab8338bd88c8b24.json` |
| COIN | HOLIDAY_WEEKEND | 3000 | 4711 | -7324 | -11549 | 43 | -2348 | -2348 | COIN, TSLA, MSTR, MARA, RIOT, HOOD, PLTR, SHOP, ROKU, AMD, NFLX | `COIN-HOLIDAY_WEEKEND-839a48814a7bb3f2.json` |
| MSFT | OVERNIGHT | 3000 | 32816 | -11144 | -16430 | 2051 | -6665 | -11408 | — | `MSFT-OVERNIGHT-68ee9dba0e1fc304.json` |
| MSFT | WEEKEND | 3000 | 7552 | -7208 | -9318 | 472 | -7528 | -7528 | — | `MSFT-WEEKEND-eb60593d46868962.json` |
| MSFT | HOLIDAY_WEEKEND | 1472 | 1472 | -5021 | -5355 | 92 | -4667 | -4667 | — | `MSFT-HOLIDAY_WEEKEND-6e92eeaac53e3420.json` |
| SPY | OVERNIGHT | 3000 | 24612 | -5994 | -8230 | 2051 | -4841 | -8421 | — | `SPY-OVERNIGHT-8144506ec2f81219.json` |
| SPY | WEEKEND | 3000 | 5663 | -6121 | -11084 | 472 | -6121 | -6121 | — | `SPY-WEEKEND-ac29757168a41303.json` |
| SPY | HOLIDAY_WEEKEND | 1104 | 1104 | -4404 | -5030 | 92 | -2913 | -2913 | — | `SPY-HOLIDAY_WEEKEND-75b222494f877fcd.json` |

## Joint stress set (`joint-2cc24c2fdccef00b.json`)

K = 256 worst of 564 non-overnight closures (2016-04-25 → 2026-09-21), ranked by equal-weighted mean z of the six assets, ascending (worst first). Back-fill: OLS through the origin of z_a on z_SPY over non-overnight closures where both exist.

| Asset | β to SPY (z) | back-filled closures |
| --- | ---: | ---: |
| NVDA | 0.807 | 0 |
| AAPL | 0.813 | 0 |
| TSLA | 0.539 | 0 |
| COIN | 0.786 | 289 |
| MSFT | 0.843 | 0 |

Worst ten:

| # | Reopen session | Closure | basket mean z |
| ---: | --- | --- | ---: |
| 1 | 2024-08-05 | WEEKEND | -6.734 |
| 2 | 2020-02-24 | WEEKEND | -4.484 |
| 3 | 2020-03-09 | WEEKEND | -4.237 |
| 4 | 2020-09-08 | HOLIDAY_WEEKEND | -3.909 |
| 5 | 2020-03-16 | WEEKEND | -3.593 |
| 6 | 2020-01-27 | WEEKEND | -3.087 |
| 7 | 2019-05-13 | WEEKEND | -2.704 |
| 8 | 2022-06-13 | WEEKEND | -2.618 |
| 9 | 2025-01-27 | WEEKEND | -2.582 |
| 10 | 2019-05-06 | WEEKEND | -2.574 |
