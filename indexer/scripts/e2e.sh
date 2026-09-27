#!/usr/bin/env bash
# Indexer + API end to end on the local devnode (Sprint 1 acceptance 7):
#   chain events (StateChanged, ReportAccepted) → Ponder → Postgres (indexer views) → GET /v1/clock/:assetId
# Needs: make infra-up db-migrate, and a clock stack on the devnode (make local-deploy-clock LOCAL_RPC=http://127.0.0.1:8547).
set -euo pipefail
cd "$(dirname "$0")/../.."
RPC=${RPC:-http://127.0.0.1:8547}
PK=${DEVNODE_PRIVATE_KEY:-0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659}
DB=${DATABASE_URL:-postgres://credence:credence@127.0.0.1:${POSTGRES_PORT:-5433}/credence}
BOOK=deployments/412346.local.json
PORT_PONDER=${PORT_PONDER:-42169}
PORT_API=${PORT_API:-18787}
[ -f "$BOOK" ] || { echo "no $BOOK: run make local-deploy-clock LOCAL_RPC=$RPC"; exit 1; }
CLOCK=$(jq -r .clock $BOOK); FEED=$(jq -r .feedA $BOOK); NVDA=$(jq -r .assetId_NVDA $BOOK)
REPORT_T='(bytes32,uint8,uint128,uint40,uint40,uint8,uint64)[]'
if command -v psql >/dev/null; then q() { psql "$DB" -tAc "$1"; }
else q() { docker compose -f infra/docker-compose.yml exec -T postgres psql -U credence -d "${DB##*/}" -tAc "$1"; }; fi

echo "── 1. chain events"
if [ "$(cast logs --from-block 0 --address $CLOCK 'StateChanged(bytes32 indexed,uint8,uint8,uint64)' -r $RPC --json | jq length)" = "0" ]; then
  # before the calendar starts every asset is CLOSED; a guardian HALT (the deployer is guardian locally) forces a transition
  cast send $CLOCK 'restrict(bytes32,uint8,uint40)' $NVDA 4 $(( $(date +%s) + 600 )) --private-key $PK -r $RPC >/dev/null
fi
cast send $CLOCK 'poke(bytes32)' $NVDA --private-key $PK -r $RPC >/dev/null
NOW=$(date +%s); SEQ=$(( $(cast call $FEED 'latestSeq(bytes32)(uint64)' $NVDA -r $RPC) + 1 ))
R="[($NVDA,0,181330000000000000000,$NOW,$((NOW/86400)),0,$SEQ)]"
D=$(cast call $FEED "hashReports($REPORT_T)(bytes32)" "$R" -r $RPC)
S1=$(cast wallet sign --no-hash $D --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d)  # 0x7099…
S2=$(cast wallet sign --no-hash $D --private-key 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a)  # 0x3C44…
cast send $FEED "submit($REPORT_T,bytes[])" "$R" "[$S2,$S1]" --private-key $PK -r $RPC >/dev/null   # ascending signer order
echo "   poked NVDA, submitted LIVE seq=$SEQ price=181.33"

echo "── 2. Ponder"
LOG=$(mktemp); API_LOG=$(mktemp)
cleanup() { kill ${PONDER_PID:-} ${API_PID:-} 2>/dev/null || true; }
trap cleanup EXIT
( cd indexer && DATABASE_URL=$DB PONDER_CHAIN_ID=412346 PONDER_RPC_URL=$RPC PONDER_TELEMETRY_DISABLED=true \
    npx ponder start --schema indexer_e2e_$$ --views-schema indexer --port $PORT_PONDER >"$LOG" 2>&1 ) &
PONDER_PID=$!
for i in $(seq 1 90); do
  n=$(q "select count(*) from indexer.price_point where asset_id = '$NVDA' and seq = $SEQ" 2>/dev/null | tr -d '[:space:]' || echo 0)
  [ "$n" = "1" ] && break
  sleep 1
done
[ "$n" = "1" ] || { echo "Ponder did not index seq $SEQ"; tail -30 "$LOG"; exit 1; }
echo "   indexed (views in schema 'indexer')"

echo "── 3. API"
( cd services/api && DATABASE_URL=$DB API_PORT=$PORT_API SESSION_SECRET=$(head -c 32 /dev/urandom | base64) node src/server.ts >"$API_LOG" 2>&1 ) &
API_PID=$!
for i in $(seq 1 30); do curl -sf localhost:$PORT_API/readyz >/dev/null && break; sleep 0.5; done
BODY=$(curl -sf localhost:$PORT_API/v1/clock/NVDA:XNAS)
echo "$BODY" | jq '{assetId, state, closureId, transitions: [.transitions[] | {from: .from.name, to: .to.name, block}], feeds: [.feeds[] | {feed, seq, price: .price.formatted}], next: (.next // [] | length)}'
echo "$BODY" | jq -e --arg a "$NVDA" --arg s "$SEQ" '
  .assetId == $a and (.transitions | length) >= 1 and any(.feeds[]; .feed == "A" and .seq == $s and .price.formatted == "181.33")' >/dev/null
curl -sf localhost:$PORT_API/v1/openapi.json | jq -e '.paths["/v1/clock/{assetId}"]' >/dev/null
echo "OK: StateChanged + ReportAccepted indexed and served by GET /v1/clock/:assetId"
