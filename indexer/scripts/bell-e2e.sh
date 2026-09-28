#!/usr/bin/env bash
# Acceptance 4, market level (make api-bell-e2e): Ponder + API against the devnode's core stack
# (BE-chain's DeployCoreLocal on the devnode, full Stylus engine), 100 positions, and /bell compared with
# CredenceMarket.bellStatus / engine.quoteCover at the block the API reports. Own views schema; the
# devnode's `indexer` views are untouched.
set -euo pipefail
cd "$(dirname "$0")/../.."
RPC=${RPC:-http://127.0.0.1:8547}
DB=${DATABASE_URL:-postgres://credence:credence@127.0.0.1:${POSTGRES_PORT:-5433}/credence}
PORT_PONDER=${PORT_PONDER:-42189}; PORT_API=${PORT_API:-18798}; VIEWS=indexer_bell_e2e
jq -e '.equity.market' deployments/412346.local.json >/dev/null || { echo "no equity stack on the devnode (BE-chain DeployCoreLocal)"; exit 1; }
tree() { local c; echo "$1"; for c in $(pgrep -P "$1" 2>/dev/null); do tree "$c"; done; }
cleanup() { local p; p=$( { for x in ${PONDER_PID:-} ${API_PID:-}; do tree "$x"; done; } | tr '\n' ' '); [ -n "$p" ] && { kill $p 2>/dev/null || true; sleep 1; kill -9 $p 2>/dev/null || true; }; true; }
trap cleanup EXIT
LOG=$(mktemp); API_LOG=$(mktemp)
( cd indexer && DATABASE_URL=$DB PONDER_CHAIN_ID=412346 PONDER_RPC_URL=$RPC PONDER_TELEMETRY_DISABLED=true \
    npx ponder start --schema bell_e2e_$$ --views-schema $VIEWS --port $PORT_PONDER >"$LOG" 2>&1 ) & PONDER_PID=$!
( cd services/api && DATABASE_URL=$DB API_PORT=$PORT_API INDEXER_SCHEMA=$VIEWS RPC_URL=$RPC SESSION_SECRET=$(head -c 32 /dev/urandom | base64) \
    RATE_LIMIT_PER_MIN=100000 node src/server.ts >"$API_LOG" 2>&1 ) & API_PID=$!
for i in $(seq 1 60); do curl -sf localhost:$PORT_API/readyz >/dev/null && break; sleep 1; done
( cd services/api && SETUP=${SETUP:-1} RPC_URL=$RPC API=http://127.0.0.1:$PORT_API node scripts/bell-market-e2e.ts ) || { tail -20 "$API_LOG"; tail -20 "$LOG"; exit 1; }
