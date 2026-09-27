# σ methodology (v1)

Owner: QE · Status: **normative for keeper J7** · Guide §8.10, §10.2 J7, §10.6 steps 3 and 6, R-15 · ADR-0202

This is the exact computation of the volatility scale σ for each (asset, closure type) that the Risk
Engine multiplies the standardised scenario sets by (F-4.2, F-4.3, F-4.4). The calibration pipeline
uses it to standardise history, and the keeper (J7) uses it to publish σ daily. Both must agree bit for
bit. The executable reference is `calibration/credence_cal/sigma.py`; the test vectors are in
[`sigma-vectors.json`](sigma-vectors.json) (§8).

## 1. Inputs

For each listed asset, per XNYS session s with previous session p (both from the XNYS calendar):

| Input | Source |
| --- | --- |
| `close_p` | official regular-session close of session p (unadjusted) |
| `open_s` | official regular-session open of session s (unadjusted) |
| `split_s` | new shares per old share for a split effective at s's open; `1.0` otherwise. Reverse splits are < 1. A stock dividend of rate q counts as `1 + q` |
| `dividend_s` | cash dividend per share with ex-date s; `0.0` otherwise |
| closure type t | the `closureTypeAfter` of session p in the calendar: `1` OVERNIGHT (s is the next calendar day), `2` WEEKEND (only Saturday/Sunday in between), `3` HOLIDAY_WEEKEND (any weekday holiday in between; a mid-week holiday is 3). Unscheduled closures (e.g. 2025-01-09) are holidays |

If either bar is missing (a halt through the close or open, a vendor hole), **skip the gap**: it spans
more than one closure. A gap with zero volume on s is skipped too.

## 2. Arithmetic

All arithmetic is IEEE-754 binary64 (`f64`), evaluated **left to right exactly as written**, with the
parentheses shown. Decimal constants are parsed with a correctly-rounded parser (Rust `str::parse::<f64>`,
Python `float()`); every float in the vectors is the shortest round-trip representation.

```text
LAM = 0.94        W = 0.5
r   = split_s * (open_s + dividend_s) / close_p - 1.0                 // gap return, total-return basis
```

## 3. State and update

Per asset the state is three EWMA variances `v[1], v[2], v[3]` (one per closure type). A gap of type t
updates **only** `v[t]`:

```text
v[t] = LAM * v[t] + (1.0 - LAM) * (r * r)
```

## 4. Published σ (before the floor)

```text
σ[1] = sqrt(v[1])
σ[2] = sqrt(W * v[2] + ((1.0 - W) * rho2[2]) * v[1])
σ[3] = sqrt(W * v[3] + ((1.0 - W) * rho2[3]) * v[1])
```

`sqrt` is the correctly-rounded IEEE square root (`f64::sqrt`, `math.sqrt`). `rho2[t]` is the asset's
long-run ratio `mean(r²  of type t) / mean(r² of type 1)`; it is a **constant** that each calibration
publishes (§7).

Why a blend: weekends and holidays are rare (≈ 52 and ≈ 9 a year), so an EWMA of their own gaps reacts
to a regime change only after weeks or months. The overnight EWMA sees ≈ 250 gaps a year, and ρ maps
its level to the closure type. Out of sample over 37 names (2016–2026, 14,974 weekend and 3,156
holiday gaps), W = 0.5 minimises the QLIKE loss for both types (ADR-0202 has the table); W = 1 (no blend)
and W = 0 (overnight only) are both worse.

## 5. Conversion, floor and the publish rule

```text
toWad(x)  = floor(x * 1e9 + 0.5) * 1e9                       // round to 1e-9 (half away from zero), as uint256
model[t]  = toWad(σ[t])
floor[t]  = from the calibration file (§7)
cur[t]    = engine.sigma(assetId, t)                          // 0 if never set
days      = floor((block.timestamp - sigmaAt[t]) / 86400)     // as the engine computes it (risk-core elapsed_days)
minAllow  = risk-core sigma_min_allowed(cur[t], days)         // cur × 0.9^days, rounded up (R-15)
submit[t] = max(model[t], floor[t], minAllow)                 // if cur[t] = 0: max(model[t], floor[t])
```

Use risk-core's `sigma_min_allowed` / `elapsed_days` directly (native build); do not re-derive 0.9^days.
Because `submit ≥ minAllow` and `submit ≥ floor`, the engine never rejects it for `SigmaDropTooFast` or
`SigmaBelowFloor`. If the transaction lands later than estimated, `days` can only grow, so `minAllow`
only falls and the submission stays valid. Risk goes up at once and down at most 10% a day.

**Implied volatility blend: off in v1.** There is no licensed implied-vol source. The slot is reserved:
a future version will define `σ_final = sqrt((1 − w_iv) σ_hist² + w_iv σ_iv²)` with `w_iv` from the
calibration file; in v1 `w_iv = 0` and `σ_final = σ_hist`.

## 6. Schedule (J7)

Daily, 30 minutes after the XNYS close (the guide's J7 trigger). Before submitting, apply every gap that
has become known since the last run, **in session order** (the gap into session s becomes known at s's
official open). Then compute and submit σ for all three types of every listed asset, with `asOfDay` =
the ET date of the session just closed. Idempotency key: (asset, closureType, day). On a restart, replay
from the calibration snapshot (§7) over all gaps after its `asOf`; the result is the same.

## 7. Warm-up and the calibration file

**Keeper (resume mode).** The keeper never starts cold. Each calibration publishes
`calibration/out/sigma/sigma-<hash>.json` with, per listed asset:

| Field | Meaning |
| --- | --- |
| `assetId` | `keccak256("<SYMBOL>:XNAS")` |
| `state.asOf` | the session date of the last gap included |
| `state.v` | `v[1..3]` after that gap (float strings, exact) |
| `state.rho2` | `rho2[2]`, `rho2[3]` (float strings, exact) |
| `floorWad` | σ floor per type (also written on-chain with `setSigmaFloor`) |
| `sigmaWad` | the floored σ at `asOf` (the value to seed the engine with) |

The keeper loads `v` and `rho2`, then applies §3 to every gap after `asOf`.

**Calibration (cold mode).** To standardise history, the pipeline starts each name from nothing:

- `v[t]` is seeded with the plain mean of `r*r` over the first `SEED[t]` gaps of type t (sum left to
  right, then divide), with `SEED = {1: 20, 2: 10, 3: 10}`; after seeding, §3 applies.
- `rho2[t]` is the **expanding** ratio over all gaps seen so far (`Σr²_t / n_t) / (Σr²_1 / n_1)`), so a
  historical z never uses future information.
- σ[t] is defined ("warm") once `n[1] ≥ 60` and type t is seeded. A z is only produced for a gap whose
  type is warm, as `z = r / σ[t]` with σ computed **before** that gap updates the state.

A newly listed asset without a calibrated snapshot publishes its floor until the next calibration.

**Floors (§10.6 step 6).** For each (asset, type): the 25th percentile (numpy `quantile`, linear
interpolation) of the daily series of unfloored σ[t] over every day on which all three types were warm.

## 8. Test vectors (`sigma-vectors.json`)

| Block | What J7 must reproduce | Match |
| --- | --- | --- |
| `gapReturn` | `r` from (prevClose, open, split, dividend), §2 | exact `f64` (compare the repr) |
| `classify` | closure type for (prevSession, session), incl. Thanksgiving, Good Friday, Independence Day 2027 (observed Monday 5 July), mid-week Juneteenth 2025, New Year, MLK day, and the 2025-01-09 unscheduled closure | exact |
| `keeperResume` | three cases K-1..K-3: from `v0` and `rho2`, apply each step's `(type, r)`; after each step `v` (exact `f64`) and `sigmaWad` per type (§5 `toWad`, unfloored) | exact |
| `publish` | `submitWad` from (modelWad, floorWad, currentWad, days) | exact |
| `pipelineReplay` | cold mode, §7 (for the pipeline; the keeper does not need it) | exact |

Examples (K-1, first two steps; `v0 = {1: 2.5e-4, 2: 3.1e-4, 3: 1.9e-4}`, `rho2 = {2: 1.25, 3: 0.72}`):

| Step | type | r | v[1] | v[2] | σ[1] WAD | σ[2] WAD | σ[3] WAD |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 2 | -0.000346 | 0.00025 | 0.00029140718296 | 15811388000000000 | 17376812000000000 | 13601471000000000 |
| 2 | 1 | 0.018591 | 0.00025573751686 | 0.00029140718296 | 15991795000000000 | 17479689000000000 | 13677189000000000 |

Publish examples: model 0.015, floor 0.012, current 0.020 → submit **0.018** after 1 day, **0.0162**
after 2 days, **0.015** after 3 days; a model of 0.011 with floor 0.012 submits **0.012**.

The pytest suite (`calibration/tests/test_sigma.py`) regenerates the vectors from the reference
implementation and fails if the committed file differs.

## 9. Changes

A change to any constant or formula here is a new version (`sigma.md` v2, new vectors) and goes through
the quarterly recalibration proposal, because the scenario sets are standardised with this exact σ.
