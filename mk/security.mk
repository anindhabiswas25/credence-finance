# Credence Finance: QA / security targets (owner: QA-sec, charter §2). Included by the root Makefile.
# Every tool is pinned and project-local (.tools/, git-ignored); every output goes to target/qa/.
# Heavy jobs are niced and use 4 forge threads (charter §2a: three engineers share the machine).

SEC_OUT        := target/qa
SLITHER_VER    := 0.11.3
ADERYN_TAG     := aderyn-v0.6.8
ADERYN_VER     := 0.6.8
# Aderyn ≥ 0.6 needs nightly features; this is the nightly already pinned for the Stylus artifact (R-24, ADR-0102).
ADERYN_RUST    := nightly-2025-08-01
SEC_NICE       ?= nice -n 19
SEC_THREADS    ?= 4
SEC_FORGE_ENV  := FOUNDRY_OUT=$(CURDIR)/$(SEC_OUT)/forge-out FOUNDRY_CACHE_PATH=$(CURDIR)/$(SEC_OUT)/forge-cache
SEC_UV_ENV     := UV_CACHE_DIR=$(CURDIR)/.tools/uv-cache UV_TOOL_DIR=$(CURDIR)/.tools/uv-tools
SLITHER        := uvx --from slither-analyzer==$(SLITHER_VER) slither
ADERYN         := $(CURDIR)/.tools/bin/aderyn
SEC_SUITES     := test/{security,fuzz}/**
# Open findings (triage QA-01..06): tests that assert the fixed behaviour; skipped unless QA_FINDINGS=1.
SEC_FINDINGS   := QA0|gdaBuy_poolNavIsFinal|gdaBuy_settleEpoch

.PHONY: security-tools security-slither security-aderyn security-static security-test security-findings \
  security-invariants security-invariants-bg security-invariants-status security-all

security-tools: ## Install pinned Slither (uvx, cache in .tools/) and Aderyn (cargo from the release tag, .tools/bin)
	@mkdir -p .tools $(SEC_OUT)
	$(SEC_UV_ENV) $(SLITHER) --version
	@if [ -x $(ADERYN) ] && $(ADERYN) --version | grep -q "$(ADERYN_VER)"; then $(ADERYN) --version; else \
	  CARGO_TARGET_DIR=$(SEC_OUT) CARGO_BUILD_JOBS=4 $(SEC_NICE) cargo +$(ADERYN_RUST) install --locked --root .tools \
	    --git https://github.com/Cyfrin/aderyn --tag $(ADERYN_TAG) aderyn; fi

security-slither: contracts-deps security-tools ## Slither on contracts/src → target/qa/slither.{json,md}; fails on an untriaged high/medium
	@rm -f $(SEC_OUT)/slither.json
	-cd contracts && $(SEC_FORGE_ENV) $(SEC_UV_ENV) $(SEC_NICE) $(SLITHER) . --filter-paths "lib/|test/|script/" --exclude-dependencies \
	  --json $(CURDIR)/$(SEC_OUT)/slither.json --checklist --markdown-root . \
	  > $(CURDIR)/$(SEC_OUT)/slither.md 2> $(CURDIR)/$(SEC_OUT)/slither.log
	@test -s $(SEC_OUT)/slither.json || { echo "slither produced no report (see $(SEC_OUT)/slither.log)"; exit 1; }
	python3 docs/security/tools/triage_check.py slither $(SEC_OUT)/slither.json docs/security/triage.md

security-aderyn: contracts-deps security-tools ## Aderyn on contracts/src → target/qa/aderyn.{json,md}; fails on an untriaged high
	cd contracts && $(SEC_FORGE_ENV) $(SEC_NICE) $(ADERYN) . -s src -o $(CURDIR)/$(SEC_OUT)/aderyn.json > $(CURDIR)/$(SEC_OUT)/aderyn.log 2>&1
	cd contracts && $(SEC_FORGE_ENV) $(SEC_NICE) $(ADERYN) . -s src -o $(CURDIR)/$(SEC_OUT)/aderyn.md >> $(CURDIR)/$(SEC_OUT)/aderyn.log 2>&1
	python3 docs/security/tools/triage_check.py aderyn $(SEC_OUT)/aderyn.json docs/security/triage.md

security-static: security-slither security-aderyn ## Both static analyzers and the triage gate

security-test: contracts-deps ## Reentrancy, inflation / rounding fuzz (profile.ci: 10,000 runs) and the QA-sec invariants
	cd contracts && $(SEC_FORGE_ENV) FOUNDRY_PROFILE=ci $(SEC_NICE) forge test --threads $(SEC_THREADS) --match-path '$(SEC_SUITES)'

security-findings: contracts-deps ## The open-finding tests (QA_FINDINGS=1): each fails until its REQUEST is fixed
	cd contracts && QA_FINDINGS=1 $(SEC_FORGE_ENV) $(SEC_NICE) forge test --threads $(SEC_THREADS) --match-path '$(SEC_SUITES)' \
	  --match-test '$(SEC_FINDINGS)'

security-invariants: contracts-deps ## The whole §14.2 catalogue + QA-sec invariants at 512 runs × depth 256 (profile.ci; CPU-heavy)
	cd contracts && $(SEC_FORGE_ENV) FOUNDRY_PROFILE=ci $(SEC_NICE) forge test --threads $(SEC_THREADS) \
	  --match-path 'test/{invariant,security/invariant}/*' --match-test '^invariant'

security-invariants-bg: ## security-invariants detached (setsid + systemd-inhibit), log target/qa/invariants-512x256.log
	docs/security/tools/long_run.sh start $(SEC_OUT)/invariants-512x256.log -- /usr/bin/time -v $(MAKE) security-invariants

security-invariants-status: ## RUNNING / DONE exit=N / ABORTED for the detached invariant run
	@docs/security/tools/long_run.sh status $(SEC_OUT)/invariants-512x256.log

security-all: security-static security-test ## Static analysis + the security suites (not the 512 × 256 run)
