# Backend fragment (owner: BE-backend). Included by the root Makefile.
# Every target has a `## help` comment; `make help` lists them.

BACKEND_RUST_PKGS := -p credence-common -p credence-relayer -p credence-keeper
# Backend crates follow rust-toolchain.toml (1.95.0; alloy 2.5 needs >= 1.94.1, ADR-0005 / ADR-0102).
# Set BACKEND_RUST_TOOLCHAIN=<name> only to override locally.
BACKEND_RUST_TOOLCHAIN ?=
# Charter §2a: BE-backend builds into its own target dir (set per command, never exported to other fragments).
BACKEND_TARGET_DIR ?= target/be
CARGO := CARGO_TARGET_DIR=$(BACKEND_TARGET_DIR) $(if $(BACKEND_RUST_TOOLCHAIN),RUSTUP_TOOLCHAIN=$(BACKEND_RUST_TOOLCHAIN) )cargo
TEST_DATABASE_URL ?= postgres://credence:credence@127.0.0.1:$${POSTGRES_PORT:-5433}/credence
COMPOSE           := docker compose -f infra/docker-compose.yml
UV                := $(shell command -v uv 2>/dev/null || echo $$HOME/.local/bin/uv)

# Node 24 LTS (§6.1). Prefer an nvm-installed v24 when the default node is older.
NVM_NODE24 := $(lastword $(sort $(wildcard $(HOME)/.nvm/versions/node/v24.*/bin)))
ifneq ($(NVM_NODE24),)
export PATH := $(NVM_NODE24):$(PATH)
endif
PNPM := pnpm

.PHONY: backend-install backend-build backend-test backend-lint backend-fmt \
        infra-up infra-down infra-reset infra-ps db-migrate db-rollback calendar-gen calendar-test \
        relayer-dev relayer-smoke keeper-dev indexer-dev api-dev relayer-e2e keeper-e2e indexer-e2e services-up \
        notifier-dev notifier-e2e r26-probe keeper-sigma-test keeper-j12-e2e

backend-install: ## Install backend deps: @credence/risk-wasm (wasm-pack, into target/be), pnpm workspace, uv calibration env, Rust crates fetched
	CARGO_TARGET_DIR=$(BACKEND_TARGET_DIR) $(MAKE) --no-print-directory risk-wasm
	$(PNPM) install --frozen-lockfile
	cd calibration && $(UV) sync --frozen
	$(CARGO) fetch --locked

backend-build: ## Build backend: Rust services (release-less check build) and TS packages
	$(CARGO) build --locked $(BACKEND_RUST_PKGS)
	$(PNPM) turbo run build

backend-test: ## Run backend tests: Rust services, TS packages (sdk, api, indexer), calendar
	$(CARGO) test --locked $(BACKEND_RUST_PKGS)
	$(PNPM) turbo run test
	cd calibration && $(UV) run --frozen pytest -q

backend-lint: ## Lint backend: rustfmt check, clippy -D warnings, eslint, tsc
	$(CARGO) fmt $(BACKEND_RUST_PKGS) -- --check
	$(CARGO) clippy --locked $(BACKEND_RUST_PKGS) --all-targets -- -D warnings
	$(PNPM) turbo run lint typecheck

backend-fmt: ## Format backend code (rustfmt + prettier)
	$(CARGO) fmt $(BACKEND_RUST_PKGS)
	$(PNPM) -r exec prettier --write . --ignore-unknown

infra-up: ## Start postgres 17 + nitro-devnode (Stylus, :8547, chain 412346) and wait until healthy
	$(COMPOSE) up -d --wait postgres devnode devnode-init

infra-down: ## Stop the local stack (the postgres volume is kept)
	$(COMPOSE) --profile services --profile tools down

infra-reset: ## Stop the local stack and delete the postgres volume
	$(COMPOSE) --profile services --profile tools down -v

infra-ps: ## Show local stack status
	$(COMPOSE) ps -a

db-migrate: ## Apply ops + app schema migrations with dbmate (ADR-0001)
	$(COMPOSE) run --rm migrate --wait up

db-rollback: ## Roll back the latest migration
	$(COMPOSE) run --rm migrate rollback

calendar-gen: ## Generate XNYS + USBANK Session[] JSON for 13 months into calibration/out/calendars (FROM=YYYY-MM-DD)
	cd calibration && $(UV) run --frozen python -m credence_cal.calendar $(if $(FROM),--from $(FROM))

calendar-test: ## Calendar edge-case tests (holidays, early closes, DST, 24/5)
	cd calibration && $(UV) run --frozen pytest -q

relayer-dev: ## Run the relayer on the devnode: 3 nodes + aggregator (VENDOR=replay with a synthetic session unless set)
	@[ -f deployments/412346.local.json ] || $(MAKE) local-deploy-clock LOCAL_RPC=http://127.0.0.1:8547
	@if [ "$${VENDOR:-replay}" = replay ] && [ -z "$${REPLAY_FILE:-}" ]; then \
	  ASSETS=$${ASSETS:-NVDA:XNAS,AAPL:XNAS} $(CARGO) run -q -p credence-relayer -- sample-replay --out target/replay-sample.jsonl; fi
	CHAIN_ID=$${CHAIN_ID:-412346} RPC_URL=$${RPC_URL:-http://127.0.0.1:8547} VENDOR=$${VENDOR:-replay} \
	  REPLAY_FILE=$${REPLAY_FILE:-target/replay-sample.jsonl} REPLAY_START_OFFSET_S=$${REPLAY_START_OFFSET_S:-4200} ASSETS=$${ASSETS:-NVDA:XNAS,AAPL:XNAS} \
	  FEED_ADDRESS=$${FEED_ADDRESS:-$$(jq -r .shared.feedA deployments/412346.local.json)} \
	  $(CARGO) run -p credence-relayer -- run

relayer-smoke: ## Live vendor smoke test (VENDOR=polygon|alpaca, keys in .env)
	$(CARGO) run -p credence-relayer -- smoke --out target/relayer-smoke-$${VENDOR:-polygon}.json

relayer-e2e: contracts-build ## Relayer e2e on anvil: 2-of-3 accepted; 1-of-3, stale/old seq, wrong domain rejected (+ops.relayer_report with Postgres up)
	TEST_DATABASE_URL=$(TEST_DATABASE_URL) $(CARGO) test -p credence-relayer --test e2e -- --ignored --nocapture --test-threads=1

keeper-dev: ## Run one keeper instance locally (reads .env)
	$(CARGO) run -p credence-keeper -- run

keeper-e2e: contracts-build ## Keeper e2e on anvil + Postgres: J1 pokes on schedule; leader failover with no duplicate txs (needs infra-up)
	TEST_DATABASE_URL=$(TEST_DATABASE_URL) $(CARGO) test -p credence-keeper --test keeper_e2e -- --ignored --nocapture

indexer-e2e: ## Indexer + API e2e on the devnode: StateChanged/ReportAccepted → Ponder → GET /v1/clock/:assetId
	@[ -f deployments/412346.local.json ] || $(MAKE) local-deploy-clock LOCAL_RPC=http://127.0.0.1:8547 ASSETS=NVDA,AAPL
	$(PNPM) --filter @credence/sdk build
	bash indexer/scripts/e2e.sh

indexer-dev: ## Run the Ponder indexer against the local devnode
	$(PNPM) --filter @credence/indexer dev

api-dev: ## Run the Hono API on :8787
	$(PNPM) --filter @credence/api dev

notifier-dev: ## Run the notifier (queue consumer + /healthz /readyz /metrics on :9103; reads .env)
	$(PNPM) --filter @credence/notifier dev

notifier-e2e: ## Notifier e2e on Postgres: scenario A Bell heads-up (G-10, G-11) by email + push + Telegram against mock providers; retries, dead-letter, SKIP LOCKED (needs infra-up)
	$(CARGO) build -q -p credence-risk-cli
	TEST_DATABASE_URL=$(TEST_DATABASE_URL) RISK_CLI=$(abspath $(BACKEND_TARGET_DIR))/debug/risk-cli $(PNPM) --filter @credence/notifier e2e

services-up: ## Build and start relayer + keeper containers on the local stack
	$(COMPOSE) --profile services up -d --build

R26_DIR := target/be/r26
R26_CONNECTOR := @redstone-finance/evm-connector@1.0.0
r26-probe: ## R-26 feed probe on Arbitrum Sepolia (ADR-0009): RedStone verified by its own connector via eth_call, Chainlink + Pyth reads → target/be/r26/probe.json
	@mkdir -p $(R26_DIR)/src
	@[ -d $(R26_DIR)/package ] || (cd $(R26_DIR) && npm pack --silent $(R26_CONNECTOR) >/dev/null && tar xzf redstone-finance-evm-connector-*.tgz)
	@rm -rf $(R26_DIR)/src/redstone && cp -r $(R26_DIR)/package/contracts $(R26_DIR)/src/redstone
	@printf '%s\n' '// SPDX-License-Identifier: MIT' 'pragma solidity ^0.8.17;' \
	  'import "./redstone/data-services/PrimaryProdDataServiceConsumerBase.sol";' \
	  'contract Probe is PrimaryProdDataServiceConsumerBase {' \
	  '  function read(bytes32[] calldata ids) external view returns (uint256[] memory values, uint256 ts) {' \
	  '    (values, ts) = getOracleNumericValuesAndTimestampFromTxMsg(ids);' \
	  '  }' '}' > $(R26_DIR)/src/Probe.sol
	cd $(R26_DIR) && forge build --root . --contracts src/Probe.sol -o out --cache-path cache --skip test >/dev/null
	$(PNPM) --filter @credence/feeds build
	node packages/feeds/dist/probe.js --verifier $(R26_DIR)/out/Probe.sol/Probe.json --out $(R26_DIR)/probe.json $(if $(RPC),--rpc $(RPC))

keeper-j12-e2e: ## J12 on the devnode: ArbWasm programTimeLeft of shared.riskEngine → gauge; a non-program raises the stylus-activation alert (needs infra-up db-migrate + an engine)
	TEST_DATABASE_URL=$(TEST_DATABASE_URL) $(CARGO) test --locked -p credence-keeper --test j12_devnode -- --ignored --nocapture

keeper-sigma-test: ## J7 σ: reproduce QE's calibration/docs/sigma-vectors.json bit for bit + resume from the calibration snapshot
	$(CARGO) test --locked -p credence-keeper --test sigma_vectors -- --nocapture
	$(CARGO) test --locked -p credence-keeper --lib sigma_job
