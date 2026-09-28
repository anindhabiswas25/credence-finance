#!/usr/bin/env bash
# make scenario-a-e2e (S3 F, ADR-0012): scenario A on the devnode, keeper-only after seeding.
# Needs: infra-up db-migrate, BE-chain's synthetic core with the real pool + auction house in
# deployments/412346.local.json (compressed calendar: the Friday close ≥ 2 h 15 min ahead).
# Runs: Ponder + API (own views schema), mock email/Telegram, notifier, relayer (replay vendor on the chain's
# calendar), keeper (J3/J4 live), bidder bot; then seed.ts, then check.ts until epoch settlement.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
ROOT=$PWD
export RPC_URL=${RPC_URL:-http://127.0.0.1:8547}
export DATABASE_URL=${DATABASE_URL:-postgres://credence:credence@127.0.0.1:${POSTGRES_PORT:-5433}/credence}
export SCENARIO_DIR=${SCENARIO_DIR:-target/be/scenario-a}
OUT=$ROOT/$SCENARIO_DIR; mkdir -p "$OUT"; : > "$OUT/deliveries.jsonl"
VIEWS=indexer_scenario_a; P_PONDER=42191; P_API=18798; P_MOCK=18799
BIN=$ROOT/target/be/debug
BOOK=deployments/412346.local.json
jq -e '.equity.pool and .equity.auctionHouse' $BOOK >/dev/null || { echo "no equity pool / auction house in $BOOK"; exit 1; }
cast code "$(jq -r .equity.pool $BOOK)" --rpc-url "$RPC_URL" | grep -q .. || { echo "the pool has no code"; exit 1; }
cast call "$(jq -r .equity.pool $BOOK)" "venue()(bytes32)" --rpc-url "$RPC_URL" >/dev/null || { echo "equity.pool is not the v2 UnderwriterPool (the S2 mock?): wait for BE-chain item D"; exit 1; }

PIDS=()
tree() { local c; echo "$1"; for c in $(pgrep -P "$1" 2>/dev/null); do tree "$c"; done; }
cleanup() { local p; p=$( { for x in "${PIDS[@]:-}"; do [ -n "$x" ] && tree "$x"; done; } | tr '\n' ' '); [ -n "$p" ] && { kill $p 2>/dev/null || true; sleep 1; kill -9 $p 2>/dev/null || true; }; true; }
trap cleanup EXIT
start() { local name=$1; shift; ( "$@" >"$OUT/$name.log" 2>&1 ) & PIDS+=($!); echo "started $name (log $SCENARIO_DIR/$name.log)"; }
node_api() { (cd services/api && node "$@"); }

echo "── 0. the chain's calendar and the replay recording"
node_api scripts/scenario-a/calendar.ts
node_api scripts/scenario-a/replay.ts
CAL="$OUT/XNYS.json,$OUT/USBANK.json"
KEEPER_KEY=$(node_api -e 'import("./scripts/scenario-a/lib.ts").then(m=>console.log(m.actorKey("keeper")))' 2>/dev/null | tail -1)
RELAYER_KEY=$(node_api -e 'import("./scripts/scenario-a/lib.ts").then(m=>console.log(m.actorKey("relayer")))' 2>/dev/null | tail -1)
RELAYER_B_KEY=$(node_api -e 'import("./scripts/scenario-a/lib.ts").then(m=>console.log(m.actorKey("relayer-b")))' 2>/dev/null | tail -1)
KEEPER_ADDRESS=$(cast wallet address "$KEEPER_KEY"); RELAYER_ADDRESS=$(cast wallet address "$RELAYER_KEY"); RELAYER_B_ADDRESS=$(cast wallet address "$RELAYER_B_KEY")

echo "── 1. relayer first (the feeds must stay fresh while seeding)"
REC=$(jq -r .recStart "$OUT/replay.meta.json")
node_api scripts/scenario-a/seed-gas.ts "$RELAYER_ADDRESS" "$RELAYER_B_ADDRESS" "$KEEPER_ADDRESS"
# feeds A and B (the oracle cross-checks them), each with its own submitter
for F in A B; do
  KEY=$RELAYER_KEY; [ $F = B ] && KEY=$RELAYER_B_KEY
  FEED=$(jq -r ".shared.feed$F" $BOOK)
  start relayer-$F env CHAIN_ID=412346 FEED_ID=$F VENDOR=replay REPLAY_FILE="$OUT/replay.jsonl" REPLAY_START_OFFSET_S=$(( $(date +%s) - REC )) \
    ASSETS=NVDA:XNAS,TSLA:XNAS,AAPL:XNAS FEED_ADDRESS="$FEED" RELAYER_SUBMITTER_PRIVATE_KEY="$KEY" \
    RELAYER_STREAM=0 DATABASE_URL="$DATABASE_URL" METRICS_ADDR=127.0.0.1:0 "$BIN/credence-relayer" run
done
sleep 30

echo "── 2. indexer + API + providers + notifier"
start ponder bash -c "cd indexer && DATABASE_URL=$DATABASE_URL PONDER_CHAIN_ID=412346 PONDER_RPC_URL=$RPC_URL PONDER_TELEMETRY_DISABLED=true npx ponder start --schema scenario_a_$$ --views-schema $VIEWS --port $P_PONDER"
start api bash -c "cd services/api && DATABASE_URL=$DATABASE_URL API_PORT=$P_API INDEXER_SCHEMA=$VIEWS RPC_URL=$RPC_URL SESSION_SECRET=$(head -c 32 /dev/urandom | base64) RATE_LIMIT_PER_MIN=100000 CALENDAR_DIR=$OUT node src/server.ts"
start mock node_api scripts/scenario-a/mock-providers.ts $P_MOCK
start notifier bash -c "cd services/notifier && DATABASE_URL=$DATABASE_URL INDEXER_SCHEMA=$VIEWS NOTIFIER_PORT=0 NOTIFIER_SCAN_LOOKBACK_S=21600 \
  RESEND_API_KEY=mock RESEND_API_URL=http://127.0.0.1:$P_MOCK/resend TELEGRAM_BOT_TOKEN=mock TELEGRAM_API_URL=http://127.0.0.1:$P_MOCK/tg \
  NOTIFIER_BACKOFF_BASE_S=2 DEPLOYMENTS_FILE=$BOOK node src/main.ts"
for i in $(seq 1 90); do curl -sf localhost:$P_API/readyz >/dev/null && break; sleep 2; done

echo "── 3. seeding (the last manual transactions)"
(cd services/api && node scripts/scenario-a/seed.ts)
SEED_END_BLOCK=$(cast block-number --rpc-url "$RPC_URL")
echo "seed end block $SEED_END_BLOCK"

echo "── 4. keeper (J3/J4 live) + bidder bot"
start keeper env CHAIN_ID=412346 RPC_URL=$RPC_URL DATABASE_URL=$DATABASE_URL CALENDAR_FILES=$CAL KEEPER_ASSETS=NVDA:XNAS,TSLA:XNAS,AAPL:XNAS \
  KEEPER_PRIVATE_KEY="$KEEPER_KEY" KEEPER_J3_LIVE=1 KEEPER_J4_LIVE=1 KEEPER_INSTANCE_ID=scenario-a INDEXER_SCHEMA=$VIEWS \
  KEEPER_GAS_MULTIPLIER_X10=${KEEPER_GAS_MULTIPLIER_X10:-13} KEEPER_J3_BATCH=${KEEPER_J3_BATCH:-50} METRICS_ADDR=127.0.0.1:9192 \
  SIGMA_COMMITTEE_KEYS= "$BIN/credence-keeper" run
# acceptance 4: SIGKILL the keeper right after its first REOPEN fixLots is done, restart it before the clear (+7:00)
(
  for i in $(seq 1 2000); do
    n=$(docker compose -f infra/docker-compose.yml exec -T postgres psql -U credence -d credence -tAc \
          "select count(*) from ops.keeper_job where key like 'J5:%:fixLots:%' and status = 'done'" 2>/dev/null || echo 0)
    [ "${n:-0}" -ge 1 ] && break; sleep 3
  done
  KP=$(pgrep -f "credence-keeper run" | head -1); [ -n "$KP" ] && kill -9 $KP && echo "$(date -u +%T) killed the keeper (pid $KP) between fixLots and clear" >> "$OUT/restart.log"
  sleep 20
  env CHAIN_ID=412346 RPC_URL=$RPC_URL DATABASE_URL=$DATABASE_URL CALENDAR_FILES=$CAL KEEPER_ASSETS=NVDA:XNAS,TSLA:XNAS,AAPL:XNAS \
    KEEPER_PRIVATE_KEY="$KEEPER_KEY" KEEPER_J3_LIVE=1 KEEPER_J4_LIVE=1 KEEPER_INSTANCE_ID=scenario-a INDEXER_SCHEMA=$VIEWS \
    KEEPER_GAS_MULTIPLIER_X10=${KEEPER_GAS_MULTIPLIER_X10:-13} KEEPER_J3_BATCH=${KEEPER_J3_BATCH:-50} METRICS_ADDR=127.0.0.1:9192 \
    SIGMA_COMMITTEE_KEYS= "$BIN/credence-keeper" run >> "$OUT/keeper.log" 2>&1 &
  echo "$(date -u +%T) restarted the keeper (pid $!)" >> "$OUT/restart.log"
  wait
) & PIDS+=($!)
start bidder env RPC_URL=$RPC_URL BIDDER_CONFIG="$OUT/bidders.json" BIDDER_STATE="$OUT/bidder-state.json" "$BIN/credence-bidder"

echo "── 5. the closure cycle (waits for the Friday close and the Monday reopen)"
(cd services/api && API=http://127.0.0.1:$P_API SEED_END_BLOCK=$SEED_END_BLOCK KEEPER_ADDRESS=$KEEPER_ADDRESS RELAYER_ADDRESS=$RELAYER_ADDRESS RELAYER_B_ADDRESS=$RELAYER_B_ADDRESS \
  node scripts/scenario-a/check.ts) || { tail -30 "$OUT/keeper.log"; exit 1; }
curl -s localhost:9192/metrics | grep -E '^keeper_failed_txs_total' || echo "keeper_failed_txs_total: none recorded"
