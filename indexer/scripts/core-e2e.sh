#!/usr/bin/env bash
# Acceptance 6 (make indexer-core-e2e): the indexer and the API serve markets, positions and the vault
# from a local scenario-A run on BE-chain's DeployCoreLocal (scratch anvil + Postgres; the devnode and its
# `indexer` views are not touched: this run uses its own views schema).
#   Fri 2026-10-09, NVDA at $180: Priya adds 500 tNVDA and borrows $67,000 (LTV 74.4%) → at the Bell
#   (15:45 ET) the weekend safe LTV is 71.26% (G-10, injected into the stand-in engine) → enforceBell
#   auto-covers her for $35.95 → Ponder indexes every step → the API serves it.
# Needs: make infra-up db-migrate (Postgres), contracts built (make contracts-build).
set -euo pipefail
cd "$(dirname "$0")/../.."
DB=${DATABASE_URL:-postgres://credence:credence@127.0.0.1:${POSTGRES_PORT:-5433}/credence}
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("",0));print(s.getsockname()[1])')
RPC=http://127.0.0.1:$PORT
PORT_PONDER=${PORT_PONDER:-42179}
PORT_API=${PORT_API:-18797}
VIEWS=indexer_core_e2e
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80                        # anvil 0: deployer
PRIYA_PK=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a                  # anvil 4
PRIYA=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
S1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; S2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
COMMITTEE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8,0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,0x90F79bf6EB2c4f870365E785982E1f101E93b906
FRI_OPEN=1791552600; T0=$((FRI_OPEN + 300)); BELL=$((FRI_OPEN + 22500 + 60))   # 13:35Z, then 19:46Z (bellAt 19:45Z)
REPORT_T='(bytes32,uint8,uint128,uint40,uint40,uint8,uint64)[]'
BOOK=deployments/31337.core-e2e-$$.local.json
if command -v psql >/dev/null; then q() { psql "$DB" -tAc "$1"; }
else q() { docker compose -f infra/docker-compose.yml exec -T postgres psql -U credence -d "${DB##*/}" -tAc "$1"; }; fi
tree() { local c; echo "$1"; for c in $(pgrep -P "$1" 2>/dev/null); do tree "$c"; done; }
cleanup() {
  local pids; pids=$( { for p in ${ANVIL_PID:-} ${PONDER_PID:-} ${API_PID:-}; do tree "$p"; done; } | tr '\n' ' ')
  [ -n "$pids" ] && { kill $pids 2>/dev/null || true; sleep 1; kill -9 $pids 2>/dev/null || true; }
  rm -f "$BOOK"
}
trap cleanup EXIT

anvil --port "$PORT" --timestamp $T0 --silent --code-size-limit 200000 --gas-limit 100000000 & ANVIL_PID=$!
for i in $(seq 1 50); do cast chain-id -r $RPC >/dev/null 2>&1 && break; sleep 0.2; done
send() { cast send "$@" -r $RPC >/dev/null; }
at() { cast rpc evm_setNextBlockTimestamp "$1" -r $RPC >/dev/null; cast rpc evm_mine -r $RPC >/dev/null; }
now() { cast block latest -f timestamp -r $RPC; }

echo "── 1. DeployCoreLocal (scratch anvil)"
( cd contracts && PRIVATE_KEY=$PK RELAYER_A_SIGNERS=$COMMITTEE RELAYER_B_SIGNERS=$COMMITTEE COVER_PREMIUM=35950000 OUT=../$BOOK \
    XNYS_CALENDAR=../calibration/out/calendars/XNYS-20261001-20271031.json USBANK_CALENDAR=../calibration/out/calendars/USBANK-20261001-20271031.json \
    forge script script/DeployCoreLocal.s.sol:DeployCoreLocal --rpc-url $RPC --broadcast --slow -q >/dev/null )
b() { jq -r "$1" $BOOK; }
MARKET=$(b .equity.market); VAULT=$(b .equity.vault); ENGINE=$(b .shared.riskEngine); CLOCK=$(b .shared.clock)
FEEDA=$(b .shared.feedA); FEEDB=$(b .shared.feedB); TNVDA=$(b .tokens.tNVDA); NVDA=$(b .assetIds.NVDA); ID=$(b .equity.markets.NVDA)
echo "   market $MARKET, vault $VAULT, NVDA market $ID, $(jq '.equity.markets | length' $BOOK)+$(jq '.nav.markets | length' $BOOK) markets"

push() {  # $1 feed, $2 kind, $3 price (WAD), $4 observedAt
  local seq r d a b
  seq=$(( $(cast call $1 'latestSeq(bytes32)(uint64)' $NVDA -r $RPC) + 1 ))
  r="[($NVDA,$2,$3,$4,$((FRI_OPEN / 86400)),2,$seq)]"
  d=$(cast call $1 "hashReports($REPORT_T)(bytes32)" "$r" -r $RPC)
  a=$(cast wallet sign --no-hash $d --private-key $S1); b=$(cast wallet sign --no-hash $d --private-key $S2)
  send $1 "submit($REPORT_T,bytes[])" "$r" "[$b,$a]" --private-key $PK      # ascending signer order (0x3C44… < 0x7099…)
}
live() { local t; t=$(now); push $FEEDA 0 $1 $t; push $FEEDB 0 $1 $t; send $CLOCK 'poke(bytes32)' $NVDA --private-key $PK; }

echo "── 2. Scenario A, Friday: Priya borrows at \$180 (weekend safe LTV 71.26% injected, cover quoted at \$35.95)"
send $ENGINE 'setSafeLtv(bytes32,uint8,uint256)' $NVDA 2 712580117506000000 --private-key $PK
live 180000000000000000000
send $TNVDA 'mint(address,uint256)' $PRIYA 500000000000000000000 --private-key $PK
send $TNVDA 'approve(address,uint256)' $MARKET $(cast max-uint) --private-key $PRIYA_PK
send $MARKET 'addCollateral(bytes32,address,uint256)' $ID $PRIYA 500000000000000000000 --private-key $PRIYA_PK
send $MARKET 'borrow(bytes32,uint256,address)' $ID 67000000000 $PRIYA --private-key $PRIYA_PK
echo "   Priya: 500 tNVDA, debt $(cast call $MARKET 'debtOf(bytes32,address)(uint256)' $ID $PRIYA -r $RPC | cut -d' ' -f1)"

echo "── 3. Ponder + API on this chain (views schema $VIEWS)"
LOG=$(mktemp); API_LOG=$(mktemp)
( cd indexer && DATABASE_URL=$DB PONDER_CHAIN_ID=31337 PONDER_RPC_URL=$RPC DEPLOYMENTS_FILE=../$BOOK PONDER_TELEMETRY_DISABLED=true \
    npx ponder start --schema core_e2e_$$ --views-schema $VIEWS --port $PORT_PONDER >"$LOG" 2>&1 ) & PONDER_PID=$!
( cd services/api && DATABASE_URL=$DB API_PORT=$PORT_API INDEXER_SCHEMA=$VIEWS RPC_URL=$RPC CHAIN_ID=31337 SESSION_SECRET=$(head -c 32 /dev/urandom | base64) \
    node src/server.ts >"$API_LOG" 2>&1 ) & API_PID=$!
wait_for() { for i in $(seq 1 120); do eval "$1" && return 0; sleep 1; done; echo "timeout: $1"; tail -20 "$LOG"; tail -20 "$API_LOG"; exit 1; }
wait_for "[ \"\$(q \"select count(*) from $VIEWS.position where owner = lower('$PRIYA')\" 2>/dev/null | tr -d '[:space:]')\" = 1 ]"
wait_for "curl -sf localhost:$PORT_API/readyz >/dev/null"

M=$(curl -sf localhost:$PORT_API/v1/markets)
echo "$M" | jq -c '[.markets[] | {stack, maxLtv: .maxLtv.percent, borrow: .totalBorrow.formatted, rate: .live.borrowRate.percent, next: .live.nextClosure.closureType.name}] | .[0:3]'
echo "$M" | jq -e '(.markets | length) == 7 and ([.markets[] | select(.stack == "nav")] | length) == 1' >/dev/null
echo "$M" | jq -e --arg id $ID 'any(.markets[]; .marketId == $id and .totalBorrow.formatted == "67000" and .live.borrowRate.raw != "0")' >/dev/null
V=$(curl -sf localhost:$PORT_API/v1/vault/equity)
echo "$V" | jq -c '{totalAssets: .totalAssets.formatted, sharePrice, apy: .apy.percent, idle: .idle.formatted}'
echo "$V" | jq -e '(.totalAssets.formatted | tonumber) >= 1000000' >/dev/null
P=$(curl -sf localhost:$PORT_API/v1/positions/$PRIYA)
echo "$P" | jq -c '.positions[] | {collateral, debt: .live.debt.formatted, ltv: .live.ltv.percent, hf: .live.healthFactor.percent, coveredForNext: .cover.coveredForNext}'
echo "$P" | jq -e '(.positions | length) == 1 and .positions[0].live.collateralValue.formatted == "90000" and .positions[0].cover.coveredForNext == false' >/dev/null

echo "── 4. The Bell (19:46Z): enforceBell auto-covers Priya; the index and the API follow"
at $BELL
live 180000000000000000000
send $MARKET 'enforceBell(bytes32,address[])' $ID "[$PRIYA]" --private-key $PK
wait_for "[ \"\$(q \"select count(*) from $VIEWS.position_event where owner = lower('$PRIYA') and kind in ('bell_enforced', 'cover_bought')\" 2>/dev/null | tr -d '[:space:]')\" = 2 ]"
q "select kind, amounts->>'outcome' as outcome, amounts->>'premium' as premium from $VIEWS.position_event where owner = lower('$PRIYA') order by block, id" | sed 's/^/   /'
P=$(curl -sf localhost:$PORT_API/v1/positions/$PRIYA)
echo "$P" | jq -c '.positions[] | {debt: .live.debt.formatted, coveredClosureId: .cover.coveredClosureId, coveredForNext: .cover.coveredForNext}'
echo "$P" | jq -e '.positions[0].cover.coveredForNext == true' >/dev/null
[ "$(q "select amounts->>'outcome' from $VIEWS.position_event where owner = lower('$PRIYA') and kind = 'bell_enforced'" | tr -d '[:space:]')" = 2 ] || { echo "expected AUTO_COVERED (2)"; exit 1; }
[ "$(q "select amounts->>'premium' from $VIEWS.position_event where owner = lower('$PRIYA') and kind = 'cover_bought'" | tr -d '[:space:]')" = 35950000 ] || { echo "expected premium 35950000"; exit 1; }
echo "OK: markets, the vault and Priya's position (borrow → Bell → auto-cover) indexed and served by the API"
