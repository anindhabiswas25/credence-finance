# Backtest (alpaca, data grade `free-2016`, through 2026-09-25)

Machine-readable: `backtest-d40243903c1aabf0.json`. Every safe LTV, premium, loss vector, capacity check, lot and settlement is risk-core output through `credence_cal.engine` (PyEngine); this report only counts and sums. Method: `credence_cal/backtest.py` (module docstring). Base parameters: α 0.10%, κ 3%, θ 100%, c 15%, η 4, β 97.5%, u_max 50%, pool equity $2,000,000. Synthetic stress levels (ADR-0204): {'since2000': -8.16, '40y': -9.33}.

## Walk-forward (headline, out of sample), from 2018-01-01

Breach frequency vs α (a breach: the realised open factor (1 + r)(1 − κ) below the α-quantile safe factor g_α): **6 / 12261 = 0.0489% [0.0180%, 0.1065%], Kupiec p 0.0469**, expected 12.261.

| Closure type | breaches / trials, 95% CI, Kupiec |
| --- | --- |
| OVERNIGHT | 2 / 9586 = 0.0209% [0.0025%, 0.0753%], Kupiec p 0.0028 |
| WEEKEND | 4 / 2207 = 0.1812% [0.0494%, 0.4634%], Kupiec p 0.2788 |
| HOLIDAY_WEEKEND | 0 / 468 = 0.0000% [0.0000%, 0.7851%], Kupiec p 0.3332 |

| Asset:type | breaches / trials, 95% CI, Kupiec |
| --- | --- |
| AAPL:OVERNIGHT | 0 / 1715 = 0.0000% [0.0000%, 0.2149%], Kupiec p 0.064 |
| AAPL:WEEKEND | 1 / 395 = 0.2532% [0.0064%, 1.4024%], Kupiec p 0.4206 |
| AAPL:HOLIDAY_WEEKEND | 0 / 85 = 0.0000% [0.0000%, 4.2470%], Kupiec p 0.68 |
| COIN:OVERNIGHT | 1 / 1011 = 0.0989% [0.0025%, 0.5499%], Kupiec p 0.9913 |
| COIN:WEEKEND | 1 / 232 = 0.4310% [0.0109%, 2.3780%], Kupiec p 0.2386 |
| COIN:HOLIDAY_WEEKEND | 0 / 43 = 0.0000% [0.0000%, 8.2211%], Kupiec p 0.7693 |
| MSFT:OVERNIGHT | 0 / 1715 = 0.0000% [0.0000%, 0.2149%], Kupiec p 0.064 |
| MSFT:WEEKEND | 0 / 395 = 0.0000% [0.0000%, 0.9295%], Kupiec p 0.374 |
| MSFT:HOLIDAY_WEEKEND | 0 / 85 = 0.0000% [0.0000%, 4.2470%], Kupiec p 0.68 |
| NVDA:OVERNIGHT | 1 / 1715 = 0.0583% [0.0015%, 0.3244%], Kupiec p 0.5533 |
| NVDA:WEEKEND | 1 / 395 = 0.2532% [0.0064%, 1.4024%], Kupiec p 0.4206 |
| NVDA:HOLIDAY_WEEKEND | 0 / 85 = 0.0000% [0.0000%, 4.2470%], Kupiec p 0.68 |
| SPY:OVERNIGHT | 0 / 1715 = 0.0000% [0.0000%, 0.2149%], Kupiec p 0.064 |
| SPY:WEEKEND | 1 / 395 = 0.2532% [0.0064%, 1.4024%], Kupiec p 0.4206 |
| SPY:HOLIDAY_WEEKEND | 0 / 85 = 0.0000% [0.0000%, 4.2470%], Kupiec p 0.68 |
| TSLA:OVERNIGHT | 0 / 1715 = 0.0000% [0.0000%, 0.2149%], Kupiec p 0.064 |
| TSLA:WEEKEND | 0 / 395 = 0.0000% [0.0000%, 0.9295%], Kupiec p 0.374 |
| TSLA:HOLIDAY_WEEKEND | 0 / 85 = 0.0000% [0.0000%, 4.2470%], Kupiec p 0.68 |

Pool: 2195 epochs; mean epoch P&L $972.57 (sd $1,239.33); total $2,134,785.15; mean annual return on J0 11.86%; premiums $1,395,259.48; shortfalls $13,653.50; liquidations 1207.

Epoch P&L quantiles (USD): {'0.001': 186.15, '0.01': 214.88, '0.05': 263.55, '0.5': 600.36, '0.95': 3012.42}.

Premiums by closure type: OVERNIGHT $1,302,224.24 on 123,050 covers ($10.58 each); WEEKEND $85,247.62 on 27,106 covers ($3.14 each); HOLIDAY_WEEKEND $7,787.62 on 5,641 covers ($1.38 each).

Breach events: NVDA 2018-11-16 OVERNIGHT r -19.30% (σ 1.92%), NVDA 2019-01-28 WEEKEND r -14.74% (σ 1.73%), SPY 2020-03-09 WEEKEND r -7.44% (σ 1.30%), COIN 2022-05-11 OVERNIGHT r -24.86% (σ 2.16%), AAPL 2024-08-05 WEEKEND r -9.45% (σ 1.01%), COIN 2024-08-05 WEEKEND r -20.75% (σ 2.48%).

Worst epoch: 2022-05-11 (OVERNIGHT) $-10,611.81, shortfall $13,653.50 (0.53% of J0). Worst full calendar year: 2021 $114,885.33.

Capacity binding rate (epochs with at least one cover refused): 0.27% (weekend and holiday closures only: 1.25%); 397 of 155797 cover requests refused.

Senior-loss events: 0 (none).

Largest shortfall epochs: 2022-05-11 OVERNIGHT $13,653.50.

## In-sample (every closure since the data start), from 2016-04-22

Breach frequency vs α (a breach: the realised open factor (1 + r)(1 − κ) below the α-quantile safe factor g_α): **6 / 14361 = 0.0418% [0.0153%, 0.0909%], Kupiec p 0.0124**, expected 14.361.

| Closure type | breaches / trials, 95% CI, Kupiec |
| --- | --- |
| OVERNIGHT | 3 / 11266 = 0.0266% [0.0055%, 0.0778%], Kupiec p 0.0034 |
| WEEKEND | 3 / 2592 = 0.1157% [0.0239%, 0.3379%], Kupiec p 0.8047 |
| HOLIDAY_WEEKEND | 0 / 503 = 0.0000% [0.0000%, 0.7307%], Kupiec p 0.3157 |

| Asset:type | breaches / trials, 95% CI, Kupiec |
| --- | --- |
| AAPL:OVERNIGHT | 0 / 2051 = 0.0000% [0.0000%, 0.1797%], Kupiec p 0.0428 |
| AAPL:WEEKEND | 1 / 472 = 0.2119% [0.0054%, 1.1747%], Kupiec p 0.5042 |
| AAPL:HOLIDAY_WEEKEND | 0 / 92 = 0.0000% [0.0000%, 3.9303%], Kupiec p 0.6679 |
| COIN:OVERNIGHT | 1 / 1011 = 0.0989% [0.0025%, 0.5499%], Kupiec p 0.9913 |
| COIN:WEEKEND | 1 / 232 = 0.4310% [0.0109%, 2.3780%], Kupiec p 0.2386 |
| COIN:HOLIDAY_WEEKEND | 0 / 43 = 0.0000% [0.0000%, 8.2211%], Kupiec p 0.7693 |
| MSFT:OVERNIGHT | 1 / 2051 = 0.0488% [0.0012%, 0.2714%], Kupiec p 0.4145 |
| MSFT:WEEKEND | 0 / 472 = 0.0000% [0.0000%, 0.7785%], Kupiec p 0.3311 |
| MSFT:HOLIDAY_WEEKEND | 0 / 92 = 0.0000% [0.0000%, 3.9303%], Kupiec p 0.6679 |
| NVDA:OVERNIGHT | 0 / 2051 = 0.0000% [0.0000%, 0.1797%], Kupiec p 0.0428 |
| NVDA:WEEKEND | 1 / 472 = 0.2119% [0.0054%, 1.1747%], Kupiec p 0.5042 |
| NVDA:HOLIDAY_WEEKEND | 0 / 92 = 0.0000% [0.0000%, 3.9303%], Kupiec p 0.6679 |
| SPY:OVERNIGHT | 1 / 2051 = 0.0488% [0.0012%, 0.2714%], Kupiec p 0.4145 |
| SPY:WEEKEND | 0 / 472 = 0.0000% [0.0000%, 0.7785%], Kupiec p 0.3311 |
| SPY:HOLIDAY_WEEKEND | 0 / 92 = 0.0000% [0.0000%, 3.9303%], Kupiec p 0.6679 |
| TSLA:OVERNIGHT | 0 / 2051 = 0.0000% [0.0000%, 0.1797%], Kupiec p 0.0428 |
| TSLA:WEEKEND | 0 / 472 = 0.0000% [0.0000%, 0.7785%], Kupiec p 0.3311 |
| TSLA:HOLIDAY_WEEKEND | 0 / 92 = 0.0000% [0.0000%, 3.9303%], Kupiec p 0.6679 |

Pool: 2615 epochs; mean epoch P&L $685.56 (sd $1,072.73); total $1,792,739.67; mean annual return on J0 8.15%; premiums $950,822.62; shortfalls $12,483.38; liquidations 1286.

Epoch P&L quantiles (USD): {'0.001': 177.06, '0.01': 177.06, '0.05': 177.06, '0.5': 404.88, '0.95': 2401.85}.

Premiums by closure type: OVERNIGHT $835,465.90 on 140,685 covers ($5.94 each); WEEKEND $105,259.37 on 31,640 covers ($3.33 each); HOLIDAY_WEEKEND $10,097.35 on 6,090 covers ($1.66 each).

Breach events: SPY 2016-06-24 OVERNIGHT r -3.41% (σ 0.40%), NVDA 2019-01-28 WEEKEND r -14.74% (σ 1.73%), COIN 2022-05-11 OVERNIGHT r -24.86% (σ 2.16%), AAPL 2024-08-05 WEEKEND r -9.45% (σ 1.01%), COIN 2024-08-05 WEEKEND r -20.75% (σ 2.62%), MSFT 2026-01-29 OVERNIGHT r -8.65% (σ 0.76%).

Worst epoch: 2022-05-11 (OVERNIGHT) $-7,975.91, shortfall $12,483.38 (0.40% of J0). Worst full calendar year: 2017 $66,565.09.

Capacity binding rate (epochs with at least one cover refused): 0.38% (weekend and holiday closures only: 1.24%); 411 of 178415 cover requests refused.

Senior-loss events: 0 (none).

Largest shortfall epochs: 2022-05-11 OVERNIGHT $12,483.38.

## Sensitivity (walk-forward; one parameter moved from the base at a time)

| Parameter | value | breaches / trials | rate | annual return on J0 | premiums | shortfalls | worst epoch | worst year | capacity binding | senior-loss events |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| alpha | 0.0005 | 2 / 12261 | 0.0163% | 12.44% | $1,502,623 | $12,409 | $-9,262 | $121,997 | 0.18% | 0 |
| alpha | 0.001 | 6 / 12261 | 0.0489% | 11.86% | $1,395,259 | $13,654 | $-10,612 | $114,885 | 0.27% | 0 |
| alpha | 0.002 | 17 / 12261 | 0.1387% | 11.61% | $1,347,438 | $13,654 | $-10,618 | $112,535 | 0.36% | 0 |
| alpha | 0.005 | 59 / 12261 | 0.4812% | 11.05% | $1,244,324 | $13,654 | $-10,618 | $112,152 | 1.37% | 0 |
| kappa | 0.02 | 6 / 12261 | 0.0489% | 11.45% | $1,321,048 | $8,471 | $-5,508 | $112,159 | 0.23% | 0 |
| kappa | 0.03 | 6 / 12261 | 0.0489% | 11.86% | $1,395,259 | $13,654 | $-10,612 | $114,885 | 0.27% | 0 |
| kappa | 0.04 | 6 / 12261 | 0.0489% | 12.31% | $1,477,719 | $18,926 | $-15,795 | $117,852 | 0.27% | 0 |
| kappa | 0.05 | 6 / 12261 | 0.0489% | 12.79% | $1,570,358 | $25,922 | $-21,099 | $121,520 | 0.27% | 0 |
| theta | 0.5 | 6 / 12261 | 0.0489% | 10.00% | $1,060,343 | $13,654 | $-10,663 | $103,337 | 0.27% | 0 |
| theta | 1 | 6 / 12261 | 0.0489% | 11.86% | $1,395,259 | $13,654 | $-10,612 | $114,885 | 0.27% | 0 |
| theta | 1.5 | 6 / 12261 | 0.0489% | 13.72% | $1,730,377 | $13,654 | $-10,561 | $126,441 | 0.27% | 0 |
| u_max | 0.4 | 6 / 12261 | 0.0489% | 11.83% | $1,391,282 | $13,654 | $-10,612 | $114,885 | 0.41% | 0 |
| u_max | 0.5 | 6 / 12261 | 0.0489% | 11.86% | $1,395,259 | $13,654 | $-10,612 | $114,885 | 0.27% | 0 |
| u_max | 0.6 | 6 / 12261 | 0.0489% | 11.90% | $1,401,877 | $13,654 | $-10,612 | $114,885 | 0.18% | 0 |
| eta | 2 | 6 / 12261 | 0.0489% | 11.71% | $1,367,482 | $13,654 | $-10,612 | $114,864 | 0.27% | 0 |
| eta | 4 | 6 / 12261 | 0.0489% | 11.86% | $1,395,259 | $13,654 | $-10,612 | $114,885 | 0.27% | 0 |
| eta | 6 | 6 / 12261 | 0.0489% | 12.01% | $1,423,038 | $13,654 | $-10,612 | $114,907 | 0.27% | 0 |
