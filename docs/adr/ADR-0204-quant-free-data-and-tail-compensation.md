# ADR-0204 · Free data since 2016 and explicit compensation for the missing tail

Status: accepted · Role: QE · Date: 2026-09-28 · **Supersedes ADR-0201** · Guide §1.2, §9.3, §9.5, §10.6 steps 1, 4, 5 and 7, R-13, R-26 · PM ANSWER 2026-09-28 11:45

## Context
The user will not buy a data plan (PM ANSWER 11:45). The free sources measured in ADR-0201 are:
- **Alpaca Basic**: SIP daily bars (the consolidated official open and close) and corporate actions from **2016-01-04**, about 10.7 years;
- **Polygon/Massive Basic**: official daily open and close, but only for the **last 2 years**, at 5 requests per minute.

The brief asked for 20+ years since 2000. The free history therefore misses the 2000–2015 tail: the dot-com unwind, 9/11 (a 4-session closure), 2008 (Lehman and the October weekends), the 2010 flash crash (intraday, not a gap), the August 2011 downgrade weekend, and the 24 August 2015 open. A model built only on 2016–2026 would be calibrated on a sample whose worst joint weekend is 2024-08-05, and which contains one real crisis (March 2020).

## Decision

### 1. Source, licence, labels
- The calibration source is **Alpaca SIP daily bars, 2016-01-04 → 2026-09-25** (37 symbols), pinned by `calibration/manifests/data-alpaca.json` (content sha256 per symbol; `make cal-verify`).
- **Cross-check:** `make cal-crosscheck` compares the pinned bars with Polygon's official `/v1/open-close` on 36 closures of the last 2 years. Per listed asset these are the four largest-|r| WEEKEND/HOLIDAY_WEEKEND gaps plus two seeded random ones, each checked on both the previous close and the open. The result (relative differences only, no prices) is committed at `calibration/manifests/crosscheck-alpaca-polygon.json`.
- Every output carries **`dataGrade: "free-2016"`**. This replaces `dev-unlicensed`.
- **Licence:** both plans are personal, non-professional licences. The user accepted them for the S2 testnet calibration. Only derived, standardised values go on-chain (int16 z in thousandths of σ, σ in WAD), never prices. **The PM re-opens licensing before any mainnet launch.** The Tiingo adapter (`VENDOR=tiingo`) stays in the code, unused, so a licensed re-pull is one `make cal-data cal-all VENDOR=…` away.

### 2. Compensation A: t₃ tail floor on every scenario set
The docs' model is a unit-variance Student-t with 3 degrees of freedom (the "t₃ stand-in", G-06: −5.897σ at α = 0.1%). After pooling, thinning and quantising (ADR-0203), each set is floored at its tail:

```
p_i  = (i + 0.5) / N                                  (Hazen plotting position of sorted index i)
z_i ← min(z_i, floor(1000 · t₃⁻¹(p_i) / √3))          for every i with p_i ≤ 2.5%
```

Both sequences ascend, so the set stays sorted. The window runs to 2.5% so that it covers every α the backtest sweeps (≤ 0.5%) and the ES tail of the premium (β = 97.5%). The Hazen position puts the t₃ value for i* = ceil(αN) − 1 at a probability slightly **below** α, so the floor is a little stricter than the docs' number at i* itself (−6.28σ for N = 3,000).

### 3. Compensation B: synthetic stress closures in the joint set
Four synthetic closures go **ahead of** the historical ones, and K stays 256, so the four mildest historical closures drop out:

- **Level.** The peaks-over-threshold return level of the historical basket z (the equal-weighted mean z the joint set is ranked by). A GPD is fitted to the worst 10% of −basket. The level for T closures is `u + s/ξ ((Tζ)^ξ − 1)`, where T is closures per year times the horizon. The level is never milder than the worst observed value, and it is rounded to 0.01 toward the severe side.
  - Horizon `since2000` (2000-01-01 to the data end, 26.7 years): the worst weekend a sample as long as the brief asked for would be expected to hold.
  - Horizon `40y`: the 1987-type event.
- **Shape.** Each level is laid out in two cross-sections:
  - `worstHistorical`: the worst historical closure (2024-08-05) scaled to the level, which keeps a realistic dispersion (AAPL and COIN fell hardest);
  - `uniform`: every asset at the level, i.e. correlation 1, which is how 1987 and October 2008 behaved and which 2016–2026 never shows.
- **Fit on the Alpaca data:** 57 exceedances, ξ = 0.287, scale 0.655, 54.2 closures a year. `since2000` gives basket z **−8.16** and `40y` gives **−9.33**, against −6.73 observed. A Student-t fitted to the whole basket sample has df = 2.97 and gives milder levels (−6.33 and −7.27). The more severe method is used.
- The walk-forward backtest passes these full-sample levels into every year, because an early year has too few closures to fit a tail. That is a look-ahead, but only in the conservative direction.

### 4. What was not done, and why
- **No hand-typed historical 2000–2015 gaps.** Without licensed data they cannot be verified, and an unverifiable number in the tail is worse than a documented model.
- **No inflation of σ or of the σ floors.** The published σ tracks the regime, and a σ haircut would raise every premium in calm weeks without touching the tail shape that is actually missing.

## Effect (Alpaca SIP 2016-01 → 2026-09; `calibration/out/validation/README.md` has every set)
| Item | History only | Published (with A and B) |
| --- | --- | --- |
| Sets where t₃ is more severe at i* | 4 of 18 (every HOLIDAY_WEEKEND set of MEGA_TECH and SPY) | 0 of 18 |
| NVDA / AAPL / MSFT HOLIDAY_WEEKEND z at i* (N = 1,472) | −5.02σ | −5.86σ |
| SPY HOLIDAY_WEEKEND z at i* (N = 1,104) | −4.40σ | −5.31σ |
| SPY WEEKEND / OVERNIGHT z at i* | −6.12σ / −5.99σ | −6.28σ / −6.28σ |
| Safe factor at σ = 4% (MEGA_TECH holiday) | 77.52% | 74.26% (t₃: 74.12%) |
| G-22 premium on the MEGA_TECH holiday set | $0.00 | $2.94 |
| Weekend sets of MEGA_TECH / HIGH_VOL at i* | −7.21σ | unchanged; only the extreme minimum deepens |
| Worst joint loss, reference book ($1M per market, all covered at max LTV, today's σ) | $16,459 | $107,571 (×6.5) |
| Pool equity needed for that book at u_max = 50% | $32,917 | $215,141 |

The floor changes nothing where the history is already fatter than t₃, which is 14 of 18 sets, including every overnight and HIGH_VOL set. The pooled history is *more* severe than the stand-in there, so the docs' worked examples understate the tail at σ = 4%: on the weekend sets the safe factor is 69.03% against the stand-in's 74.12%. The synthetic closures are the real cost: they make the capacity check about six times stricter for a book that is fully covered at max LTV. The backtest (the proposal) reports the capacity binding rate this causes.

## What longer data would change
- **Sets:** 2000–2015 adds about 860 non-overnight closures per name, several of them from crisis regimes (2001, 2008, 2011, 2015). The pooled i* would come from real events, and the t₃ floor would likely stop binding on the holiday sets.
- **Joint set:** real multi-weekend stress clusters (October 2008) would replace the two `uniform` synthetic closures. The `since2000` level would become an observation, not a fit.
- **σ floors:** the 25th percentile of σ over 26 years would include the calm of 2004–2006 and 2013–2014. The floors could move either way; they only bind in calm markets.
- **Backtest:** 2008 would be out-of-sample, and the walk-forward breach test would have about 2.8× the trials (2002–2026 against 2018–2026). The per-asset breach intervals in the proposal are wide because only 2018–2026 is walk-forward.
- The proposal names the parameters a longer history would most likely move. Each is a governance change, not a code change.

## Consequences
- Every hash changes relative to the `dev-unlicensed` outputs. The data are the same; the label and the tail are new.
- Changing TAIL_P, the degrees of freedom, the POT threshold or the horizons is a recalibration proposal.
- ADR-0201's licence table stays valid as a record of what was measured. Its decision section is replaced by this ADR.
