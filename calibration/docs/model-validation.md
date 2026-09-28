# Model validation note: the calibrated scenario sets against the docs' t₃ stand-in

Owner: QE · Sprint 2 · brief item 9 · Decision record: ADR-0204 (free data, tail compensation) · Generated tables: [`calibration/out/validation/README.md`](../out/validation/README.md) (`make cal-all`; every number is risk-core output via `credence_cal.engine`)

**Audience: the PM, for the worked examples.** The Architecture, the money docs and Guide §2.3 / Appendix A price closure risk with a stand-in: a unit-variance Student-t with 3 degrees of freedom. At α = 0.1% its quantile is z = −5.897σ, so the safe factor `g = (1 + σ z)(1 − κ)` is 79.84% / 74.12% / 71.26% / 62.67% at σ = 3% / 4% / 4.5% / 6%. The protocol actually uses the calibrated scenario sets: pooled historical z (ADR-0203), Alpaca SIP 2016-01 → 2026-09, `dataGrade: "free-2016"`, with the t₃ tail floor of ADR-0204.

## 1. Where history is more severe than the stand-in (14 of 18 sets)
| Sets | z at i* (α = 0.1%) | Safe factor at σ = 4% (t₃: 74.12%) | Why |
| --- | --- | --- | --- |
| OVERNIGHT, MEGA_TECH (NVDA, AAPL, MSFT) | −11.14σ | 53.76% | Earnings gaps: jumps the EWMA σ cannot anticipate (sd(z) ≈ 1.24, ADR-0202) |
| OVERNIGHT, HIGH_VOL (TSLA, COIN) | −9.38σ | 60.62% | Earnings and crypto-news gaps |
| WEEKEND, MEGA_TECH and HIGH_VOL | −7.21σ | 69.03% | 2024-08-05 (the carry unwind), 2020-03-16, single-name weekend news |
| HOLIDAY_WEEKEND, HIGH_VOL | −7.32σ | 68.58% | Padded with the group's weekends (ADR-0203) |
| WEEKEND / OVERNIGHT, SPY | −6.12σ / −5.99σ history; −6.28σ published | 72.65% published | 2020 and 2024-08-05; the floor adds a little at i* |

**For the worked examples, this means** a doc example at σ = 4% overstates the safe LTV of a weekend by about 5 pp (74.12% against 69.03%) and of an overnight by up to 20 pp. **But σ is not 4% today.** The published weekend σ (`out/sigma`) is 1.07% (AAPL) to 2.86% (COIN). At today's σ every market's safe LTV is capped at its LTV_max of 75% (SPY 80%), except COIN OVERNIGHT at 73.46%. The docs' stories (σ 4–6% after a shock) are regimes the chain reaches only after a volatility spike. The PM can keep the t₃ numbers as illustrations if the text adds that "calibrated weekend sets are about 5 pp stricter at the same σ". Scenario tests inject the doc premiums anyway (Appendix A).

## 2. Where history is less severe (4 of 18 sets) and what was done
The HOLIDAY_WEEKEND sets of MEGA_TECH (N = 1,472) and SPY (N = 1,104). There are about 9 holiday closures a year, and 2016–2026 had no holiday-weekend crash:

| Set | z at i*: t₃ / history / published | Safe factor at σ = 4%: history → published | G-22 premium: history → published |
| --- | --- | --- | --- |
| NVDA, AAPL, MSFT HOLIDAY_WEEKEND | −5.90 / −5.02 / −5.86 | 77.52% → 74.26% | $0.00 → $2.94 |
| SPY HOLIDAY_WEEKEND | −5.90 / −4.40 / −5.31 | 79.91% → 76.39% | $0.00 → $2.65 |

With history alone these sets would have priced a Thanksgiving closure as *safer than a normal weekend*, which is wrong. The t₃ floor (ADR-0204 §2) brings them back to roughly the stand-in. SPY stays slightly milder than −5.90σ at i* because N = 1,104 puts i* = 1 at a plotting position of 0.136%. That is the price of a short set, and it is documented rather than hidden.

## 3. The joint stress set (capacity)
The 2016–2026 history has one market-wide gap crash at the scale that matters, 2024-08-05, at basket z −6.73. ADR-0204 §3 adds four synthetic closures at the POT return levels −8.16 (2000→today) and −9.33 (40 years), each as a scaled 2024-08-05 cross-section and as all-assets-equal. For a reference book of $1M of collateral per market, all covered at max LTV, at today's σ:

- worst joint loss: $16,459 from history only, $107,571 with the synthetic closures (**×6.5**);
- pool equity needed at u_max = 50%: $32,917 from history only, $215,141 with the synthetic closures.

This is the deliberate cost of the missing 2000–2015 tail. The backtest's capacity binding rate (proposal) shows whether it binds in practice.

## 4. Known limitations
- **Survivorship:** the comparable groups are today's large names (ADR-0203), which understates the tail. The t₃ floor partly offsets this.
- **Discreteness:** a finite set cannot reach the continuous t₃ tail beyond 1/(2N). The G-22 premium on an N = 3,000 t₃ set is $3.59, against the docs' continuous $4.39. The chain prices on the finite set, so the doc figures overstate the premium under the same model by about 20%.
- **z scale:** the weekend and holiday z of the chosen σ blend have sd 1.07–1.09, not 1. The sets carry that (FHS), and the t₃ comparison is in the same units the engine uses.
- **Data:** 10.7 years of free, personal-licence data. The re-pull on licensed 2000+ data is one command (ADR-0204 §1). §5 of that ADR lists what it would change.
