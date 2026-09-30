#!/usr/bin/env bash
# S3 gas on the devnode with the REAL Stylus engine (acceptance 6, PM gas ruling):
#   1. enforceBell when every borrower of the batch gets auto-cover through the real pool: gas for batches of
#      1, 2, 4, … N (eth_estimateGas), the largest batch within 24M gas (→ the keeper's J3 KEEPER_J3_BATCH), and
#      that batch sent for real;
#   2. writeCover (one buyCover);
#   3. an INTRADAY auction cleared with the 64-bid maximum (engine.clear on Stylus), fixLots and settlePositions.
# Own book (deployments/<chain>.gas.local.json) and engine; never touches the shared book.
#   LOCAL_RPC (default :8547)  PRIVATE_KEY (default the devnode dev key)  N (default 16)  BIDS (default 64)
# The Bell window is a 2 h constant and the pool must exist before it opens (§8.6.3), so bellAt is ≥ 1 h 45 min after
# the deploy on a clock that cannot be warped. No run may take that long (user, 2026-09-30), hence two phases:
#   PHASE=setup    deploy, N positions, bidders, writeCover in the window, the 64-bid auction (≈ 20 min); saves
#                  its state to GAS_STATE (default target/chain/gas-state.sh) and prints bellAt
#   PHASE=measure  from bellAt: enforceBell estimates per batch size, the J3 batch for real, the summary (≈ 5 min)
#   PHASE=all      (default) both, waiting for bellAt in between
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RPC="${LOCAL_RPC:-http://127.0.0.1:8547}"
KEY="${PRIVATE_KEY:-0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659}"
BUNDLE="${RISK_BUNDLE:-$ROOT/calibration/out/risk-bundle-889d50e4.json}"
N="${N:-16}"; BIDS="${BIDS:-64}"; LIMIT=24000000
PHASE="${PHASE:-all}"; STATE="${GAS_STATE:-$ROOT/target/chain/gas-state.sh}"
CHAIN="$(cast chain-id --rpc-url "$RPC")"
case "$CHAIN" in 421614|42161) echo "local only" >&2; exit 1 ;; esac
ME="$(cast wallet address --private-key "$KEY")"
BOOK="$ROOT/deployments/$CHAIN.gas.local.json"
FIX="$ROOT/contracts/test/fixtures/devnode"
SIGNER_KEYS=(0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
             0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d)
SIGNERS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8,0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,0x90F79bf6EB2c4f870365E785982E1f101E93b906
# gas limit = estimate × 1.3 (as the keeper, §10.2): an idle devnode estimates at its latest block's timestamp, which
# lags the wall clock, and the clock's poke then takes a cheaper branch than the mined tx (N = 32 borrows ran out of
# gas at 98.6% of a bare estimate)
gas_for() { # from-key to sig args… → a gas limit with the ×1.3 margin
  local k="$1" a=(); shift
  for x in "$@"; do [ "$x" = --json ] || a+=("$x"); done
  # a report stamped with the wall clock is "in the future" at that stale block (MAX_FUTURE_SKEW): then ≈ 3M flat
  local g; g="$(cast estimate --rpc-url "$RPC" --from "$(cast wallet address --private-key "$k")" "${a[@]}" 2>/dev/null)" \
    || g=2300000
  echo $(( g * 13 / 10 ))
}
sendk() { local k="$1"; shift; cast send --rpc-url "$RPC" --private-key "$k" --gas-limit "$(gas_for "$k" "$@")" "$@"; }
send() { sendk "$KEY" "$@" >/dev/null; }
say() { echo "[$(date +%H:%M:%S)] $*"; }

# 1. engine + bundle + core, deployed BEFORE the Bell window (a pool launched inside a window sells cover from the next
#    closure only, §8.6.3): the close is 2 h 08 min after the calendar is written (the window opens 8 min in, once the
#    N positions are open at maxLtv), bellAt 1 h 53 min after it
if [ "$PHASE" != measure ]; then
rm -f "$BOOK"
ENGINE_BOOK="$BOOK" DEVNODE_RPC="$RPC" DEVNODE_KEY="$KEY" bash "$ROOT/stylus/risk-engine/scripts/deploy.sh" >/dev/null
ENGINE="$(jq -r .shared.riskEngine "$BOOK")"
(cd "$ROOT" && RISK_ENGINE="$ENGINE" PRIVATE_KEY="$KEY" LOCAL_RPC="$RPC" RISK_BUNDLE="$BUNDLE" \
  RISK_BUNDLE_DIR="$(dirname "$BUNDLE")" bash contracts/script/load_risk_bundle.sh | tail -1)
mkdir -p "$FIX"
python3 "$ROOT/contracts/script/synthetic_calendar.py" "$(cast block latest --field timestamp --rpc-url "$RPC")" "$FIX" \
  --regular-minutes "${GAS_REGULAR_MIN:-128}" --closure-minutes 60 --session-minutes 180 --after 5 >/dev/null
(cd "$ROOT/contracts" && OUT="$BOOK" RISK_ENGINE="$ENGINE" PRIVATE_KEY="$KEY" RELAYER_A_SIGNERS="$SIGNERS" \
  RELAYER_B_SIGNERS="$SIGNERS" XNYS_CALENDAR="$FIX/XNYS-synthetic.json" USBANK_CALENDAR="$FIX/USBANK-synthetic.json" \
  SEED_EQUITY=12000000000000 SEED_POOL=50000000000000 \
  forge script script/DeployCoreLocal.s.sol:DeployCoreLocal --rpc-url "$RPC" --broadcast --slow >/dev/null)
say "core deployed: $(jq -r .equity.market "$BOOK")"
fi
[ -f "$BOOK" ] || { echo "no gas book $BOOK: run PHASE=setup first" >&2; exit 1; }
MARKET="$(jq -r .equity.market "$BOOK")"; HOUSE="$(jq -r .equity.auctionHouse "$BOOK")"; POOL="$(jq -r .equity.pool "$BOOK")"
USDC="$(jq -r .tokens.usdc "$BOOK")"; CLOCK="$(jq -r .shared.clock "$BOOK")"; SO="$(jq -r .shared.sigmaOracle "$BOOK")"
FEEDS=("$(jq -r .shared.feedA "$BOOK")" "$(jq -r .shared.feedB "$BOOK")")

price() { # asset price: a LIVE regular print on both feeds (2-of-3 signed)
  # stamp with the wall clock (the next block's time), not the latest block's: on a quiet devnode that block can be
  # tens of seconds old, and the report is then stale (60 s) when the borrow lands (BorrowPaused / HALTED)
  local now; now="$(cast block latest --field timestamp --rpc-url "$RPC")"
  [ "$(( $(date +%s) - 1 ))" -gt "$now" ] && now="$(( $(date +%s) - 1 ))"
  for F in "${FEEDS[@]}"; do
    local seq; seq=$(( $(cast call --rpc-url "$RPC" "$F" 'latestSeq(bytes32)(uint64)' "$1") + 1 ))
    local r="[($1,0,$2,$now,0,2,$seq)]" t='(bytes32,uint8,uint128,uint40,uint40,uint8,uint64)[]'
    local d; d="$(cast call --rpc-url "$RPC" "$F" "hashReports($t)(bytes32)" "$r")"
    send "$F" "submit($t,bytes[])" "$r" \
      "[$(cast wallet sign --no-hash --private-key "${SIGNER_KEYS[0]}" "$d"),$(cast wallet sign --no-hash --private-key "${SIGNER_KEYS[1]}" "$d")]"
  done
  send "$CLOCK" 'poke(bytes32)' "$1"
}
# waits keep both feeds fresh (as the relayer does): a feed older than 60 s in REGULAR halts the asset (fail closed)
declare -A PX
wait_until() { while [ "$(date +%s)" -le "$1" ]; do for a in "${!PX[@]}"; do price "$a" "${PX[$a]}"; done; sleep 15; done; }
A="$(jq -r .assetIds.AAPL "$BOOK")"; ID="$(jq -r .equity.markets.AAPL "$BOOK")"; T="$(jq -r .tokens.tAAPL "$BOOK")"
NV="$(jq -r .assetIds.NVDA "$BOOK")"; NID="$(jq -r .equity.markets.NVDA "$BOOK")"; NT="$(jq -r .tokens.tNVDA "$BOOK")"
PX[$A]=200000000000000000000; PX[$NV]=180000000000000000000
closure_at() { # asset field → a closureInfo time (the clock is lazy: poke first; 0 means the calendar is not read yet)
  local v; v="$(cast call --json --rpc-url "$RPC" "$CLOCK" 'closureInfo(bytes32)((uint8,uint8,uint64,uint64,uint128,uint40,uint40,uint40,uint40,uint40,uint128,uint40,uint40,uint32,uint32,uint40,bool,bool))' "$1" | jq -r "flatten | .[$2]")"
  [ "$v" != 0 ] || { echo "closureInfo($1)[$2] is 0" >&2; exit 1; }; echo "$v"
}

if [ "$PHASE" != measure ]; then

# 2. N borrowers on AAPL at 72% (before the Bell window the limit is maxLtv), 64 funded bidders
declare -a BK BA
send "$T" 'mint(address,uint256)' "$ME" "$(( N * 100 ))000000000000000000"
send "$T" 'approve(address,uint256)' "$MARKET" "$(( N * 100 ))000000000000000000"
price "$A" 200000000000000000000
for i in $(seq 0 $((N - 1))); do
  BK[$i]="$(cast wallet new --json | jq -r '(.data // .)[0].private_key')"; BA[$i]="$(cast wallet address --private-key "${BK[$i]}")"
  cast send --rpc-url "$RPC" --private-key "$KEY" "${BA[$i]}" --value 0.2ether >/dev/null
  send "$MARKET" 'addCollateral(bytes32,address,uint256)' "$ID" "${BA[$i]}" 100000000000000000000
  st=0x0
  for _ in 1 2 3; do # the borrow cross-checks both feeds (60 s in REGULAR): re-price and retry a BorrowPaused
    price "$A" 200000000000000000000
    st="$(sendk "${BK[$i]}" "$MARKET" 'borrow(bytes32,uint256,address)' "$ID" 14400000000 "${BA[$i]}" --json | jq -r '(.data // .).status')" || st=0x0
    [ "$st" = 0x1 ] && break
  done
  [ "$st" = 0x1 ] || { echo "borrow $i failed" >&2; exit 1; }
done
say "$N AAPL positions at 72%"
declare -a XK XA
for i in $(seq 0 $((BIDS - 1))); do
  XK[$i]="$(cast wallet new --json | jq -r '(.data // .)[0].private_key')"; XA[$i]="$(cast wallet address --private-key "${XK[$i]}")"
  cast send --rpc-url "$RPC" --private-key "$KEY" "${XA[$i]}" --value 0.2ether >/dev/null
  send "$USDC" 'mint(address,uint256)' "${XA[$i]}" 100000000000
  sendk "${XK[$i]}" "$USDC" 'approve(address,uint256)' "$HOUSE" 100000000000 >/dev/null
done
say "$BIDS bidders funded"
# AAPL weekend σ → 5% through SigmaOracle: every borrower is now above the safe LTV at the Bell
U="($A,2,50000000000000000,$(( $(cast block latest --field timestamp --rpc-url "$RPC") / 86400 )),1)"
UD="$(cast call --rpc-url "$RPC" "$SO" 'hashUpdate((bytes32,uint8,uint256,uint32,uint64))(bytes32)' "$U")"
send "$SO" 'submit((bytes32,uint8,uint256,uint32,uint64),bytes[])' "$U" \
  "[$(cast wallet sign --no-hash --private-key "${SIGNER_KEYS[0]}" "$UD"),$(cast wallet sign --no-hash --private-key "${SIGNER_KEYS[1]}" "$UD")]"

# 3. writeCover: one voluntary cover in the Bell window, before the deadline (NVDA, 72%)
price "$NV" 180000000000000000000   # the clock is lazy: poke before reading its times
WIN="$(closure_at "$NV" 6)"
say "waiting for the Bell window at $WIN"
wait_until "$WIN"
price "$NV" 180000000000000000000
KC="$(cast wallet new --json | jq -r '(.data // .)[0].private_key')"; C="$(cast wallet address --private-key "$KC")"
cast send --rpc-url "$RPC" --private-key "$KEY" "$C" --value 0.2ether >/dev/null
send "$NT" 'mint(address,uint256)' "$C" 100000000000000000000
sendk "$KC" "$NT" 'approve(address,uint256)' "$MARKET" 100000000000000000000 >/dev/null
sendk "$KC" "$MARKET" 'addCollateral(bytes32,address,uint256)' "$NID" "$C" 100000000000000000000 >/dev/null
price "$NV" 180000000000000000000
sendk "$KC" "$MARKET" 'borrow(bytes32,uint256,address)' "$NID" 12960000000 "$C" >/dev/null
price "$NV" 180000000000000000000
RCV="$(sendk "$KC" "$MARKET" 'buyCover(bytes32,uint256,bool)' "$NID" 1000000000 true --json)"
[ "$(echo "$RCV" | jq -r .status)" = 0x1 ] || { echo "buyCover failed: $RCV" >&2; exit 1; }
GAS_COVER="$(echo "$RCV" | jq -r .gasUsed | cast to-dec)"
say "buyCover (one writeCover through the pool and the Stylus engine): $GAS_COVER"

# 4. an INTRADAY lot on NVDA cleared with the 64-bid maximum
send "$HOUSE" 'setTimings(uint8,uint40[4])' 1 '[15,15,300,300]'
KL="$(cast wallet new --json | jq -r '(.data // .)[0].private_key')"; L="$(cast wallet address --private-key "$KL")"
cast send --rpc-url "$RPC" --private-key "$KEY" "$L" --value 0.2ether >/dev/null
send "$NT" 'mint(address,uint256)' "$L" 1000000000000000000000
sendk "$KL" "$NT" 'approve(address,uint256)' "$MARKET" 1000000000000000000000 >/dev/null
sendk "$KL" "$MARKET" 'addCollateral(bytes32,address,uint256)' "$NID" "$L" 1000000000000000000000 >/dev/null
price "$NV" 180000000000000000000
sendk "$KL" "$MARKET" 'borrow(bytes32,uint256,address)' "$NID" 133000000000 "$L" >/dev/null
price "$NV" 150000000000000000000
PX[$NV]=150000000000000000000
send "$MARKET" 'flagForAuction(bytes32,address[])' "$NID" "[$L]"
AID=$(( $(cast call --rpc-url "$RPC" "$HOUSE" 'nextAuctionId()(uint64)') - 1 ))
AT='(uint8,uint8,bytes32,bytes32,uint64,uint64,uint32,uint40[4],uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint16,uint16,bool,bool)'
field() { cast call --json --rpc-url "$RPC" "$HOUSE" "auction(uint64)($AT)" "$AID" | jq -r "flatten | .[$(($1 - 1))]"; }
sleep 16
price "$NV" 150000000000000000000
GAS_FIX="$(sendk "$KEY" "$HOUSE" 'fixLots(uint64)' "$AID" --json | jq -r .gasUsed | cast to-dec)"
LOT="$(field 12)"
for i in $(seq 0 $((BIDS - 1))); do
  q=$(python3 -c "print($LOT // $BIDS + 1)"); p=$(python3 -c "print(146 * 10**18 + $i * 10**16)")
  sendk "${XK[$i]}" "$HOUSE" 'placeBid(uint64,uint128,uint128)' "$AID" "$q" "$p" >/dev/null
done
say "$BIDS bids placed on lot $LOT"
wait_until "$(field 11)"
price "$NV" 150000000000000000000
RC="$(cast send --rpc-url "$RPC" --private-key "$KEY" --gas-limit 30000000 "$HOUSE" 'clear(uint64)' "$AID" --json)"
GAS_CLEAR="$(echo "$RC" | jq -r .gasUsed | cast to-dec)"
GAS_SETTLE="$(sendk "$KEY" "$MARKET" 'settlePositions(uint64,address[])' "$AID" "[$L]" --json | jq -r .gasUsed | cast to-dec)"
say "fixLots (1 position) $GAS_FIX, clear ($BIDS bids) $GAS_CLEAR (status $(echo "$RC" | jq -r .status)), settlePositions (1) $GAS_SETTLE"

price "$A" 200000000000000000000
BELL_AT="$(closure_at "$A" 7)"
{ declare -p BA; echo "GAS_COVER=$GAS_COVER GAS_FIX=$GAS_FIX GAS_CLEAR=$GAS_CLEAR GAS_SETTLE=$GAS_SETTLE BELL_AT=$BELL_AT"
  echo "CLEAR_STATUS=$(echo "$RC" | jq -r .status)"; } > "$STATE"
say "setup done, state in $STATE; the measure phase runs from bellAt $BELL_AT ($(date -d "@$BELL_AT" +%H:%M:%S))"
fi
[ "$PHASE" = setup ] && exit 0
# shellcheck disable=SC1090
source "$STATE"
PX[$NV]=150000000000000000000

# 5. enforceBell at the Bell deadline: estimates per batch size, then the largest batch within 24M for real
say "waiting for bellAt $BELL_AT"
wait_until "$BELL_AT"
batch() { local s="["; for i in $(seq 0 $(($1 - 1))); do s="$s${BA[$i]},"; done; echo "${s%,}]"; }
declare -A G
best=0
for k in 1 2 4 8 12 16 20 24 32; do
  [ "$k" -le "$N" ] || break
  price "$A" 200000000000000000000
  g="$(cast estimate --rpc-url "$RPC" --from "$ME" "$MARKET" 'enforceBell(bytes32,address[])' "$ID" "$(batch "$k")" 2>/dev/null || echo 0)"
  G[$k]="$g"; say "enforceBell($k, all auto-covered): ${g:-over the block limit}"
  [ "$g" != 0 ] && [ "$g" -le "$LIMIT" ] && best="$k"
done
# linear fit through 1 and the largest measured size below the limit → the J3 batch
if [ "$best" -gt 1 ]; then
  per=$(( (G[$best] - G[1]) / (best - 1) )); base=$(( G[1] - per ))
  J3=$(( (LIMIT - base) / per ))
else J3=1; fi
[ "$J3" -gt "$N" ] && J3="$N"
price "$A" 200000000000000000000
R="$(cast send --rpc-url "$RPC" --private-key "$KEY" --gas-limit 30000000 "$MARKET" 'enforceBell(bytes32,address[])' "$ID" "$(batch "$J3")" --json)"
covered="$(echo "$R" | jq --arg t "$(cast keccak 'AutoCoverApplied(bytes32,address,uint64,uint256,uint256)')" '[.logs[] | select(.topics[0]==$t)] | length')"
say "enforceBell($J3) sent: status $(echo "$R" | jq -r .status), gas $(echo "$R" | jq -r .gasUsed | cast to-dec), auto-covered $covered"

echo "GAS SUMMARY"
echo "  buyCover/writeCover            $GAS_COVER"
for k in "${!G[@]}"; do echo "  enforceBell($k) estimate        ${G[$k]}"; done | sort -t'(' -k2 -n
echo "  J3 batch within 24M gas        $J3 (sent: auto-covered $covered)"
echo "  clear ($BIDS bids)                $GAS_CLEAR"
echo "  fixLots (1) / settle (1)       $GAS_FIX / $GAS_SETTLE"
