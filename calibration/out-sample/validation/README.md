# Model validation: historical sets against the t₃ stand-in (data grade `synthetic`, through 2023-12-29)

Machine-readable: `validation-7c0b71bdf619d99b.json`. Method: `credence_cal/validation.py`; every number is risk-core output. α = 0.1%, κ = 3%, d = 0. The g columns are the **uncapped** safe factor (safe LTV with maxLtv = 1); the product caps it at LTV_max (75%, SPY 80%).

t₃ stand-in: z = -5898‰σ; g = 79.84% at σ 3.0%, 74.12% at σ 4.0%, 71.26% at σ 4.5%, 62.67% at σ 6.0% (the docs' §2.3 values before the cap). G-22 premium on the N = 3,000 t₃ set: $3.59 (docs, continuous t₃: $4.39).

| Asset | Closure | N | z at i*: t₃ / history / published | verdict | g at σ 4%: t₃ / history / published | g at today's σ: history / published (σ) | G-22 premium: history / published |
| --- | --- | ---: | --- | --- | --- | --- | --- |
| NVDA | OVERNIGHT | 3000 | -5898 / -6132 / -6276 | history more severe | 74.12% / 73.21% / 72.65% | 89.91% / 89.74% (1.19%) | $2.56 / $3.59 |
| NVDA | WEEKEND | 1392 | -5898 / -8914 / -8914 | history more severe | 74.12% / 62.41% / 62.41% | 82.66% / 82.66% (1.66%) | $11.42 / $11.42 |
| NVDA | HOLIDAY_WEEKEND | 1644 | -5898 / -8914 / -8914 | history more severe | 74.12% / 62.41% / 62.41% | 77.37% / 77.37% (2.27%) | $9.67 / $9.67 |
| AAPL | OVERNIGHT | 3000 | -5898 / -6132 / -6276 | history more severe | 74.12% / 73.21% / 72.65% | 92.02% / 91.90% (0.84%) | $2.56 / $3.59 |
| AAPL | WEEKEND | 1392 | -5898 / -8914 / -8914 | history more severe | 74.12% / 62.41% / 62.41% | 85.35% / 85.35% (1.35%) | $11.42 / $11.42 |
| AAPL | HOLIDAY_WEEKEND | 1644 | -5898 / -8914 / -8914 | history more severe | 74.12% / 62.41% / 62.41% | 84.81% / 84.81% (1.41%) | $9.67 / $9.67 |
| TSLA | OVERNIGHT | 3000 | -5898 / -6132 / -6276 | history more severe | 74.12% / 73.21% / 72.65% | 56.69% / 55.74% (6.78%) | $3.70 / $3.92 |
| TSLA | WEEKEND | 1152 | -5898 / -4492 / -5389 | history less severe | 74.12% / 79.57% / 76.09% | 68.54% / 62.86% (6.53%) | $0.00 / $2.68 |
| TSLA | HOLIDAY_WEEKEND | 1355 | -5898 / -4492 / -5697 | history less severe | 74.12% / 79.57% / 74.90% | 69.11% / 61.63% (6.40%) | $0.00 / $2.77 |
| COIN | OVERNIGHT | 3000 | -5898 / -6132 / -6276 | history more severe | 74.12% / 73.21% / 72.65% | 82.35% / 82.01% (2.46%) | $3.70 / $3.92 |
| COIN | WEEKEND | 1152 | -5898 / -4492 / -5389 | history less severe | 74.12% / 79.57% / 76.09% | 83.22% / 80.47% (3.16%) | $0.00 / $2.68 |
| COIN | HOLIDAY_WEEKEND | 1355 | -5898 / -4492 / -5697 | history less severe | 74.12% / 79.57% / 74.90% | 86.85% / 84.13% (2.33%) | $0.00 / $2.77 |
| MSFT | OVERNIGHT | 3000 | -5898 / -6132 / -6276 | history more severe | 74.12% / 73.21% / 72.65% | 88.58% / 88.39% (1.42%) | $2.56 / $3.59 |
| MSFT | WEEKEND | 1392 | -5898 / -8914 / -8914 | history more severe | 74.12% / 62.41% / 62.41% | 84.08% / 84.08% (1.49%) | $11.42 / $11.42 |
| MSFT | HOLIDAY_WEEKEND | 1644 | -5898 / -8914 / -8914 | history more severe | 74.12% / 62.41% / 62.41% | 84.46% / 84.46% (1.45%) | $9.67 / $9.67 |
| SPY | OVERNIGHT | 3000 | -5898 / -4709 / -6276 | history less severe | 74.12% / 78.73% / 72.65% | 93.91% / 92.88% (0.68%) | $0.18 / $3.59 |
| SPY | WEEKEND | 696 | -5898 / -6609 / -6609 | history more severe | 74.12% / 71.36% / 71.36% | 93.08% / 93.08% (0.61%) | $1.93 / $1.93 |
| SPY | HOLIDAY_WEEKEND | 822 | -5898 / -6609 / -6983 | history more severe | 74.12% / 71.36% / 69.91% | 92.91% / 92.67% (0.64%) | $1.63 / $2.28 |

## Joint stress set: effect of the synthetic closures on capacity

Reference book: $1,000,000 of collateral per market, all covered at max LTV, today's WEEKEND σ. Worst joint loss with the 4 synthetic closures: $125,245.67 (at 2019-12-16); historical closures only: $125,245.67. Pool equity needed at u_max = 50%: $250,491.33 vs $250,491.33 (+0.0%).
