# Quant Engineer (QE) targets. Owner: QE. Calibration pipeline, Build Guide §10.6.
# Python lives in calibration/.venv (uv). Rust builds, if any, use CARGO_TARGET_DIR=target/quant (charter §2a).

UV      ?= uv
VENDOR  ?= alpaca
CAL      = cd calibration && $(UV) run --frozen
CAL_OUT ?= calibration/out
QE_CARGO = CARGO_TARGET_DIR=target/quant cargo
RISK_CLI ?= target/quant/release/risk-cli

.PHONY: cal-install cal-data cal-verify cal-crosscheck cal-all cal-sample cal-test cal-vectors cal-risk-cli cal-validate

cal-install: ## QE: sync the calibration env (uv), then build risk-py (credence_risk) into it with target/quant
	cd calibration && $(UV) sync --frozen
	$(MAKE) --no-print-directory risk-py-develop RISK_PY_VENV=calibration/.venv CARGO_TARGET_DIR=target/quant

cal-data: ## QE: pull raw vendor data and rewrite the pinned manifest (VENDOR=alpaca|tiingo, END=YYYY-MM-DD)
	$(CAL) python -m credence_cal.data pull --vendor $(VENDOR) $(if $(END),--end $(END))

cal-verify: ## QE: check calibration/data/raw against the committed manifest
	$(CAL) python -m credence_cal.data verify --vendor $(VENDOR)

cal-all: ## QE: rebuild every calibration output (sets, σ, validation, backtest, proposal) from the pinned raw data (VENDOR=alpaca|tiingo)
	$(CAL) python -m credence_cal.pipeline all --vendor $(VENDOR)

cal-vectors: ## QE: regenerate the σ spec test vectors (calibration/docs/sigma-vectors.json)
	$(CAL) python -m credence_cal.sigma_vectors

cal-test: ## QE: calibration unit tests (offline)
	$(CAL) pytest -q

cal-sample: ## QE: rebuild every output from the committed synthetic sample into calibration/out-sample (CI)
	$(CAL) python -m credence_cal.pipeline core --vendor sample --out out-sample

cal-risk-cli: ## QE: build risk-cli into target/quant (engine math for the backtest fallback and validate-set)
	$(QE_CARGO) build --release -p credence-risk-cli

cal-validate: cal-risk-cli ## QE: run risk-cli validate-set on every scenario set and joint file (CAL_OUT=calibration/out|out-sample)
	@set -e; for f in $(CAL_OUT)/scenarios/*.json $(CAL_OUT)/joint/*.json; do \
	  $(RISK_CLI) validate-set $$f >/dev/null || { echo "INVALID: $$f"; exit 1; }; done; \
	echo "validate-set: every file in $(CAL_OUT) passes"

cal-crosscheck: ## QE: cross-check the pinned Alpaca bars against Polygon official open/close (last 2 years, ~10 min)
	$(CAL) python -m credence_cal.data crosscheck
