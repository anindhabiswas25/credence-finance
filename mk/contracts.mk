# Credence Finance: blockchain targets (owner: BE-chain). Included by the root Makefile.
# Every target has a `## help` comment; `make help` lists them.

CONTRACTS_DIR   := contracts
# v0 is frozen history (S1); v1 = S2 (ADR-0104). Never re-export v0.
ABI_VERSION     ?= v1
ABI_OUT         := deployments/abis/$(ABI_VERSION)
DEVNODE_RPC     ?= http://127.0.0.1:8547
# Pre-funded dev key of nitro-devnode (public, local only; never used on a real network).
DEVNODE_KEY     ?= 0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659
STYLUS_DIR      := stylus/risk-engine
DIFF_N          ?= 10000

# Pinned Solidity dependencies (Build Guide §6.2). Installed on demand; contracts/lib is not committed.
OZ_TAG          := v5.6.1
FORGE_STD_TAG   := v1.16.2
SOLADY_TAG      := v0.1.26

# Interfaces and libraries whose ABIs are frozen per release (deployments/abis/<version>/<Name>.json).
ABI_CONTRACTS := ICredenceErrors ICalendarStore IAssetClock IPriceSource INavSource ICredencePriceFeed ITwapSource \
  IOracleAdapter ISequencerHealth ICredenceMarket ISeniorVault IUnderwriterPool IAuctionHouse ISettlementAdapter \
  ISolverVenue ISolverAuction IRiskEngine ISigmaOracle IKeeperTips IProtocolReserve ITreasury ICredenceGuardian \
  ICollateralToken INavFund ICompliance IComplianceRegistry IFaucet
# Implementations built this sprint (their ABIs add admin functions and constructor args to the interfaces).
ABI_IMPLS ?= CalendarStore AssetClock CredencePriceFeed OracleAdapter SequencerHealth UniV3TwapSource \
  CredenceStockToken CredenceTreasuryFund ComplianceRegistry Faucet CredenceMarket SeniorVault SigmaOracle \
  KeeperTips Treasury ProtocolReserve CredenceGuardian CredenceTimelock RiskEngineRouter

.PHONY: abis-check local-deploy-clock contracts-deps contracts-build contracts-test contracts-invariant contracts-coverage contracts-fmt \
  contracts-fmt-check contracts-snapshot contracts-clean abis-export risk-build risk-test risk-lint risk-fmt stylus-test stylus-abi-check \
  stylus-check stylus-export-abi devnode-up devnode-down devnode-deploy-engine stylus-diff risk-validate-set risk-load-set risk-py-develop risk-py-test risk-wasm risk-wasm-test local-deploy-core stylus-repro devnode-integration

contracts-deps: ## Install pinned Solidity deps into contracts/lib (OZ, forge-std, solady) if missing
	@cd $(CONTRACTS_DIR) && \
	  { [ -d lib/openzeppelin-contracts ] || forge install --no-git OpenZeppelin/openzeppelin-contracts@$(OZ_TAG); } && \
	  { [ -d lib/forge-std ] || forge install --no-git foundry-rs/forge-std@$(FORGE_STD_TAG); } && \
	  { [ -d lib/solady ] || forge install --no-git Vectorized/solady@$(SOLADY_TAG); }

contracts-build: contracts-deps ## Compile all Solidity contracts (forge build)
	cd $(CONTRACTS_DIR) && forge build

contracts-test: contracts-deps ## Run every Solidity test: unit, fuzz, invariant (256 runs x depth 128), scenario
	cd $(CONTRACTS_DIR) && forge test

contracts-invariant: contracts-deps ## Run only the invariant suites
	cd $(CONTRACTS_DIR) && forge test --match-path 'test/invariant/*'

contracts-coverage: contracts-deps ## Line coverage (lcov); fails if src/core, src/governance, src/clock or src/oracle is below 95%
	@mkdir -p $(CONTRACTS_DIR)/coverage
	@rm -f $(CONTRACTS_DIR)/lcov.info   # a stale report must never pass the gate
	cd $(CONTRACTS_DIR) && FOUNDRY_PROFILE=coverage forge coverage --ir-minimum --skip script --report summary --report lcov \
	  --no-match-coverage '(test|script|lib)/' | tee coverage/summary.txt
	python3 $(CONTRACTS_DIR)/script/check_coverage.py $(CONTRACTS_DIR)/lcov.info src/core src/governance src/clock src/oracle 95

contracts-fmt: ## Format Solidity sources
	cd $(CONTRACTS_DIR) && forge fmt

contracts-fmt-check: ## Check Solidity formatting (CI)
	cd $(CONTRACTS_DIR) && forge fmt --check

contracts-snapshot: contracts-deps ## Write the gas snapshot (contracts/.gas-snapshot)
	cd $(CONTRACTS_DIR) && forge snapshot --no-match-path 'test/invariant/*'

contracts-clean: ## Remove Foundry build output
	cd $(CONTRACTS_DIR) && forge clean

abis-export: contracts-build ## Export frozen ABIs to deployments/abis/$(ABI_VERSION)/*.json
	@mkdir -p $(ABI_OUT)
	@cd $(CONTRACTS_DIR) && for c in $(ABI_CONTRACTS) $(ABI_IMPLS); do \
	  forge inspect $$c abi --json > ../$(ABI_OUT)/$$c.json || exit 1; \
	done
	@echo "exported $$(ls $(ABI_OUT) | wc -l) ABIs to $(ABI_OUT)"

abis-check: ## ABIs v1 are additive over the frozen v0 (except the allowed R-25 break); regenerates v1/CHANGELOG.md
	python3 $(CONTRACTS_DIR)/script/abi_diff.py deployments/abis/v0 deployments/abis/v1 --write deployments/abis/v1/CHANGELOG.md

risk-build: ## Build risk-core and risk-cli (native, release)
	cargo build --release -p credence-risk-core -p credence-risk-cli

risk-test: ## Run risk-core golden vectors G-01..G-22, proptests, and risk-cli tests
	cargo test -p credence-risk-core -p credence-risk-cli -p credence-bindings

RISK_CRATES := -p credence-risk-core -p credence-risk-cli -p credence-bindings -p credence-risk-py -p credence-risk-wasm -p credence-risk-engine -p credence-auction-math -p credence-risk-engine-diff

risk-lint: ## rustfmt check + clippy -D warnings on the blockchain crates
	cargo fmt $(RISK_CRATES) -- --check
	cargo clippy $(RISK_CRATES) --all-targets -- -D warnings

risk-fmt: ## Format the blockchain Rust crates
	cargo fmt $(RISK_CRATES)

stylus-test: ## Native unit tests of the Stylus Risk Engine (TestVM)
	cargo test -p credence-risk-engine -p credence-auction-math

stylus-check: ## cargo stylus check of the Risk Engine against the devnode (size ≤ 1 fragment + activation)
	WS=$$(bash $(STYLUS_DIR)/scripts/stylus-ws.sh) && cd $$WS && \
	  cargo stylus check --endpoint $(DEVNODE_RPC) --contract credence-risk-engine

devnode-integration: ## Market ↔ real Stylus engine on the devnode (dedicated engine + QE bundle + core), vs risk-cli
	LOCAL_RPC=$(DEVNODE_RPC) PRIVATE_KEY=$(DEVNODE_KEY) bash $(CONTRACTS_DIR)/script/devnode_integration.sh

stylus-repro: ## Build both Stylus programs from two fresh clones of HEAD and require identical WASM sha256 (R-24)
	bash $(STYLUS_DIR)/scripts/repro.sh

stylus-export-abi: ## Print the Stylus Risk Engine Solidity ABI
	cargo run -q -p credence-risk-engine --features export-abi --bin credence-risk-engine

stylus-abi-check: ## Engine ABI == deployments/abis/v1/IRiskEngine.json in both directions
	bash $(STYLUS_DIR)/scripts/abi-check.sh

XNYS_CALENDAR   ?= $(firstword $(wildcard calibration/out/calendars/XNYS-*.json))
USBANK_CALENDAR ?= $(firstword $(wildcard calibration/out/calendars/USBANK-*.json))
LOCAL_RPC       ?= $(DEVNODE_RPC)
# Local relayer committees (anvil keys 1-3 by default; the relayer's local signer keys go here).
RELAYER_A_SIGNERS ?= 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,0x90F79bf6EB2c4f870365E785982E1f101E93b906
RELAYER_B_SIGNERS ?= $(RELAYER_A_SIGNERS)

local-deploy-clock: contracts-build ## Deploy the clock + price stack and test assets to LOCAL_RPC; writes deployments/<chainId>.local.json
	cd $(CONTRACTS_DIR) && PRIVATE_KEY=$(DEVNODE_KEY) RELAYER_A_SIGNERS=$(RELAYER_A_SIGNERS) \
	  RELAYER_B_SIGNERS=$(RELAYER_B_SIGNERS) XNYS_CALENDAR=../$(XNYS_CALENDAR) USBANK_CALENDAR=../$(USBANK_CALENDAR) \
	  forge script script/DeployClockLocal.s.sol:DeployClockLocal --rpc-url $(LOCAL_RPC) --broadcast --slow

local-deploy-core: contracts-build ## Deploy the whole S2 protocol (clock, 6 equity markets + TBILL, vaults seeded) to LOCAL_RPC; writes deployments/<chainId>.local.json
	cd $(CONTRACTS_DIR) && PRIVATE_KEY=$(DEVNODE_KEY) RELAYER_A_SIGNERS=$(RELAYER_A_SIGNERS) \
	  RELAYER_B_SIGNERS=$(RELAYER_B_SIGNERS) XNYS_CALENDAR=../$(XNYS_CALENDAR) USBANK_CALENDAR=../$(USBANK_CALENDAR) \
	  forge script script/DeployCoreLocal.s.sol:DeployCoreLocal --rpc-url $(LOCAL_RPC) --broadcast --slow

devnode-up: ## Ensure a local nitro-devnode answers on :8547 (delegates to `make infra-up`)
	@bash $(STYLUS_DIR)/scripts/devnode.sh up

devnode-down: ## Stop the local nitro-devnode container
	@bash $(STYLUS_DIR)/scripts/devnode.sh down

devnode-deploy-engine: ## Deploy + activate the Stylus Risk Engine on the devnode; records it in deployments/<chainId>.local.json
	DEVNODE_RPC=$(DEVNODE_RPC) DEVNODE_KEY=$(DEVNODE_KEY) bash $(STYLUS_DIR)/scripts/deploy.sh

stylus-diff: ## Differential: $(DIFF_N) random inputs per function, native risk-core vs a DEDICATED engine on the devnode (+ gas vs §8.9.3 ceilings)
	@CHAIN=$$(cast chain-id --rpc-url $(DEVNODE_RPC)); BOOK=deployments/$$CHAIN.diff.local.json; \
	  if [ ! -f $$BOOK ] || [ -z "$$(cast code --rpc-url $(DEVNODE_RPC) $$(jq -r .shared.riskEngine $$BOOK) 2>/dev/null | sed 's/^0x$$//')" ]; then \
	    ENGINE_BOOK=$(abspath .)/$$BOOK DEVNODE_RPC=$(DEVNODE_RPC) DEVNODE_KEY=$(DEVNODE_KEY) bash $(STYLUS_DIR)/scripts/deploy.sh; fi; \
	  PRIVATE_KEY=$(DEVNODE_KEY) cargo run --release -p credence-risk-engine-diff -- --rpc $(DEVNODE_RPC) \
	    --book $$BOOK --n $(DIFF_N) --gas --gas-check

# Scenario-set files (ADR-0106). RISK_FILE / RISK_BUNDLE: a set, joint set or bundle; references resolve relative to
# the bundle's directory. Default = the example bundle in contracts/test/fixtures/risk.
RISK_BUNDLE ?= contracts/test/fixtures/risk/example-bundle.json
RISK_FILE   ?= $(RISK_BUNDLE)

risk-validate-set: ## Validate a scenario-set / joint-set / risk-bundle file (RISK_FILE=…) with risk-cli
	cargo run -q --release -p credence-risk-cli -- validate-set $(RISK_FILE)

risk-load-set: ## Validate RISK_BUNDLE, load it into the engine on LOCAL_RPC (RISK_ENGINE= or the address book) and verify every hash
	cargo run -q --release -p credence-risk-cli -- validate-set $(RISK_BUNDLE) > /dev/null
	RISK_ENGINE=$${RISK_ENGINE:-$$(jq -r .shared.riskEngine deployments/$$(cast chain-id --rpc-url $(LOCAL_RPC)).local.json)} \
	  PRIVATE_KEY=$(DEVNODE_KEY) LOCAL_RPC=$(LOCAL_RPC) RISK_BUNDLE=$(abspath $(RISK_BUNDLE)) \
	  RISK_BUNDLE_DIR=$(abspath $(dir $(RISK_BUNDLE))) bash $(CONTRACTS_DIR)/script/load_risk_bundle.sh

# risk-py (PyO3 + maturin). maturin is not installed globally: a pinned `uvx maturin` builds into a project venv
# (board DECISION 09:10). QE: `make risk-py-develop RISK_PY_VENV=calibration/.venv CARGO_TARGET_DIR=target/quant`.
MATURIN      ?= uvx --from maturin==1.9.6 maturin
RISK_PY_VENV ?= crates/risk-py/.venv

risk-py-develop: ## Build crates/risk-py (release) and install `credence_risk` into RISK_PY_VENV (default crates/risk-py/.venv)
	@[ -x $(RISK_PY_VENV)/bin/python ] || uv venv -q $(RISK_PY_VENV)
	VIRTUAL_ENV=$(abspath $(RISK_PY_VENV)) $(MATURIN) develop --release --uv -m crates/risk-py/Cargo.toml

risk-py-test: risk-py-develop ## risk-py smoke test (every function; cross-checked against risk-cli and the ADR-0106 example)
	cargo build -q --release -p credence-risk-cli
	RISK_CLI=$(abspath target/release/risk-cli) $(RISK_PY_VENV)/bin/python crates/risk-py/tests/test_smoke.py

# risk-wasm (wasm-bindgen via wasm-pack 0.15.0). One package, two builds: `node` (CommonJS glue, sync load) for the
# API / SDK tests and `web` (fetch + instantiate) for the web app, behind conditional exports. Output:
# crates/risk-wasm/pkg = `@credence/risk-wasm` (git-ignored; BE-backend depends on it from packages/sdk).
RISK_WASM_PKG := crates/risk-wasm/pkg

risk-wasm: ## Build @credence/risk-wasm into crates/risk-wasm/pkg (node + web builds, conditional exports)
	rm -rf $(RISK_WASM_PKG)
	wasm-pack build crates/risk-wasm --release --no-pack --target nodejs --out-dir pkg/node --out-name credence_risk_wasm
	wasm-pack build crates/risk-wasm --release --no-pack --target web --out-dir pkg/web --out-name credence_risk_wasm
	cp crates/risk-wasm/js/package.json crates/risk-wasm/js/node.mjs crates/risk-wasm/js/web.mjs \
	  crates/risk-wasm/js/index.d.ts $(RISK_WASM_PKG)/
	echo '{ "type": "commonjs" }' > $(RISK_WASM_PKG)/node/package.json
	rm -f $(RISK_WASM_PKG)/node/.gitignore $(RISK_WASM_PKG)/web/.gitignore
	@ls -l $(RISK_WASM_PKG)/web/*.wasm

risk-wasm-test: risk-wasm ## risk-wasm smoke test on Node (both builds; cross-checked against risk-cli)
	cargo build -q --release -p credence-risk-cli
	RISK_CLI=$(abspath target/release/risk-cli) node crates/risk-wasm/tests/smoke.mjs
