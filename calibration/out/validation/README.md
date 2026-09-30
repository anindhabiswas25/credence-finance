# Model validation: historical sets against the t₃ stand-in (data grade `free-2016`, through 2026-09-25)

Machine-readable: `validation-2e181c449aee7f72.json`. Method: `credence_cal/validation.py`; every number is risk-core output. α = 0.1%, κ = 3%, d = 0. The g columns are the **uncapped** safe factor (safe LTV with maxLtv = 1); the product caps it at LTV_max (75%, SPY 80%).

t₃ stand-in: z = -5898‰σ; g = 79.84% at σ 3.0%, 74.12% at σ 4.0%, 71.26% at σ 4.5%, 62.67% at σ 6.0% (the docs' §2.3 values before the cap). G-22 premium on the N = 3,000 t₃ set: $3.59 (docs, continuous t₃: $4.39).

| Asset | Closure | N | z at i*: t₃ / history / published | verdict | g at σ 4%: t₃ / history / published | g at today's σ: history / published (σ) | G-22 premium: history / published |
| --- | --- | ---: | --- | --- | --- | --- | --- |
| NVDA | OVERNIGHT | 3000 | -5898 / -11144 / -11144 | history more severe | 74.12% / 53.76% / 53.76% | 80.99% / 80.99% (1.48%) | $18.86 / $18.86 |
| NVDA | WEEKEND | 3000 | -5898 / -7208 / -7208 | history more severe | 74.12% / 69.03% / 69.03% | 85.85% / 85.85% (1.59%) | $4.15 / $4.86 |
| NVDA | HOLIDAY_WEEKEND | 1472 | -5898 / -5021 / -5860 | history less severe | 74.12% / 77.52% / 74.26% | 90.33% / 89.22% (1.37%) | $0.00 / $2.94 |
| AAPL | OVERNIGHT | 3000 | -5898 / -11144 / -11144 | history more severe | 74.12% / 53.76% / 53.76% | 86.78% / 86.78% (0.95%) | $18.86 / $18.86 |
| AAPL | WEEKEND | 3000 | -5898 / -7208 / -7208 | history more severe | 74.12% / 69.03% / 69.03% | 89.54% / 89.54% (1.07%) | $4.15 / $4.86 |
| AAPL | HOLIDAY_WEEKEND | 1472 | -5898 / -5021 / -5860 | history less severe | 74.12% / 77.52% / 74.26% | 92.33% / 91.55% (0.96%) | $0.00 / $2.94 |
| TSLA | OVERNIGHT | 3000 | -5898 / -9375 / -9375 | history more severe | 74.12% / 60.62% / 60.62% | 82.91% / 82.91% (1.55%) | $14.62 / $14.62 |
| TSLA | WEEKEND | 3000 | -5898 / -7208 / -7208 | history more severe | 74.12% / 69.03% / 69.03% | 84.57% / 84.57% (1.78%) | $7.82 / $7.82 |
| TSLA | HOLIDAY_WEEKEND | 3000 | -5898 / -7324 / -7324 | history more severe | 74.12% / 68.58% / 68.58% | 81.60% / 81.60% (2.17%) | $7.11 / $7.11 |
| COIN | OVERNIGHT | 3000 | -5898 / -9375 / -9375 | history more severe | 74.12% / 60.62% / 60.62% | 73.46% / 73.46% (2.59%) | $14.62 / $14.62 |
| COIN | WEEKEND | 3000 | -5898 / -7208 / -7208 | history more severe | 74.12% / 69.03% / 69.03% | 76.98% / 76.98% (2.86%) | $7.82 / $7.82 |
| COIN | HOLIDAY_WEEKEND | 3000 | -5898 / -7324 / -7324 | history more severe | 74.12% / 68.58% / 68.58% | 81.27% / 81.27% (2.21%) | $7.11 / $7.11 |
| MSFT | OVERNIGHT | 3000 | -5898 / -11144 / -11144 | history more severe | 74.12% / 53.76% / 53.76% | 81.97% / 81.97% (1.39%) | $18.86 / $18.86 |
| MSFT | WEEKEND | 3000 | -5898 / -7208 / -7208 | history more severe | 74.12% / 69.03% / 69.03% | 87.96% / 87.96% (1.29%) | $4.15 / $4.86 |
| MSFT | HOLIDAY_WEEKEND | 1472 | -5898 / -5021 / -5860 | history less severe | 74.12% / 77.52% / 74.26% | 92.19% / 91.39% (0.99%) | $0.00 / $2.94 |
| SPY | OVERNIGHT | 3000 | -5898 / -5994 / -6276 | history more severe | 74.12% / 73.74% / 72.65% | 94.27% / 94.14% (0.47%) | $2.07 / $3.59 |
| SPY | WEEKEND | 3000 | -5898 / -6121 / -6276 | history more severe | 74.12% / 73.25% / 72.65% | 93.19% / 93.09% (0.64%) | $4.09 / $4.17 |
| SPY | HOLIDAY_WEEKEND | 1104 | -5898 / -4404 / -5311 | history less severe | 74.12% / 79.91% / 76.39% | 94.67% / 94.19% (0.55%) | $0.00 / $2.65 |
| GOOGL | OVERNIGHT | 3000 | -5898 / -11144 / -11144 | history more severe | 74.12% / 53.76% / 53.76% | 84.46% / 84.46% (1.16%) | $18.86 / $18.86 |
| GOOGL | WEEKEND | 3000 | -5898 / -7208 / -7208 | history more severe | 74.12% / 69.03% / 69.03% | 88.73% / 88.73% (1.18%) | $4.15 / $4.86 |
| GOOGL | HOLIDAY_WEEKEND | 1472 | -5898 / -5021 / -5860 | history less severe | 74.12% / 77.52% / 74.26% | 91.67% / 90.78% (1.09%) | $0.00 / $2.94 |
| AMZN | OVERNIGHT | 3000 | -5898 / -11144 / -11144 | history more severe | 74.12% / 53.76% / 53.76% | 80.06% / 80.06% (1.57%) | $18.86 / $18.86 |
| AMZN | WEEKEND | 3000 | -5898 / -7208 / -7208 | history more severe | 74.12% / 69.03% / 69.03% | 87.72% / 87.72% (1.33%) | $4.15 / $4.86 |
| AMZN | HOLIDAY_WEEKEND | 1472 | -5898 / -5021 / -5860 | history less severe | 74.12% / 77.52% / 74.26% | 91.59% / 90.69% (1.11%) | $0.00 / $2.94 |

## Joint stress set: effect of the synthetic closures on capacity

Reference book: $1,000,000 of collateral per market, all covered at max LTV, today's WEEKEND σ. Worst joint loss with the 4 synthetic closures: $120,455.86 (at SYN-40y-worstHistorical); historical closures only: $16,458.54. Pool equity needed at u_max = 50%: $240,911.72 vs $32,917.07 (+631.9%).
