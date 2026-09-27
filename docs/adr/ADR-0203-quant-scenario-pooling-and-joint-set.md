# ADR-0203 · Scenario sets: pooling comparable names; the joint stress set

Status: accepted · Role: QE · Date: 2026-09-28 · Guide §9.3 (N = 1,000–3,000), §10.6 steps 4–5, R-13, R-14

## Context
At α = 0.1%, `i* = ceil(α N) − 1` is the 1st, 2nd or 3rd worst value of a set of 1,000–3,000. One asset has about 50 weekends and 9 holiday closures a year, and the dev data covers 10.7 years (ADR-0201), so no single name can fill a set. The guide asks to pool comparable names.

## Decision: scenario sets
1. **Groups** (`credence_cal/common.py::GROUPS`), fixed and ordered, with the asset itself first:
   - MEGA_TECH (NVDA, AAPL, MSFT): + AMD, AVGO, GOOGL, AMZN, META, INTC, CSCO, ORCL, QCOM, ADBE, TXN, MU, NFLX
   - HIGH_VOL (TSLA, COIN): + MSTR, MARA, RIOT, HOOD, PLTR, SHOP, ROKU, AMD, NFLX
   - INDEX_ETF (SPY): + QQQ, IWM, DIA and the nine sector SPDRs
2. **Same-type pooling.** A set for (a, t) holds the z of type t of every name in a's group. Each z is standardised by that name's own σ (ADR-0202), so names of different volatility are comparable.
3. **Padding (HOLIDAY_WEEKEND only).** If fewer than 1,000 values result, the group's WEEKEND z are added. Holiday and weekend z differ at the centre (KS 0.10 over all names), but the weekend z have the fatter tail (1.53%/0.94% of |z| > 4 against 0.60% for holidays at the chosen blend), so padding is conservative. Only HIGH_VOL needs it (764 holiday values).
4. **Thinning.** Above 3,000 values (the gas ceiling for `quoteCover`), keep the midpoint quantiles `x_(floor((2i+1) M / 6000))`. This preserves the pooled quantile function, so G_α is the pool's α-quantile, not a random subsample's.
5. **Quantisation.** `floor(1000 z)` (toward −∞, the lender-conservative side), clipped to ±32,767, sorted ascending.
6. **History windows and exclusions.** RIOT and MARA contribute only from 2021-01-01; before that they were micro-cap shells, not crypto proxies (RIOT's 2016-03-31 +670% bar is an unadjusted reverse split). One gap is excluded by hand: XLF 2016-09-19 (the XLRE spin-off distribution, which is missing from the vendor's corporate actions). Every other outlier is a real event (for example the earnings gaps of META 2022-02-03 and NFLX 2022-04-20, and the 2024-08-05 carry unwind) and stays in, because that tail is exactly what FHS must keep. The quality report lists them all.

## Effect on the tail (Alpaca 2016–2026; `calibration/out/scenarios/README.md` has every set)
| Set | N | z at i*, pooled | own-only z at α (own N) |
| --- | ---: | ---: | --- |
| NVDA WEEKEND | 3,000 | −7.21 | −8.50 (472; the own minimum) |
| TSLA WEEKEND | 3,000 | −7.21 | −3.97 (472) |
| SPY WEEKEND | 3,000 | −6.12 | −6.12 (472) |
| NVDA HOLIDAY | 1,472 | −5.02 | −5.36 (92) |
| COIN HOLIDAY | 3,000 | −7.32 | −2.35 (43) |
| NVDA OVERNIGHT | 3,000 | −11.14 | −3.96 (2,051) |

Pooling mostly makes the tail **more** severe where an asset's own history is short or quiet (TSLA and COIN weekends, overnight everywhere, since the pool carries other names' earnings crashes), and slightly less severe where the asset's own single worst event dominates (NVDA and AAPL weekends: 2024-08-05 and 2020-03-16). Overnight sets are the same for all names in a group; that is accepted, because overnight safe LTV is capped at LTV_max for every asset at current σ.

## Decision: joint stress set (R-13)
- Candidates: every WEEKEND or HOLIDAY_WEEKEND closure where SPY has a z (564 closures, 2016-04 → 2026-09).
- Each asset contributes its own z of that closure's type. Missing values (COIN before its 2021-04-14 listing: 289 closures) are back-filled as `β_a × z_SPY`, with β_a the OLS slope through the origin of z_a on z_SPY over the closures where both exist (NVDA 0.81, AAPL 0.81, TSLA 0.54, COIN 0.79, MSFT 0.84). A β fill has no idiosyncratic part, so it understates single-name stress in COIN's early years. The capacity check's uncovered bound and the per-set safe LTV cover single-name tails anyway.
- Ranking: equal-weighted **mean z** of the six assets (the quantity the engine rescales by today's σ), ascending. The K = 256 worst are kept, worst first, and every asset's column uses the same closure order. Worst: 2024-08-05 (−6.73), 2020-02-24, 2020-03-09, 2020-09-08, 2020-03-16.

## Consequences
- Sets depend on the group lists. Changing a group is a recalibration proposal.
- Survivorship: the groups are today's large names. That biases the pool toward names that survived, which **understates** tails. A licensed full-history pull (ADR-0201) should add delisted comparables.
