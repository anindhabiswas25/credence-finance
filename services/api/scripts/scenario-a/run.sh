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
OUT=$ROOT/$SCENARIO_DIR; mkdir -p "$OUT"; : > "$OUT/deliveries.jsonl"; rm -f "$OUT/restart.log" "$OUT/.finished"; : > "$OUT/.services"
# everything this runner prints goes to check.log too; a dying run must leave a line there (ABORTED/FAILED/OK)
exec > >(tee "$OUT/check.log") 2>&1
echo "scenario A runner started $(date -u +%FT%TZ) (pid $$)"
VIEWS=indexer_scenario_a; P_PONDER=42191; P_API=18798; P_MOCK=18799
BIN=$ROOT/target/be/debug
BOOK=deployments/412346.local.json
jq -e '.equity.pool and .equity.auctionHouse' $BOOK >/dev/null || { echo "no equity pool / auction house in $BOOK"; exit 1; }
cast code "$(jq -r .equity.pool $BOOK)" --rpc-url "$RPC_URL" | grep -q .. || { echo "the pool has no code"; exit 1; }
cast call "$(jq -r .equity.pool $BOOK)" "venue()(bytes32)" --rpc-url "$RPC_URL" >/dev/null || { echo "equity.pool is not the v2 UnderwriterPool (the S2 mock?): wait for BE-chain item D"; exit 1; }

PIDS=()
tree() { local c; echo "$1"; for c in $(pgrep -P "$1" 2>/dev/null); do tree "$c"; done; }
cleanup() { local rc=$?; local p; touch "$OUT/.finished"
  [ $rc -ne 0 ] && ! grep -q '^ABORTED' "$OUT/check.log" && echo "FAILED: runner exited with status $rc at $(date -u +%FT%TZ)"
  p=$( { for x in "${PIDS[@]:-}"; do [ -n "$x" ] && tree "$x"; done; } | tr '\n' ' '); [ -n "$p" ] && { kill $p 2>/dev/null || true; sleep 1; kill -9 $p 2>/dev/null || true; }; true; }
trap cleanup EXIT
trap 'exit 2' TERM INT HUP
start() { local name=$1; shift; ( "$@" >"$OUT/$name.log" 2>&1 ) & PIDS+=($!); echo "$name $!" >> "$OUT/.services"; echo "started $name (log $SCENARIO_DIR/$name.log)"; }
node_api() { (cd services/api && node "$@"); }

# Watchdog (S4 brief Part 1.3): the last run died with the laptop and left no line in check.log. Every 10 s:
#  - the devnode answers and its head block advances: RPC down > 60 s, or the head block's time > 60 s behind
#    the wall clock for 3 checks in a row (the relayers' STATUS heartbeat is 60 s, REGULAR 10 s) → ABORTED;
#  - the wall clock jumped > 60 s between two checks (the host slept despite systemd-inhibit) → ABORTED;
#  - every started service is alive; the keeper by name, with 60 s of grace for the kill-watch restart → ABORTED;
#  - Postgres answers.
# It writes "ABORTED: <reason>" to check.log and TERMs the runner (exit non-zero, the EXIT trap stops the rest).
watchdog() {
  local main=$1 last=$(date +%s) rpc_bad=0 lag_bad=0 keeper_gone=0
  while [ ! -f "$OUT/.finished" ]; do
    sleep 10; local t=$(date +%s) why=""
    [ $(( t - last )) -gt 70 ] && why="the wall clock jumped $(( t - last )) s between two checks (host suspended?)"
    last=$t
    local head; head=$(cast block latest --field timestamp --rpc-url "$RPC_URL" 2>/dev/null) || head=""
    if [ -z "$head" ]; then rpc_bad=$(( rpc_bad + 10 )); [ $rpc_bad -gt 60 ] && why=${why:-"the devnode RPC $RPC_URL has not answered for $rpc_bad s"}
    else rpc_bad=0
      if [ $(( t - head )) -gt 60 ]; then lag_bad=$(( lag_bad + 1 )); else lag_bad=0; fi
      [ $lag_bad -ge 3 ] && why=${why:-"the devnode's block time stopped advancing: head block time $head is $(( t - head )) s behind the wall clock"}
    fi
    docker exec credence-postgres-1 pg_isready -q -U credence -d credence 2>/dev/null || why=${why:-"Postgres does not answer"}
    local name pid
    while read -r name pid; do
      [ "$name" = keeper ] && continue   # watched by name below (kill-watch replaces its process)
      kill -0 "$pid" 2>/dev/null || why=${why:-"service $name died (see $SCENARIO_DIR/$name.log: $(tail -1 "$OUT/$name.log" 2>/dev/null | cut -c1-200))"}
    done < "$OUT/.services"
    if ! pgrep -x credence-keeper >/dev/null; then keeper_gone=$(( keeper_gone + 10 ))
      [ $keeper_gone -gt 60 ] && why=${why:-"the keeper process is gone for $keeper_gone s (see $SCENARIO_DIR/keeper.log)"}
    else keeper_gone=0; fi
    [ -f "$OUT/.finished" ] && return 0
    if [ -n "$why" ]; then echo "ABORTED: $why ($(date -u +%FT%TZ))" | tee -a "$OUT/check.log" >&2; kill -TERM "$main"; return 1; fi
  done
}

echo "── 0. the chain's calendar and the replay recording"
node_api scripts/scenario-a/calendar.ts
node_api scripts/scenario-a/replay.ts
mkdir -p "$OUT/calendars" && cp "$OUT/XNYS.json" "$OUT/USBANK.json" "$OUT/calendars/"
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
start api bash -c "cd services/api && DATABASE_URL=$DATABASE_URL API_PORT=$P_API INDEXER_SCHEMA=$VIEWS RPC_URL=$RPC_URL SESSION_SECRET=$(head -c 32 /dev/urandom | base64) RATE_LIMIT_PER_MIN=100000 CALENDAR_DIR=$OUT/calendars node src/server.ts"
start mock node_api scripts/scenario-a/mock-providers.ts $P_MOCK
start notifier bash -c "cd services/notifier && DATABASE_URL=$DATABASE_URL INDEXER_SCHEMA=$VIEWS NOTIFIER_PORT=0 NOTIFIER_SCAN_LOOKBACK_S=21600 \
  RESEND_API_KEY=mock RESEND_API_URL=http://127.0.0.1:$P_MOCK/resend TELEGRAM_BOT_TOKEN=mock TELEGRAM_API_URL=http://127.0.0.1:$P_MOCK/tg \
  NOTIFIER_BACKOFF_BASE_S=2 DEPLOYMENTS_FILE=$BOOK node src/main.ts"
for i in $(seq 1 90); do curl -sf localhost:$P_API/readyz >/dev/null && break; sleep 2; done

echo "── 3. keeper (J3/J4 live; it also ends the post-deploy REOPEN with completeReopen)"
start keeper env CHAIN_ID=412346 RPC_URL=$RPC_URL DATABASE_URL=$DATABASE_URL CALENDAR_FILES=$CAL KEEPER_ASSETS=NVDA:XNAS,TSLA:XNAS,AAPL:XNAS \
  KEEPER_PRIVATE_KEY="$KEEPER_KEY" KEEPER_J3_LIVE=1 KEEPER_J4_LIVE=1 KEEPER_INSTANCE_ID=scenario-a INDEXER_SCHEMA=$VIEWS \
  KEEPER_GAS_MULTIPLIER_X10=${KEEPER_GAS_MULTIPLIER_X10:-13} KEEPER_J3_BATCH=${KEEPER_J3_BATCH:-10} METRICS_ADDR=127.0.0.1:9192 \
  SIGMA_COMMITTEE_KEYS= "$BIN/credence-keeper" run
# acceptance 4: SIGKILL the keeper right after its first REOPEN fixLots, restart it before the clear
start kill-watch bash services/api/scripts/scenario-a/kill-watch.sh "$OUT" env CHAIN_ID=412346 RPC_URL=$RPC_URL DATABASE_URL=$DATABASE_URL CALENDAR_FILES=$CAL KEEPER_ASSETS=NVDA:XNAS,TSLA:XNAS,AAPL:XNAS \
  KEEPER_PRIVATE_KEY="$KEEPER_KEY" KEEPER_J3_LIVE=1 KEEPER_J4_LIVE=1 KEEPER_INSTANCE_ID=scenario-a INDEXER_SCHEMA=$VIEWS \
  KEEPER_GAS_MULTIPLIER_X10=${KEEPER_GAS_MULTIPLIER_X10:-13} KEEPER_J3_BATCH=${KEEPER_J3_BATCH:-10} METRICS_ADDR=127.0.0.1:9192 \
  SIGMA_COMMITTEE_KEYS= "$BIN/credence-keeper" run

WATCH_KEEPER=1 watchdog $$ & WD=$!
echo "watchdog running (pid $WD): devnode clock, RPC, Postgres, every service, host suspend"

echo "── 4. seeding once the assets trade REGULAR (the last manual transactions)"
(cd services/api && node scripts/scenario-a/seed.ts)
SEED_END_BLOCK=$(cast block-number --rpc-url "$RPC_URL")
echo "seed end block $SEED_END_BLOCK"
start bidder env RPC_URL=$RPC_URL BIDDER_CONFIG="$OUT/bidders.json" BIDDER_STATE="$OUT/bidder-state.json" "$BIN/credence-bidder"

echo "── 5. the closure cycle (waits for the Friday close and the Monday reopen)"
(cd services/api && API=http://127.0.0.1:$P_API SEED_END_BLOCK=$SEED_END_BLOCK KEEPER_ADDRESS=$KEEPER_ADDRESS RELAYER_ADDRESS=$RELAYER_ADDRESS RELAYER_B_ADDRESS=$RELAYER_B_ADDRESS \
  exec node scripts/scenario-a/check.ts) & CHECK=$!; PIDS+=($CHECK)
wait $CHECK || { tail -30 "$OUT/keeper.log"; exit 1; }
curl -s localhost:9192/metrics | grep -E '^keeper_failed_txs_total' || echo "keeper_failed_txs_total: none recorded"
node_api scripts/scenario-a/tx-summary.ts || true
echo "PASSED: scenario A at $(date -u +%FT%TZ)"
