#!/usr/bin/env bash
# make nav-settlement-e2e (S4 G; PM ruling 2026-09-30: seeded near LT, ≤ 30 min). NAV settlement on the devnode,
# keeper-only after seeding: a solver fill, then a pool advance with the issuer's T+1 fulfilment and J10's claim;
# indexer / API / notifier == chain. Needs infra-up db-migrate and BE-chain's main book with the NAV stack
# (deployments/412346.local.json: nav.settlement, nav.solverAuction) while USBANK is in a session.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
ROOT=$PWD
export RPC_URL=${RPC_URL:-http://127.0.0.1:8547}
export DATABASE_URL=${DATABASE_URL:-postgres://credence:credence@127.0.0.1:${POSTGRES_PORT:-5433}/credence}
export SCENARIO_DIR=${SCENARIO_DIR:-target/be/nav-settlement}
export SCENARIO_SALT=${SCENARIO_SALT:-nav-$(date +%s)}   # fresh actors per run
OUT=$ROOT/$SCENARIO_DIR; rm -rf "$OUT"; mkdir -p "$OUT"; : > "$OUT/deliveries.jsonl"
exec > >(tee "$OUT/check.log") 2>&1
echo "nav-settlement-e2e started $(date -u +%FT%TZ) (pid $$)"
VIEWS=indexer_nav_e2e; P_PONDER=42291; P_API=18898; P_MOCK=18899
BIN=$ROOT/target/be/debug
BOOK=deployments/412346.local.json
jq -e '.nav.settlement and .nav.solverAuction and .tokens.tTBILL' $BOOK >/dev/null || { echo "no NAV settlement stack in $BOOK"; exit 1; }
cast code "$(jq -r .nav.settlement $BOOK)" --rpc-url "$RPC_URL" | grep -q .. || { echo "nav.settlement has no code (stale book?)"; exit 1; }

PIDS=()
tree() { local c; echo "$1"; for c in $(pgrep -P "$1" 2>/dev/null); do tree "$c"; done; }
cleanup() { local rc=$?; local p
  [ $rc -ne 0 ] && echo "FAILED: runner exited with status $rc at $(date -u +%FT%TZ)"
  p=$( { for x in "${PIDS[@]:-}"; do [ -n "$x" ] && tree "$x"; done; } | tr '\n' ' '); [ -n "$p" ] && { kill $p 2>/dev/null || true; sleep 1; kill -9 $p 2>/dev/null || true; }; true; }
trap cleanup EXIT
trap 'echo "ABORTED: signal at $(date -u +%FT%TZ)"; exit 2' TERM INT HUP
start() { local name=$1; shift; ( "$@" >"$OUT/$name.log" 2>&1 ) & PIDS+=($!); echo "started $name (log $SCENARIO_DIR/$name.log)"; }
node_api() { (cd services/api && node "$@"); }

echo "── 0. the chain's calendars; actor keys"
node_api scripts/scenario-a/calendar.ts
mkdir -p "$OUT/calendars" && cp "$OUT/XNYS.json" "$OUT/USBANK.json" "$OUT/calendars/"
key() { node_api -e "import('./scripts/scenario-a/lib.ts').then(m=>console.log(m.actorKey('$1')))" 2>/dev/null | tail -1; }
KEEPER_KEY=$(key keeper); SOLVER_KEY=$(key solver)

echo "── 1. seeding (the last manual transactions)"
node_api scripts/nav/seed.ts

echo "── 2. indexer + API + providers + notifier"
start ponder bash -c "cd indexer && DATABASE_URL=$DATABASE_URL PONDER_CHAIN_ID=412346 PONDER_RPC_URL=$RPC_URL PONDER_TELEMETRY_DISABLED=true npx ponder start --schema nav_e2e_$$ --views-schema $VIEWS --port $P_PONDER"
start api bash -c "cd services/api && DATABASE_URL=$DATABASE_URL API_PORT=$P_API INDEXER_SCHEMA=$VIEWS RPC_URL=$RPC_URL SESSION_SECRET=$(head -c 32 /dev/urandom | base64) RATE_LIMIT_PER_MIN=100000 CALENDAR_DIR=$OUT/calendars node src/server.ts"
start mock node_api scripts/scenario-a/mock-providers.ts $P_MOCK
start notifier bash -c "cd services/notifier && DATABASE_URL=$DATABASE_URL INDEXER_SCHEMA=$VIEWS NOTIFIER_PORT=0 NOTIFIER_SCAN_LOOKBACK_S=3600 \
  RESEND_API_KEY=mock RESEND_API_URL=http://127.0.0.1:$P_MOCK/resend TELEGRAM_BOT_TOKEN=mock TELEGRAM_API_URL=http://127.0.0.1:$P_MOCK/tg \
  NOTIFIER_BACKOFF_BASE_S=2 DEPLOYMENTS_FILE=$BOOK node src/main.ts"
for i in $(seq 1 90); do curl -sf localhost:$P_API/readyz >/dev/null && break; sleep 2; done

echo "── 3. keeper (NAV only: J1 pokes TBILL, J10 open / finalize / claim / completeReopen)"
start keeper env CHAIN_ID=412346 RPC_URL=$RPC_URL DATABASE_URL=$DATABASE_URL CALENDAR_FILES="$OUT/XNYS.json,$OUT/USBANK.json" \
  KEEPER_ASSETS=TBILL:USBANK KEEPER_PRIVATE_KEY="$KEEPER_KEY" KEEPER_NAV=1 KEEPER_AUCTIONS=0 KEEPER_INSTANCE_ID=nav-e2e \
  INDEXER_SCHEMA=$VIEWS KEEPER_GAS_MULTIPLIER_X10=13 METRICS_ADDR=127.0.0.1:9292 SIGMA_COMMITTEE_KEYS= "$BIN/credence-keeper" run

echo "── 4. the NAV cycle (≤ 30 min in all)"
(cd services/api && API=http://127.0.0.1:$P_API SOLVER_BIN=$BIN/credence-solver SOLVER_KEY=$SOLVER_KEY \
  exec timeout 1680 node scripts/nav/check.ts) || { echo "--- keeper.log (tail)"; tail -30 "$OUT/keeper.log"; exit 1; }
curl -s localhost:9292/metrics | grep -E '^credence_keeper_failed_txs_total' || echo "credence_keeper_failed_txs_total: none recorded"
echo "PASSED: nav-settlement-e2e at $(date -u +%FT%TZ)"
