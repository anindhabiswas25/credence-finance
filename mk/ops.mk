# Ops fragment (owner: BE-backend, was DevOps): the local testnet stack in infra/prod (Amendment 2). Included by the
# root Makefile. Every target has a `## help` comment.
#
# First time:  make ops-secrets-init  → fill in infra/prod/secrets/rpc.env  → make ops-rpc-check
#              A's make testnet-keys CHAIN=… KEYSTORE_DIR=$$HOME/.credence/keys (the service keystores)
# Then:        make testnet-up  → make testnet-services-check   (the API on http://127.0.0.1:8787)

OPS_DIR     := infra/prod
OPS_ENV     := $(OPS_DIR)/.env.prod
OPS_GEN     := $(CURDIR)/$(OPS_DIR)/generated
OPS_STATE   := $(CURDIR)/$(OPS_DIR)/state
# the non-secret settings (.env.prod, from .env.prod.example), exported to every recipe line that sources it
OPS_SRC     := set -a; [ -f $(OPS_ENV) ] && . ./$(OPS_ENV); set +a;
OPS_COMPOSE  = HOST_UID=$$(id -u) HOST_GID=$$(id -g) GEN_DIR=$(OPS_GEN) STATE_DIR=$(OPS_STATE) \
               docker compose -p credence-testnet -f $(OPS_DIR)/docker-compose.yml \
               $(if $(wildcard $(OPS_ENV)),--env-file $(OPS_ENV))
OPS_TAG      = $$(cat $(OPS_STATE)/tag.current 2>/dev/null || echo latest)
# the dry run (testnet-dry-*): its own project, directories and ports
DRY_DIR     := $(CURDIR)/target/testnet-dry
DRY_COMPOSE  = HOST_UID=$$(id -u) HOST_GID=$$(id -g) GEN_DIR=$(DRY_DIR)/generated STATE_DIR=$(DRY_DIR)/state \
               SECRETS_DIR=$(DRY_DIR)/secrets KEYS_DIR=$(DRY_DIR)/keys BACKUP_HOST_DIR=$(DRY_DIR)/backups \
               API_PORT=18787 GRAFANA_PORT=13002 PROMETHEUS_PORT=19091 ALERTMANAGER_PORT=19094 TAG=dry \
               OPS_ADMIN_ADDRESSES=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
               docker compose -p credence-testnet-dry -f $(OPS_DIR)/docker-compose.yml

.PHONY: ops-secrets-init ops-rpc-check services-config testnet-up testnet-down testnet-services-check testnet-ps \
        testnet-logs services-deploy services-rollback db-backup db-restore ops-check testnet-dry-up \
        testnet-dry-check testnet-dry-down

ops-secrets-init: ## Create infra/prod/secrets (0600: rpc.env template, Postgres, session, webhook, node tokens) and .env.prod
	@bash $(OPS_DIR)/scripts/secrets-init.sh

ops-rpc-check: ## Each RPC of both chains (secrets/rpc.env + the public one): chain id and head, never the URL
	@bash $(OPS_DIR)/scripts/rpc-check.sh

services-config: ## A's address book → the stack's per-chain env: CHAIN=46630|421614 [BOOK=…] [DRYRUN=1]
	@$(OPS_SRC) CHAIN=$(CHAIN) $(if $(BOOK),BOOK=$(BOOK)) $(if $(DRYRUN),DRYRUN=$(DRYRUN)) GEN_DIR=$(OPS_GEN) \
	  bash $(OPS_DIR)/scripts/services-config.sh

testnet-up: ## services-config for both chains, then the whole local testnet stack up and healthy (project credence-testnet)
	@test -f $(OPS_DIR)/secrets/rpc.env || { echo "run make ops-secrets-init (and fill in secrets/rpc.env) first" >&2; exit 1; }
	@$(MAKE) --no-print-directory services-config CHAIN=46630
	@$(MAKE) --no-print-directory services-config CHAIN=421614
	@$(OPS_SRC) DC="$(OPS_COMPOSE)" STATE_DIR=$(OPS_STATE) bash $(OPS_DIR)/scripts/deploy.sh up
	@echo "testnet-up: the API is on http://127.0.0.1:$${API_PORT:-8787}; next: make testnet-services-check"

testnet-down: ## Stop the local testnet stack (Postgres, Prometheus and Grafana volumes are kept)
	$(OPS_COMPOSE) down --remove-orphans

testnet-ps: ## The local testnet stack's containers and health
	$(OPS_COMPOSE) ps -a

testnet-logs: ## Follow one service's log: SVC=keeper-46630 (default: every service, last 100 lines)
	$(OPS_COMPOSE) logs -f --tail 100 $(SVC)

testnet-services-check: ## The steady state after a deploy: services, indexers, feeds, keepers, API, first NAV print, alerts
	@$(OPS_SRC) DC="$(OPS_COMPOSE)" bash $(OPS_DIR)/scripts/services-check.sh

services-deploy: ## Build the images as TAG (default: git short sha), migrate up, switch, health gate (back to the old tag on failure)
	@$(OPS_SRC) DC="$(OPS_COMPOSE)" STATE_DIR=$(OPS_STATE) bash $(OPS_DIR)/scripts/deploy.sh deploy $(TAG)

services-rollback: ## Back to the previous image tag; MIGRATIONS=n rolls back n migrations first
	@$(OPS_SRC) DC="$(OPS_COMPOSE)" STATE_DIR=$(OPS_STATE) bash $(OPS_DIR)/scripts/deploy.sh rollback $(or $(MIGRATIONS),0)

db-backup: ## One pg_dump of the testnet stack's database now (infra/prod/backups; the nightly one runs by itself)
	$(OPS_COMPOSE) exec -T pg-backup sh /opt/backup/pg-backup.sh once

db-restore: ## Restore FILE=credence-<stamp>.dump: stops the services, restores, starts them, health gate
	@test -n "$(FILE)" || { echo "db-restore FILE=credence-<stamp>.dump (ls infra/prod/backups)" >&2; exit 2; }
	$(OPS_COMPOSE) stop $$($(OPS_COMPOSE) config --services | grep -vE '^(postgres|pg-backup|prometheus|alertmanager|grafana)$$')
	$(OPS_COMPOSE) exec -T pg-backup sh /opt/backup/pg-backup.sh restore $(FILE)
	@$(OPS_SRC) DC="$(OPS_COMPOSE)" STATE_DIR=$(OPS_STATE) bash $(OPS_DIR)/scripts/deploy.sh up

ops-check: ## Build checks of the ops files: compose config, promtool check (config + rules), every image builds
	@$(MAKE) --no-print-directory -s ops-check-static
	$(DRY_COMPOSE) build

ops-check-static:
	@mkdir -p /tmp/credence-ops-check/46630 /tmp/credence-ops-check/421614 /tmp/credence-ops-check/secrets
	@for f in 46630/chain.env 46630/feed-a.env 46630/feed-b.env 421614/chain.env stack.env; do touch /tmp/credence-ops-check/$$f; done
	@for f in pg_password rpc.env session_secret ops_alert_webhook relayer_a_token relayer_b_token grafana_admin; do touch /tmp/credence-ops-check/secrets/$$f; done
	GEN_DIR=/tmp/credence-ops-check SECRETS_DIR=/tmp/credence-ops-check/secrets KEYS_DIR=/tmp/credence-ops-check \
	  docker compose -p credence-testnet -f $(OPS_DIR)/docker-compose.yml config --quiet && echo "docker compose config: OK"
	docker run --rm -v $(CURDIR)/infra:/infra:ro --entrypoint promtool prom/prometheus:v3.6.0 check rules /infra/prometheus/alerts.yml
	docker run --rm -v $(CURDIR)/infra:/infra:ro --entrypoint sh prom/prometheus:v3.6.0 -c \
	  'sed "s#/etc/prometheus/alerts.yml#/infra/prometheus/alerts.yml#" /infra/prod/prometheus/prometheus.yml > /tmp/p.yml && promtool check config --syntax-only /tmp/p.yml'
	docker run --rm -v $(CURDIR)/infra/prod/alertmanager:/am:ro --entrypoint amtool prom/alertmanager:v0.28.1 check-config /am/alertmanager.yml

testnet-dry-up: ## The one e2e run before the deploy: A's dry-run books on 2 local anvils + the whole stack (project credence-testnet-dry, API :18787)
	@DC="$(DRY_COMPOSE)" DRY_DIR=$(DRY_DIR) bash $(OPS_DIR)/scripts/dryrun.sh up

testnet-dry-check: ## testnet-services-check against the dry run
	@DC="$(DRY_COMPOSE)" API_PORT=18787 PROMETHEUS_PORT=19091 ALERTMANAGER_PORT=19094 bash $(OPS_DIR)/scripts/services-check.sh

testnet-dry-down: ## Remove the dry run: its stack and volumes, the anvils, the worktree
	@DC="$(DRY_COMPOSE)" DRY_DIR=$(DRY_DIR) bash $(OPS_DIR)/scripts/dryrun.sh down
