# Quant Engineer (QE) targets. Owner: QE. Calibration pipeline, Build Guide §10.6.
# Python lives in calibration/.venv (uv). Rust builds, if any, use CARGO_TARGET_DIR=target/quant (charter §2a).

UV      ?= uv
VENDOR  ?= alpaca
CAL      = cd calibration && $(UV) run --frozen

.PHONY: cal-install cal-data cal-verify cal-crosscheck cal-all cal-sample cal-test cal-vectors

cal-install: ## QE: sync the calibration env (uv) and build risk-py into it
	cd calibration && $(UV) sync --frozen

cal-data: ## QE: pull raw vendor data and rewrite the pinned manifest (VENDOR=alpaca|tiingo, END=YYYY-MM-DD)
	$(CAL) python -m credence_cal.data pull --vendor $(VENDOR) $(if $(END),--end $(END))

cal-verify: ## QE: check calibration/data/raw against the committed manifest
	$(CAL) python -m credence_cal.data verify --vendor $(VENDOR)

cal-all: ## QE: rebuild every calibration output from the pinned raw data (VENDOR=alpaca|tiingo)
	$(CAL) python -m credence_cal.pipeline all --vendor $(VENDOR)

cal-vectors: ## QE: regenerate the σ spec test vectors (calibration/docs/sigma-vectors.json)
	$(CAL) python -m credence_cal.sigma_vectors

cal-test: ## QE: calibration unit tests (offline)
	$(CAL) pytest -q
