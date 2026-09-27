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
  CredenceStockToken CredenceTreasuryFund ComplianceRegistry Faucet

.PHONY: abis-check local-deploy-clock contracts-deps contracts-build contracts-test contracts-invariant contracts-coverage contracts-fmt \
  contracts-fmt-check contracts-snapshot contracts-clean abis-export risk-build risk-test risk-lint risk-fmt stylus-test stylus-abi-check \
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

contracts-coverage: contracts-deps ## Line coverage (lcov); fails if src/clock or src/oracle is below 95%
	@mkdir -p $(CONTRACTS_DIR)/coverage
	cd $(CONTRACTS_DIR) && forge coverage --ir-minimum --skip script --report summary --report lcov \
	  --no-match-coverage '(test|script|lib)/' | tee coverage/summary.txt
	python3 $(CONTRACTS_DIR)/script/check_coverage.py $(CONTRACTS_DIR)/lcov.info src/clock src/oracle 95

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
	cargo test -p credence-risk-core -p credence-risk-cli

RISK_CRATES := -p credence-risk-core -p credence-risk-cli -p credence-risk-engine -p credence-risk-engine-diff

risk-lint: ## rustfmt check + clippy -D warnings on the blockchain crates
	cargo fmt $(RISK_CRATES) -- --check
	cargo clippy $(RISK_CRATES) --all-targets -- -D warnings

risk-fmt: ## Format the blockchain Rust crates
	cargo fmt $(RISK_CRATES)

stylus-test: ## Native unit tests of the Stylus Risk Engine (TestVM)
	cargo test -p credence-risk-engine

stylus-check: ## cargo stylus check of the Risk Engine against the devnode (size ≤ 1 fragment + activation)
	WS=$$(bash $(STYLUS_DIR)/scripts/stylus-ws.sh) && cd $$WS && \
	  cargo stylus check --endpoint $(DEVNODE_RPC) --contract credence-risk-engine

stylus-export-abi: ## Print the Stylus Risk Engine Solidity ABI
	cargo run -q -p credence-risk-engine --features export-abi --bin credence-risk-engine

stylus-abi-check: ## Every engine function / error exists with the same selector in deployments/abis/v0/IRiskEngine.json
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

devnode-up: ## Ensure a local nitro-devnode answers on :8547 (delegates to `make infra-up`)
	@bash $(STYLUS_DIR)/scripts/devnode.sh up

devnode-down: ## Stop the local nitro-devnode container
	@bash $(STYLUS_DIR)/scripts/devnode.sh down

devnode-deploy-engine: ## Deploy + activate the Stylus Risk Engine on the devnode; records it in deployments/<chainId>.local.json
	DEVNODE_RPC=$(DEVNODE_RPC) DEVNODE_KEY=$(DEVNODE_KEY) bash $(STYLUS_DIR)/scripts/deploy.sh

stylus-diff: ## Differential test: $(DIFF_N) random inputs per function, native risk-core vs the deployed engine (+ gas)
	PRIVATE_KEY=$(DEVNODE_KEY) cargo run --release -p credence-risk-engine-diff -- --rpc $(DEVNODE_RPC) \
	  --n $(DIFF_N) --gas
