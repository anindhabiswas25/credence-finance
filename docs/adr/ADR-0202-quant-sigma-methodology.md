# ADR-0202 · σ methodology: per-type EWMA blended with the overnight scale

Status: accepted · Role: QE · Date: 2026-09-28 · Guide §10.6 step 3, R-15 · Spec: `calibration/docs/sigma.md`

## Decision
- EWMA with λ = 0.94 of past gaps **of the same closure type** (brief, §10.6), updated per event.
- For WEEKEND and HOLIDAY_WEEKEND, blend 50/50 in variance with the overnight EWMA scaled by the asset's long-run variance ratio ρ²_t: `σ_t² = 0.5 v_t + 0.5 ρ²_t v_1`. OVERNIGHT uses its own EWMA.
- Warm-up: seed with the mean r² of the first 20 / 10 / 10 gaps; no σ or z until ≥ 60 overnight gaps and the type is seeded. The keeper never starts cold: it resumes from the state snapshot in each calibration file.
- Implied volatility: **off in v1** (no licensed IV source).
- Floor: the 25th percentile of the daily unfloored σ per (asset, type). Publish rule `max(model, floor, cur × 0.9^days)`, so the engine never rejects a submission.
- σ goes on-chain rounded to 1e-9 so float noise never reaches the chain; the keeper's float arithmetic order is fixed in the spec.

## Evidence (out of sample; 37 names, Alpaca SIP 2016-01 → 2026-09; `blendEvaluation` in `out/sigma/sigma-*.json`)
QLIKE = r²/σ² + ln σ² on each gap with the ex-ante σ (lower is better); sd(z) should be near 1.

| Type | w (own-type weight) | n | QLIKE | sd(z) | share of abs(z) > 4 |
| --- | --- | ---: | ---: | ---: | ---: |
| WEEKEND | 0 (overnight × ρ only) | 14,974 | −7.622 | 1.203 | 1.53% |
| WEEKEND | 0.25 | 14,974 | −7.731 | 1.117 | 1.09% |
| WEEKEND | **0.5** | 14,974 | **−7.751** | **1.089** | **0.94%** |
| WEEKEND | 0.75 | 14,974 | −7.727 | 1.098 | 1.02% |
| WEEKEND | 1 (own EWMA only) | 14,974 | −7.603 | 1.171 | 1.12% |
| HOLIDAY_WEEKEND | 0 | 3,156 | −7.859 | 1.228 | 1.33% |
| HOLIDAY_WEEKEND | 0.25 | 3,156 | −7.993 | 1.112 | 0.82% |
| HOLIDAY_WEEKEND | **0.5** | 3,156 | **−8.004** | 1.069 | **0.60%** |
| HOLIDAY_WEEKEND | 0.75 | 3,156 | −7.970 | 1.063 | 0.63% |
| HOLIDAY_WEEKEND | 1 | 3,156 | −7.866 | 1.107 | 0.86% |
| OVERNIGHT | (own EWMA) | 65,004 | −7.604 | 1.236 | 1.05% |

w = 0.5 is best on both types and is kept as a round number (no fine tuning on 10 years). Overnight gaps have sd(z) ≈ 1.24 because earnings gaps are jumps an EWMA cannot anticipate; that is in the tails of the sets on purpose (filtered historical simulation keeps the jump shape).

## Alternatives rejected
- √time scaling of one overnight σ (French and Roll: weekend variance is far below 3× overnight; ρ² here is 1.07–2.0 for weekends).
- A long-run constant σ per type: worse QLIKE on weekends (it ignores regimes) and it would not react to a crisis.
