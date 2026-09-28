# Sprint 2 report · Quant Engineer (QE)

Date: 2026-09-28 · Session model: Claude Opus 5.5 (resumed session after the 02:45 rate-limit cutoff) · Commits (this session): `e9e3e05..HEAD` (QE commits: e9e3e05, e12fdb3, 7f4214d, e907ecd, 4aa6676, 08dd81f, 185349d, da243ae, 91ffa50, plus this report)

## 1. Summary
The calibration pipeline is complete on the free data the user chose: Alpaca SIP daily bars 2016-01-04 → 2026-09-25, cross-checked against Polygon's official prints (36 of 36 closures match to 0 bp), with every output labelled `dataGrade: "free-2016"`. ADR-0204 supersedes ADR-0201 and compensates for the missing 2000–2015 tail explicitly: a t₃ floor on the tail of every scenario set, and four synthetic stress closures at the head of the joint set.

All 18 scenario sets and the K = 256 joint set are in BE-chain's ADR-0106 format, built and validated by risk-core itself. The backtest runs entirely through risk-py. The walk-forward breach rate is 0.049% against α = 0.1%, there are no senior-loss events, and the pool earns 11.9% a year on J0. The S2 testnet proposal confirms α 0.1%, κ 3%, θ 100%, u_max 50% and η 4, and ships as a validated `credence.risk-bundle/v1` plus the ABI calldata for the timelock. `make cal-all` rebuilds every output bit for bit from the pinned raw data.

**Not done:** loading the bundle on the devnode (acceptance 2, second half) is blocked on BE-chain's S2 Stylus engine (`setJointColumn`/`jointHash`) and on a running devnode (board REQUEST 12:15). The J7 cross-check of the σ vectors (acceptance 3) is pending BE-backend in wave 2.

## 2. Acceptance checklist
| # | Item | Status | Proof (command + key output) |
| --- | --- | --- | --- |
| 1 | `make cal-all` reproduces every output hash from the pinned data; the CI sample check passes | ✅ (CI itself not run on GitHub: nothing is pushed) | `rm -rf calibration/data/work/alpaca && make cal-verify cal-all && git status --short calibration` → `37 symbols match manifest-alpaca`, then no changes (12 min; every file in `calibration/out/HASHES.alpaca.json` byte-identical). CI equivalent: `make cal-sample && git diff --exit-code -- calibration/out-sample` → clean (re-run twice) |
| 2a | Scenario sets for 6 assets × 3 closure types plus the joint K = 256 set pass `risk-cli validate-set` | ✅ | `make cal-validate` → `valid:` for 18 sets, `joint-4dcad6d1.json` and `risk-bundle-889d50e4.json`, then `validate-set: every file in calibration/out passes` (also `CAL_OUT=calibration/out-sample`). A tampered file is rejected with exit 1 (checked manually) |
| 2b | The sets load on the local devnode through BE-chain's script, and the on-chain `scenarioHash` matches | ❌ **blocked on BE-chain** | Needs the S2 engine with `setJointColumn`/`jointHash` (ADR-0106 §5, BE-chain item C) and a running devnode (`:8547` is down). REQUEST on the board at 12:15. Once READY: `make risk-load-set RISK_BUNDLE=calibration/out/risk-bundle-889d50e4.json` (the script reads back every `scenarioHash`/`jointHash`; the expected values are in each file and in `calibration/out/proposal/calldata-fb8a9e82.json`) |
| 3 | σ spec with test vectors published; BE-backend's J7 reproduces them | ⚠️ **pending BE-backend (wave 2)** | Published: `calibration/docs/sigma.md`, `calibration/docs/sigma-vectors.json` (READY 10:05; `uv run --frozen pytest -q tests/test_sigma.py` checks the vectors are current). The vectors are synthetic and independent of the data relabel. **The keeper's resume snapshot is now `calibration/out/sigma/sigma-84d3ee7a661db5f3.json`** (`free-2016`) |
| 4 | Backtest covers every item-6 metric and runs through risk-py | ✅ | `make cal-all` (stage `backtest`, engine `PyEngine`) → `calibration/out/backtest/README.md`: breach frequency vs α per asset and type with exact 95% CIs and Kupiec p, every breach event named; P&L distribution, worst epoch, worst full year, capacity binding rate; senior-loss events (0); sensitivity to α, κ, θ, u_max and η. `pytest tests/test_engine.py::test_py_and_cli_agree_call_by_call` shows risk-py and risk-cli return identical integers for every call the backtest makes |
| 5 | Proposal names α, κ, θ with reasoning; calldata JSON produced | ✅ | `calibration/out/proposal/2026-09-28.md`; `calibration/out/risk-bundle-889d50e4.json` (what `LoadScenarioSet.s.sol` consumes); `calibration/out/proposal/calldata-fb8a9e82.json` (43 ABI-encoded engine writes; `pytest tests/test_proposal.py` checks the encoders against `cast calldata`) |
| 6 | Report from the template; ADRs for data licensing and every methodological choice | ✅ | This file; ADR-0204 (free data, licence, tail compensation; supersedes ADR-0201), ADR-0202 (σ), ADR-0203 (pooling, joint set) |

## 3. What was built
- `calibration/credence_cal/engine.py`: the only door to engine math. `PyEngine` (risk-py, the default) and `CliEngine` (risk-cli) share one interface, including the ADR-0106 builders (`build_set`, `build_joint`, `validate_file`).
- `calibration/credence_cal/backtest.py`: walk-forward and in-sample replay against the synthetic book (the method is in the module docstring), breach statistics, sensitivity, and the report.
- `calibration/credence_cal/sets.py`: `t3_floor` / `tail_floor` (ADR-0204 A) and `stress_levels` plus the synthetic closures in `joint` (ADR-0204 B).
- `calibration/credence_cal/setfile.py`: ADR-0106 documents through risk-core, named by `contentHash`.
- `calibration/credence_cal/validation.py` + `calibration/docs/model-validation.md`: brief item 9, the sets against the t₃ stand-in, for the PM's worked examples.
- `calibration/credence_cal/proposal.py`: the risk bundle, the timelock calldata and the proposal markdown.
- `calibration/credence_cal/data.py`: `crosscheck` against Polygon; `calibration/manifests/crosscheck-alpaca-polygon.json`.
- `calibration/credence_cal/pipeline.py`: stages `gaps → sigma → sets → validation → backtest → proposal`; `core` = the first four (the CI sample check).
- `mk/quant.mk`: `cal-install` (uv sync + risk-py into `calibration/.venv`, `target/quant`), `cal-verify`, `cal-crosscheck`, `cal-all`, `cal-sample`, `cal-risk-cli`, `cal-validate`, `cal-test`, `cal-vectors`.
- `.github/workflows/calibration.yml`: install, risk-cli, unit tests, sample rebuild, hash diff, validate-set.
- Outputs: `calibration/out/{scenarios,joint,sigma,quality,validation,backtest,proposal}/`, `calibration/out/risk-bundle-889d50e4.json`, `calibration/out/HASHES.alpaca.json`; `calibration/out-sample/` (CI).

## 4. Test results
- `make cal-test` → `42 passed` (offline, about 3 s; the risk-cli, risk-py and cast checks skip when a tool is missing).
- `make cal-validate` → every file in `calibration/out` passes; `make cal-validate CAL_OUT=calibration/out-sample` → passes.
- `make cal-all` from scratch → no diff against the committed outputs (12 min 26 s, of which the backtest is about 11 min).
- Key results (walk-forward 2018-01 → 2026-09): breaches 6 / 12,261 = 0.049% (CI 0.018–0.107%); WEEKEND 0.181% (CI 0.049–0.463%); OVERNIGHT 0.021%; HOLIDAY_WEEKEND 0 / 468. Pool: +11.86% a year on J0 = $2M; worst epoch 2022-05-11 −$10,612 (0.53% of J0); every full year profitable; capacity binds in 0.27% of epochs; senior-loss events 0 (in-sample since 2016-04 also 0).

## 5. Deviations from the Build Guide
- **§10.6 step 1 / brief item 1 (20+ years since 2000)** → Alpaca SIP from 2016 (free, personal licence), because the user will not buy data (PM ANSWER 11:45). The missing tail is compensated explicitly → ADR-0204.
- **§10.6 step 7 ("replay every weekend since 2000")** → every closure since the data start in-sample (2016-04 →), and walk-forward from 2018 (the first year with enough prior data for out-of-sample sets). The synthetic stress levels in the walk-forward use the full sample, a look-ahead in the conservative direction only → ADR-0204, `backtest.py` docstring.
- **§10.6 step 4 (sets are pooled history)** → pooled history with a t₃ tail floor below the 2.5% quantile → ADR-0204.
- **§10.6 step 5 (joint set = the K worst historical weekends)** → 4 synthetic + 252 historical closures (K unchanged) → ADR-0204.
- The backtest does not replay the engine's 10%/day σ rate limit. It can only raise σ, so the breach counts are an upper bound (`backtest.py` docstring).

## 6. Spec issues found
- **§12.2 / R-03 with the pooled overnight sets:** 93% of premiums are overnight covers ($10.58 per cover against $3.14 for a weekend), because the pooled overnight set carries every comparable name's earnings gap (z at i* −11.1σ). A loan held at the cap every weeknight pays several percent a year. Suggestion: a scheduled-earnings attribute on the closure (earnings set vs ex-earnings set). That is a spec change, so it is only proposed (proposal §3).
- **Appendix A G-22 / the docs' t₃ premiums:** the chain prices on a finite set. On an N = 3,000 t₃ set the G-22 premium is $3.59, against the docs' continuous $4.39. The doc figures therefore overstate the premium under the same model by about 20% (model-validation note §4). Scenario tests already inject the doc premiums, so nothing breaks.
- **§2.3 worked examples at σ = 4%:** the calibrated weekend sets are about 5 pp stricter than the t₃ stand-in (69.03% against 74.12%), and the overnight sets up to 20 pp stricter. At today's σ, every safe LTV except COIN overnight is capped at LTV_max anyway (model-validation note §1).

## 7. Interfaces changed or published
- **For BE-chain:** `calibration/out/scenarios/*.json` and `calibration/out/joint/joint-4dcad6d1.json` (ADR-0106 v1, stable), `calibration/out/risk-bundle-889d50e4.json`, `calibration/out/proposal/calldata-fb8a9e82.json`. The names change only on recalibration.
- **For BE-backend (J7):** the σ spec and vectors are unchanged (READY 10:05). The resume snapshot file is now `calibration/out/sigma/sigma-84d3ee7a661db5f3.json` (`dataGrade: "free-2016"`; same numbers as the `dev-unlicensed` file, new label). The ρ² constants and floors are in it.
- `calibration/out/calendars/*` are unchanged (format frozen at v1).

## 8. Known gaps and TODOs
- Acceptance 2b: devnode load and `scenarioHash` read-back (BE-chain S2 engine plus devnode; board REQUEST 12:15).
- Acceptance 3: BE-backend's J7 ANSWER (wave 2).
- `.github/workflows/calibration.yml` has not run on GitHub (nothing pushed). Its steps were run locally.
- The backtest book is synthetic (40 loans per market, seeded). Real testnet positions should replace it in the S3+ recalibration.
- Survivorship in the comparable groups (ADR-0203) remains. A licensed full-history pull should add delisted names.

## 9. Needs from the user or the PM
- Before mainnet: re-open the data licence (ADR-0204 §1). A licensed 2000+ history is `make cal-data cal-all VENDOR=tiingo` away and is the evidence that could justify lowering θ.
- PM decision on the earnings-night finding (§6, first bullet).

## 10. How to verify from a clean checkout
```sh
make cal-install                       # uv env + risk-py (target/quant)
make cal-test                          # 42 passed
make cal-sample && git diff --exit-code -- calibration/out-sample   # the CI check
make cal-validate CAL_OUT=calibration/out-sample
# with the pinned raw data in calibration/data/raw/alpaca (not in git; `make cal-data END=2026-09-25` re-pulls it):
make cal-verify                        # 37 symbols match manifest-alpaca
make cal-all && git status --short calibration   # no output = every hash reproduced
make cal-validate                      # 18 sets + joint + bundle valid
make cal-crosscheck                    # optional, about 10 min: Alpaca vs Polygon, 36/36 at 0 bp
# once BE-chain posts the S2 engine READY and the devnode is up:
make risk-load-set RISK_BUNDLE=calibration/out/risk-bundle-889d50e4.json
```
