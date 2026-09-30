# TBILL:USBANK risk data (ADR-0118), data through 2026-09-25

Bundle: `risk-bundle-nav-5bdf292d.json` (load after the equity bundle). Proxies: BIL, SGOV (Alpaca SIP daily, free).

| Closure | σ (published) | σ floor | set n | pool | z_α (set) | z_min (set) | padded with |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| OVERNIGHT | 0.0207 % | 0.0128 % | 3000 | 3201 | -6.276 | -10.802 | — |
| WEEKEND | 0.0136 % | 0.0119 % | 3000 | 3915 | -6.276 | -10.802 | OVERNIGHT 3201, ksOvernight 0.0922 |
| HOLIDAY_WEEKEND | 0.0187 % | 0.0147 % | 3000 | 4066 | -6.276 | -10.802 | WEEKEND 714, ksWeekend 0.066, OVERNIGHT 3201, ksOvernight 0.0877 |

## Price versus NAV

An ETF close is a traded price. Its bid/ask bounce and premium/discount add variance a NAV does not have, so these sets and σ are wider than the fund's (the safe side for lenders). No free daily NAV series is available to measure the difference directly; the Roll estimate below (−2ρ₁, from the lag-1 autocorrelation of daily total returns) is the free proxy. A value near 0 means the bounce is not measurable at a daily horizon; the proxy's variance is then used as it is.

| Proxy | daily σ (bp) | lag-1 autocorrelation | ≈ noise share of variance |
| --- | ---: | ---: | ---: |
| BIL | 1.625 | -0.0596 | 12% |
| SGOV | 1.489 | 0.0915 | 0% |

## Validation (own history below the set's z_α; α = 0.100 %)

| Closure | Proxy | n | below z_α | share | worst z |
| --- | --- | ---: | ---: | ---: | ---: |
| OVERNIGHT | BIL | 2030 | 0 | 0.0 | -2.928 |
| OVERNIGHT | SGOV | 1171 | 0 | 0.0 | -4.891 |
| WEEKEND | BIL | 454 | 0 | 0.0 | -2.795 |
| WEEKEND | SGOV | 260 | 0 | 0.0 | -2.52 |
| HOLIDAY_WEEKEND | BIL | 97 | 0 | 0.0 | -2.287 |
| HOLIDAY_WEEKEND | SGOV | 54 | 0 | 0.0 | -1.563 |

Joint column: K = 256 (551 BIL non-overnight closures ranked); worst rows:

- {"row": "navMaxDrop", "type": "SYNTHETIC", "z": -32767}
- {"row": "setAlpha", "type": "SYNTHETIC", "z": -6276}
- {"date": "2021-06-07", "type": "WEEKEND", "z": -2.7952}
- {"date": "2016-09-12", "type": "WEEKEND", "z": -2.6727}
- {"date": "2021-08-16", "type": "WEEKEND", "z": -2.621}
- {"date": "2020-12-07", "type": "WEEKEND", "z": -2.6024}
- {"date": "2021-08-23", "type": "WEEKEND", "z": -2.333}
- {"date": "2017-05-30", "type": "HOLIDAY_WEEKEND", "z": -2.2866}

`navMaxDrop` = −0.5% / σ_WEEKEND, clipped to the int16 range (−32.767 σ): with σ_WEEKEND = 0.0136 % it stands for a 0.445% drop.
