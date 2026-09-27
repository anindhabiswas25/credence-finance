# Backend fragment (owner: BE-backend). Included by the root Makefile.
# Every target has a `## help` comment; `make help` lists them.

BACKEND_RUST_PKGS := -p credence-common -p credence-relayer -p credence-keeper
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
        relayer-dev keeper-dev indexer-dev api-dev relayer-e2e services-up

backend-install: ## Install backend deps: pnpm workspace, uv calibration env, Rust crates fetched
	$(PNPM) install --frozen-lockfile
	cd calibration && $(UV) sync --frozen
	cargo fetch --locked

backend-build: ## Build backend: Rust services (release-less check build) and TS packages
	cargo build --locked $(BACKEND_RUST_PKGS)
	$(PNPM) turbo run build

backend-test: ## Run backend tests: Rust services, TS packages (sdk, api, indexer), calendar
	cargo test --locked $(BACKEND_RUST_PKGS)
	$(PNPM) turbo run test
	cd calibration && $(UV) run --frozen pytest -q

backend-lint: ## Lint backend: rustfmt check, clippy -D warnings, eslint, tsc
	cargo fmt $(BACKEND_RUST_PKGS) -- --check
	cargo clippy --locked $(BACKEND_RUST_PKGS) --all-targets -- -D warnings
	$(PNPM) turbo run lint typecheck

backend-fmt: ## Format backend code (rustfmt + prettier)
	cargo fmt $(BACKEND_RUST_PKGS)
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

relayer-dev: ## Run the price relayer locally (VENDOR=replay by default; reads .env)
	VENDOR=$${VENDOR:-replay} cargo run -p credence-relayer -- run

relayer-e2e: ## Relayer on-chain e2e: deploy CredencePriceFeed on anvil, 2-of-3 accepted, 1-of-3/stale seq/wrong domain rejected
	cargo test -p credence-relayer --test e2e -- --ignored --nocapture --test-threads=1

keeper-dev: ## Run one keeper instance locally (reads .env)
	cargo run -p credence-keeper -- run

indexer-dev: ## Run the Ponder indexer against the local devnode
	$(PNPM) --filter @credence/indexer dev

api-dev: ## Run the Hono API on :8787
	$(PNPM) --filter @credence/api dev

services-up: ## Build and start relayer + keeper containers on the local stack
	$(COMPOSE) --profile services up -d --build
