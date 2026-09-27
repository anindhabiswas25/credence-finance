# Credence Finance: blockchain targets (owner: BE-chain). Included by the root Makefile.
# Every target has a `## help` comment; `make help` lists them.

CONTRACTS_DIR   := contracts
ABI_VERSION     ?= v0
ABI_OUT         := deployments/abis/$(ABI_VERSION)
DEVNODE_RPC     ?= http://127.0.0.1:8547
# Pre-funded dev key of nitro-devnode (public, local only; never used on a real network).
DEVNODE_KEY     ?= 0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659
DEVNODE_IMAGE   ?= offchainlabs/nitro-node:v3.9.4-7f582c3
DEVNODE_NAME    ?= credence-devnode
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
ABI_IMPLS ?=

.PHONY: contracts-deps contracts-build contracts-test contracts-invariant contracts-coverage contracts-fmt \
  contracts-fmt-check contracts-snapshot contracts-clean abis-export risk-build risk-test risk-lint risk-fmt \
  stylus-check stylus-export-abi devnode-up devnode-down devnode-deploy-engine stylus-diff

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

contracts-coverage: contracts-deps ## Line coverage; fails if src/clock or src/oracle is below 95%
	@mkdir -p $(CONTRACTS_DIR)/coverage
	cd $(CONTRACTS_DIR) && FOUNDRY_PROFILE=coverage forge coverage --report summary --report lcov \
	  --no-match-coverage '(test|script|lib)/' | tee coverage/summary.txt
	@python3 $(CONTRACTS_DIR)/script/check_coverage.py $(CONTRACTS_DIR)/lcov.info src/clock src/oracle 95

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

risk-build: ## Build risk-core and risk-cli (native, release)
	cargo build --release -p credence-risk-core -p credence-risk-cli

risk-test: ## Run risk-core golden vectors G-01..G-22, proptests, and risk-cli tests
	cargo test -p credence-risk-core -p credence-risk-cli

risk-lint: ## rustfmt check + clippy -D warnings on the blockchain crates
	cargo fmt -p credence-risk-core -p credence-risk-cli -p credence-risk-engine -- --check
	cargo clippy -p credence-risk-core -p credence-risk-cli --all-targets -- -D warnings
	cd $(STYLUS_DIR) && cargo clippy --target wasm32-unknown-unknown --lib -- -D warnings

risk-fmt: ## Format the blockchain Rust crates
	cargo fmt -p credence-risk-core -p credence-risk-cli -p credence-risk-engine

stylus-check: ## cargo stylus check of the Risk Engine against the devnode (size + activation check)
	cd $(STYLUS_DIR) && cargo stylus check --endpoint $(DEVNODE_RPC)

stylus-export-abi: ## Print the Stylus Risk Engine Solidity ABI
	cd $(STYLUS_DIR) && cargo stylus export-abi

devnode-up: ## Start a local nitro-devnode (Stylus-capable) on :8547 via docker (until infra/ compose exists)
	@bash $(STYLUS_DIR)/scripts/devnode.sh up

devnode-down: ## Stop the local nitro-devnode container
	@bash $(STYLUS_DIR)/scripts/devnode.sh down

devnode-deploy-engine: ## Deploy + activate the Stylus Risk Engine on the devnode; writes deployments/devnode.engine.json
	@bash $(STYLUS_DIR)/scripts/deploy.sh

stylus-diff: ## Differential test: $(DIFF_N) random inputs, native risk-core vs the deployed Stylus engine
	cargo run --release -p credence-risk-engine-diff -- --rpc $(DEVNODE_RPC) --n $(DIFF_N) \
	  --deployment deployments/devnode.engine.json
