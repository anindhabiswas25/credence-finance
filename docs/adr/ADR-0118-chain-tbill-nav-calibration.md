# ADR-0118 · BE-chain (covering QE) · TBILL:USBANK risk data from a free T-bill ETF proxy

Status: accepted (S5, item C) · Date: 2026-09-30 · Replaces the local fixture of ADR-0116

## Context
The NAV stack's asset `TBILL:USBANK` had no calibrated scenario sets, σ or joint column. ADR-0116 loaded a local-only
placeholder, which had no joint column, so the NAV pool could not sell cover on a Stylus book. There is no free daily
NAV history for a tokenised Treasury fund. The user's rule is free data only.

## Decision
- **What is modelled:** the fund's NAV change from one USBANK NAV strike to the next. The Credence treasury fund
  accrues and pays no distribution, so the proxy is the **total return** of a T-bill ETF between the closes of
  consecutive USBANK sessions: r = split × (close + dividend) / previous close − 1. Each return is typed by the same
  USBANK classifier the calendar generator uses, so a closure over Columbus Day is HOLIDAY_WEEKEND, as on-chain. A
  USBANK session with no ETF bar (Good Friday) makes a span over two closures, and it is dropped.
- **Proxies:** BIL (SPDR 1–3 Month T-Bill, from 2016 in the free window) and SGOV (iShares 0–3 Month Treasury, from
  2020-05). Both are Alpaca SIP daily bars, the same free licence as the equities (`dataGrade: free-2016`), pinned in
  their own manifest `calibration/manifests/data-alpaca-nav.json`, so the equity manifest is never rewritten
  (`make cal-nav-pull`, `make cal-nav`, and the `nav` stage of `make cal-all`).
- **σ:** the §10.6 EWMA (`sigma.py`, bit for bit) on BIL; the σ floor is BIL's long-run 25th percentile.
- **Scenario sets:** the pooled z of both proxies. A type below N_MIN = 1,000 is padded with the next shorter type
  (HOLIDAY_WEEKEND ← WEEKEND ← OVERNIGHT; each is standardised by its own type's σ, and the KS distance is reported).
  Then thinning to 3,000, quantising down and the t₃ tail floor, as for the equities (ADR-0203/0204).
- **Joint column** (K = kStress = 256; the NAV pool is its only reader), with two synthetic rows first:
  - `navMaxDrop`: the largest one-step NAV drop the oracle still accepts (`NAV_MAX_DROP` = 0.5 %; a larger drop
    halts the asset), in WEEKEND σ units. It is clipped to −32.767 σ, i.e. 0.445 % at the current σ;
  - `setAlpha`: the WEEKEND set's own α-quantile;

  then BIL's 254 worst non-overnight closures, worst first.
- **Bundle:** `calibration/out/nav/risk-bundle-nav-<sha8>.json`, a separate bundle with its own one-column joint set,
  loaded **after** the equity bundle. The loader takes one joint file per bundle, and the stacks are independent
  (R-01). Its params are a copy of the equity bundle's, so reloading them changes nothing.
- **NAV versus price:** an ETF close is a traded price, whose bid/ask bounce and premium/discount add variance a NAV
  does not have. With no free daily NAV series, the report gives the Roll estimate (−2ρ₁ of daily total returns):
  about 12 % of BIL's variance, none measurable for SGOV. The proxy's variance is used as it is, which errs wide
  (safe for lenders).

## Result (data through 2026-09-25; `calibration/out/nav/README.md`)
| Closure | σ | σ floor | z_α (set) | pool |
| --- | ---: | ---: | ---: | ---: |
| OVERNIGHT | 0.0207 % | 0.0128 % | −6.276 | 3,201 |
| WEEKEND | 0.0136 % | 0.0119 % | −6.276 | 3,915 (padded with OVERNIGHT) |
| HOLIDAY_WEEKEND | 0.0187 % | 0.0147 % | −6.276 | 4,066 (padded) |

The t₃ floor sets z_α in every type: the history is mild (worst z −4.9, SGOV overnight), and no proxy closure falls
below z_α. At α a weekend NAV loss is about 0.085 %.

## Consequences
- `make local-deploy-core` and the devnode scripts load this bundle in place of the ADR-0116 fixture. The NAV pool can
  sell cover on a Stylus book. The fixture stays in the tree for the old books only.
- For mainnet the method should be re-run on a licensed daily NAV series of the actual fund (BENJI, USTBL), which
  removes the price-noise overstatement.
