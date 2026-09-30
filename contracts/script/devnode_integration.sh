#!/usr/bin/env bash
# Devnode integration (brief E, acceptance 3): the CredenceMarket calling the REAL Stylus Risk Engine (router →
# PricingEngine + AuctionMath) for safeLtv / bellStatus, and the engine's quoteCover at the market's inputs, all
# compared with risk-cli on the same calibrated scenario set.
#   1. a dedicated engine (its own book: deployments/<chain>.integration.local.json) loaded with QE's risk bundle
#   2. DeployCoreLocal against it, on a synthetic calendar centred on the devnode's clock (test/fixtures/devnode)
#   3. signed LIVE reports on both feeds, a poke, a real borrow sent with cast
#   4. market.borrowLimitLtv / bellStatus / projectedDebt and engine.quoteCover vs risk-cli
# forge cannot execute Stylus WASM, so every transaction that reaches the engine is sent with cast.
#   LOCAL_RPC (default :8547)  PRIVATE_KEY (default the devnode dev key)  RISK_BUNDLE (default QE's S2 bundle)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RPC="${LOCAL_RPC:-http://127.0.0.1:8547}"
KEY="${PRIVATE_KEY:-0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659}"
BUNDLE="${RISK_BUNDLE:-$ROOT/calibration/out/risk-bundle-cfbb86cb.json}"
CLI="$ROOT/target/release/risk-cli"
CHAIN="$(cast chain-id --rpc-url "$RPC")"
case "$CHAIN" in 421614|42161) echo "local only" >&2; exit 1 ;; esac
ME="$(cast wallet address --private-key "$KEY")"
BOOK="$ROOT/deployments/$CHAIN.integration.local.json"
FIX="$ROOT/contracts/test/fixtures/devnode"
# the default local relayer committee (public anvil dev keys 1-3, local only), ascending by address
SIGNER_KEYS=(0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a   # 0x3C44…
             0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d)  # 0x7099…
SIGNERS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8,0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,0x90F79bf6EB2c4f870365E785982E1f101E93b906
fail=0
check() { # what got want
  if [ "$2" = "$3" ]; then echo "ok   $1 = $2"; else echo "MISMATCH $1: market/engine $2, risk-cli $3"; fail=1; fi
}
send() { cast send --rpc-url "$RPC" --private-key "$KEY" "$@" >/dev/null; }

cargo build -q --release -p credence-risk-cli --manifest-path "$ROOT/Cargo.toml"
NOW="$(cast block latest --field timestamp --rpc-url "$RPC")"

# 1. dedicated engine + QE's bundle
rm -f "$BOOK"
ENGINE_BOOK="$BOOK" DEVNODE_RPC="$RPC" DEVNODE_KEY="$KEY" bash "$ROOT/stylus/risk-engine/scripts/deploy.sh" >/dev/null
ENGINE="$(jq -r .shared.riskEngine "$BOOK")"
(cd "$ROOT" && RISK_ENGINE="$ENGINE" PRIVATE_KEY="$KEY" LOCAL_RPC="$RPC" RISK_BUNDLE="$BUNDLE" \
  RISK_BUNDLE_DIR="$(dirname "$BUNDLE")" bash contracts/script/load_risk_bundle.sh | tail -1)
# TBILL:USBANK has its own bundle (ADR-0118), loaded after the equity one
NAV_BUNDLE="${NAV_RISK_BUNDLE:-$ROOT/calibration/out/nav/risk-bundle-nav-5bdf292d.json}"
(cd "$ROOT" && RISK_ENGINE="$ENGINE" PRIVATE_KEY="$KEY" LOCAL_RPC="$RPC" RISK_BUNDLE="$NAV_BUNDLE" \
  RISK_BUNDLE_DIR="$(dirname "$NAV_BUNDLE")" bash contracts/script/load_risk_bundle.sh | tail -1)

# 2. a synthetic calendar centred on the devnode's clock (it cannot be warped): today's session runs from now − 2 h
#    to now + 2 h 12 min and is followed by a WEEKEND closure, so the market is in REGULAR with live prices. The pool
#    is deployed BEFORE the Bell window (close − 2 h): a pool that starts inside a window sells cover from the next
#    closure only (§8.6.3). Phase 5 waits for the window.
mkdir -p "$FIX"
python3 "$ROOT/contracts/script/synthetic_calendar.py" "$(cast block latest --field timestamp --rpc-url "$RPC")" "$FIX" \
  --after 7 --regular-hours 2.2 >/dev/null   # the Bell window opens 12 min in: the run stays under 30 min
XNYS="$FIX/XNYS-synthetic.json"; USBANK="$FIX/USBANK-synthetic.json"
(cd "$ROOT/contracts" && OUT="$BOOK" RISK_ENGINE="$ENGINE" PRIVATE_KEY="$KEY" RELAYER_A_SIGNERS="$SIGNERS" \
  RELAYER_B_SIGNERS="$SIGNERS" XNYS_CALENDAR="$XNYS" USBANK_CALENDAR="$USBANK" SEED_EQUITY=100000000000 \
  forge script script/DeployCoreLocal.s.sol:DeployCoreLocal --rpc-url "$RPC" --broadcast --slow >/dev/null)
MARKET="$(jq -r .equity.market "$BOOK")"; ID="$(jq -r .equity.markets.NVDA "$BOOK")"
ASSET="$(jq -r .assetIds.NVDA "$BOOK")"; CLOCK="$(jq -r .shared.clock "$BOOK")"; TOKEN="$(jq -r .tokens.tNVDA "$BOOK")"
[ "$(cast call --rpc-url "$RPC" "$MARKET" 'wiring()((address,address,address,address,address,address,address,address,address,address))' \
  | tr -d '()' | cut -d, -f3 | tr -d ' ')" = "$ENGINE" ] || { echo "market is not wired to the Stylus engine" >&2; exit 1; }
echo "ok   market $MARKET → engine $ENGINE (Stylus router)"

# 3. prices: a LIVE regular-session print on both feeds (2-of-3 signed); REGULAR needs no reference close
PRICE=180000000000000000000
stamp() { # report time: the wall clock (≈ the next block's time); the latest block can be tens of seconds old on a
  local b; b="$(cast block latest --field timestamp --rpc-url "$RPC")"   # quiet devnode, and its print then goes stale
  local w=$(( $(date +%s) - 1 )); [ "$w" -gt "$b" ] && echo "$w" || echo "$b"
}
report_submit() { # feed kind price observedAt sessionDate status
  local feed="$1" seq; seq=$(( $(cast call --rpc-url "$RPC" "$feed" 'latestSeq(bytes32)(uint64)' "$ASSET") + 1 ))
  local r="[($ASSET,$2,$3,$4,$5,$6,$seq)]" t='(bytes32,uint8,uint128,uint40,uint40,uint8,uint64)[]'
  local digest; digest="$(cast call --rpc-url "$RPC" "$feed" "hashReports($t)(bytes32)" "$r")"
  local s1 s2; s1="$(cast wallet sign --no-hash --private-key "${SIGNER_KEYS[0]}" "$digest")"
  s2="$(cast wallet sign --no-hash --private-key "${SIGNER_KEYS[1]}" "$digest")"
  send "$feed" "submit($t,bytes[])" "$r" "[$s1,$s2]"
}
live() {
  for FEED in "$(jq -r .shared.feedA "$BOOK")" "$(jq -r .shared.feedB "$BOOK")"; do
    report_submit "$FEED" 0 "$PRICE" "$(stamp)" 0 2
  done
}
live
send "$CLOCK" 'poke(bytes32)' "$ASSET"
STATE="$(cast call --rpc-url "$RPC" "$CLOCK" 'state(bytes32)(uint8)' "$ASSET")"
echo "ok   clock state $STATE (0 REGULAR, 1 EXTENDED, 2 CLOSED)"

# a real position: 100 tNVDA, borrow 13,000 USDC (72%: allowed at maxLtv before the Bell window; the borrow calls
# engine.safeLtv on-chain); the σ update below puts it above the weekend safe LTV at the Bell
send "$TOKEN" 'mint(address,uint256)' "$ME" 100000000000000000000
send "$TOKEN" 'approve(address,uint256)' "$MARKET" 100000000000000000000
send "$MARKET" 'addCollateral(bytes32,address,uint256)' "$ID" "$ME" 100000000000000000000
live   # the borrow's cross-check needs both feeds fresh (60 s in REGULAR)
send "$MARKET" 'borrow(bytes32,uint256,address)' "$ID" 13000000000 "$ME"
live
echo "ok   borrow of 13,000 USDC through the market (safeLtv checked by the Stylus engine)"

# σ through the real J7 path: a 2-of-3 EIP-712 SigmaUpdate to SigmaOracle, which writes the engine (R-15):
# NVDA WEEKEND σ → 4%, so the weekend safe LTV drops below 75%
SO="$(jq -r .shared.sigmaOracle "$BOOK")"
U="($ASSET,2,40000000000000000,$(( $(cast block latest --field timestamp --rpc-url "$RPC") / 86400 )),1)"
UD="$(cast call --rpc-url "$RPC" "$SO" 'hashUpdate((bytes32,uint8,uint256,uint32,uint64))(bytes32)' "$U")"
send "$SO" 'submit((bytes32,uint8,uint256,uint32,uint64),bytes[])' "$U" \
  "[$(cast wallet sign --no-hash --private-key "${SIGNER_KEYS[0]}" "$UD"),$(cast wallet sign --no-hash --private-key "${SIGNER_KEYS[1]}" "$UD")]"
check "σ written through SigmaOracle" "$(cast call --rpc-url "$RPC" "$ENGINE" 'sigma(bytes32,uint8)(uint256)' "$ASSET" 2 | cut -d' ' -f1)" 40000000000000000


# 4. compare with risk-cli on the same set
CT="$(cast call --rpc-url "$RPC" "$CLOCK" 'closureWindow(bytes32)(uint40,uint40,uint8)' "$ASSET" | tail -1)"
SETFILE="$(python3 -c "
import json,os,sys; b=json.load(open('$BUNDLE')); d=os.path.dirname('$BUNDLE')
print(next(os.path.join(d,f) for f in b['scenarioSets'] if json.load(open(os.path.join(d,f))).get('asset')=='NVDA:XNAS' and json.load(open(os.path.join(d,f)))['closureType']==$CT))")"
SIGMA="$(cast call --rpc-url "$RPC" "$ENGINE" 'sigma(bytes32,uint8)(uint256)' "$ASSET" "$CT" | cut -d' ' -f1)"
PARAMS="$(cast call --rpc-url "$RPC" "$ENGINE" 'params()((uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint32))' | tr -d '() ' | sed 's/\[[^]]*\]//g')"
IFS=, read -r ALPHA KAPPA THETA COC ETA BETA UMAX MINP KSTRESS <<< "$PARAMS"
Z="$(jq -c .z "$SETFILE")"

CLI_SAFE="$("$CLI" safe-ltv-from-set "{\"set\":$Z,\"alpha\":\"$ALPHA\",\"sigma\":\"$SIGMA\",\"kappa\":\"$KAPPA\",\"maxLtv\":\"750000000000000000\"}" | jq -r .safeLtv)"
MKT_LIMIT="$(cast call --rpc-url "$RPC" "$MARKET" 'borrowLimitLtv(bytes32,address)(uint256)' "$ID" "$ME" | cut -d' ' -f1)"
check "market.borrowLimitLtv before the Bell window (§8.2.2: maxLtv)" "$MKT_LIMIT" 750000000000000000
ENGINE_SAFE="$(cast call --rpc-url "$RPC" "$ENGINE" 'safeLtv(bytes32,uint8,uint256,uint256)(uint256)' "$ASSET" "$CT" 750000000000000000 0 | cut -d' ' -f1)"
check "safeLtv (engine, NVDA closure type $CT)" "$ENGINE_SAFE" "$CLI_SAFE"

DPROJ="$(cast call --rpc-url "$RPC" "$MARKET" 'projectedDebt(bytes32,address)(uint256)' "$ID" "$ME" | cut -d' ' -f1)"
VAL="$(cast call --rpc-url "$RPC" "$(jq -r .shared.oracle "$BOOK")" 'valuationPrice(bytes32)(uint256)' "$ASSET" | cut -d' ' -f1)"
C="$("$CLI" value "{\"qty\":\"100000000000000000000\",\"price\":\"$VAL\"}" | jq -r .collateralValue)"
read -r ST REPAY COLLV < <(cast call --rpc-url "$RPC" "$ENGINE" \
  'bellStatus(bytes32,uint8,uint256,uint256,uint256,uint256,bool)(uint8,uint256,uint256)' "$ASSET" "$CT" "$C" "$DPROJ" \
  750000000000000000 0 false | cut -d' ' -f1 | paste -sd' ')
CLI_BELL="$("$CLI" bell-status "{\"collateralValue\":\"$C\",\"debtProjected\":\"$DPROJ\",\"safeLtv\":\"$CLI_SAFE\",\"covered\":false}")"
check "bellStatus (engine, market inputs)" "$ST $REPAY $COLLV" "$(echo "$CLI_BELL" | jq -r '[.status,.cureRepay,.cureCollateralValue] | join(" ")')"
MKT_BELL="$(cast call --rpc-url "$RPC" "$MARKET" 'bellStatus(bytes32,address)(uint8,uint256,uint256,uint256)' "$ID" "$ME" | head -2 | cut -d' ' -f1 | paste -sd' ')"
[ "$(echo "$CLI_BELL" | jq -r .status)" = 1 ] || { echo "expected NEEDS_ACTION at the Bell" >&2; fail=1; }
check "market.bellStatus (status, cureRepay)" "$MKT_BELL" "$(echo "$CLI_BELL" | jq -r '[.status,.cureRepay] | join(" ")')"

DAYS="$(cast call --rpc-url "$RPC" "$CLOCK" 'closureDays(bytes32)(uint256)' "$ASSET" | cut -d' ' -f1)"
read -r PREM EL ES < <(cast call --rpc-url "$RPC" "$ENGINE" \
  'quoteCover(bytes32,uint8,uint16,uint256,uint256,uint256)(uint256,uint256,uint256)' "$ASSET" "$CT" "$DAYS" "$C" "$DPROJ" \
  200000000000000000 | cut -d' ' -f1 | paste -sd' ')
CLI_Q="$("$CLI" quote-cover "{\"set\":$Z,\"sigma\":\"$SIGMA\",\"kappa\":\"$KAPPA\",\"collateralValue\":\"$C\",\"debtProjected\":\"$DPROJ\",\"closureDays\":$DAYS,\"utilAfter\":\"200000000000000000\",\"theta\":\"$THETA\",\"costOfCap\":\"$COC\",\"eta\":\"$ETA\",\"beta\":\"$BETA\",\"minPremium\":\"$MINP\"}")"
check "quoteCover (engine, market inputs)" "$PREM $EL $ES" "$(echo "$CLI_Q" | jq -r '[.premium,.expectedLoss,.expectedShortfall] | join(" ")')"

# ═══ 5. S3: a real Gap Cover through the UnderwriterPool, and a real auction clear, on the Stylus engine ═══
POOL="$(jq -r .equity.pool "$BOOK")"; HOUSE="$(jq -r .equity.auctionHouse "$BOOK")"; USDC="$(jq -r .tokens.usdc "$BOOK")"
send "$USDC" 'mint(address,uint256)' "$ME" 1000000000000
send "$USDC" 'approve(address,uint256)' "$MARKET" 1000000000000
send "$USDC" 'approve(address,uint256)' "$HOUSE" 1000000000000
logdata() { # receipt-json event-signature → data of the first such log
  echo "$1" | jq -r --arg t "$(cast keccak "$2")" '[.logs[] | select(.topics[0]==$t)][0].data'
}
# the Bell window opens at close − 2 h: wait for it (the devnode clock cannot be warped)
WIN="$(( $(cast call --json --rpc-url "$RPC" "$CLOCK" 'closureInfo(bytes32)((uint8,uint8,uint64,uint64,uint128,uint40,uint40,uint40,uint40,uint40,uint128,uint40,uint40,uint32,uint32,uint40,bool,bool))' "$ASSET" | jq -r 'flatten | .[6]') ))"
echo "     waiting for the Bell window at $WIN ($(( WIN - $(date +%s) )) s)"
while [ "$(date +%s)" -le "$WIN" ]; do live; sleep 15; done   # keep the feeds fresh (a stale feed halts the asset)
# 5a. buyCover → pool.writeCover: coverLossVector + poolCapacity over the 6 markets + quoteCover at u_after (Stylus)
live
RC="$(cast send --rpc-url "$RPC" --private-key "$KEY" "$MARKET" 'buyCover(bytes32,uint256,bool)' "$ID" 1000000000 false --json)"
[ "$(echo "$RC" | jq -r .status)" = 0x1 ] || { echo "buyCover reverted: $RC" >&2; exit 1; }
BN="$(echo "$RC" | jq -r .blockNumber | cast to-dec)"
GAS_COVER="$(echo "$RC" | jq -r .gasUsed | cast to-dec)"
read -r EP _ PREMIUM UAFTER WORST < <(cast abi-decode 'f()(uint64,bytes32,uint256,uint256,uint256)' \
  "$(logdata "$RC" 'CoverWritten(uint64,bytes32,address,uint64,bytes32,uint256,uint256,uint256)')" | cut -d' ' -f1 | paste -sd' ')
DPROJ_B="$(cast call --rpc-url "$RPC" --block "$BN" "$MARKET" 'projectedDebt(bytes32,address)(uint256)' "$ID" "$ME" | cut -d' ' -f1)"
VAL_B="$(cast call --rpc-url "$RPC" --block "$BN" "$(jq -r .shared.oracle "$BOOK")" 'valuationPrice(bytes32)(uint256)' "$ASSET" | cut -d' ' -f1)"
C_B="$("$CLI" value "{\"qty\":\"100000000000000000000\",\"price\":\"$VAL_B\"}" | jq -r .collateralValue)"
CLI_P="$("$CLI" quote-cover "{\"set\":$Z,\"sigma\":\"$SIGMA\",\"kappa\":\"$KAPPA\",\"collateralValue\":\"$C_B\",\"debtProjected\":\"$DPROJ_B\",\"closureDays\":$DAYS,\"utilAfter\":\"$UAFTER\",\"theta\":\"$THETA\",\"costOfCap\":\"$COC\",\"eta\":\"$ETA\",\"beta\":\"$BETA\",\"minPremium\":\"$MINP\"}" | jq -r .premium)"
check "pool.writeCover premium (Stylus quoteCover at the pool's u_after $UAFTER)" "$PREMIUM" "$CLI_P"
EP_PREM="$(cast call --rpc-url "$RPC" "$POOL" 'epoch(uint64)((uint64,uint40,uint40,uint40,uint40,uint8,uint32,uint128,uint128,uint128,uint128,int128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128))' "$EP" --json | jq -r 'flatten | .[7]')"
check "pool epoch $EP premiums" "$EP_PREM" "$PREMIUM"
check "market.bellStatus after cover (COVERED)" "$(cast call --rpc-url "$RPC" "$MARKET" 'bellStatus(bytes32,address)(uint8,uint256,uint256,uint256)' "$ID" "$ME" | head -1)" 2
[ "$(echo "$UAFTER" | cut -d' ' -f1)" -le 500000000000000000 ] || { echo "u_after above u_max" >&2; fail=1; }

# 5b. an INTRADAY auction on AAPL: a second borrower at 74%, AAPL −10% → HF < 1 → flag → fix → bid → clear (Stylus
#     engine.clear) with the pool backstop → settle
K2="$(cast wallet new --json | jq -r '(.data // .)[0].private_key')"; B2="$(cast wallet address --private-key "$K2")"
cast send --rpc-url "$RPC" --private-key "$KEY" "$B2" --value 1ether >/dev/null
A2="$(jq -r .assetIds.AAPL "$BOOK")"; ID2="$(jq -r .equity.markets.AAPL "$BOOK")"; T2="$(jq -r .tokens.tAAPL "$BOOK")"
send "$T2" 'mint(address,uint256)' "$B2" 100000000000000000000
cast send --rpc-url "$RPC" --private-key "$K2" "$T2" 'approve(address,uint256)' "$MARKET" 100000000000000000000 >/dev/null
cast send --rpc-url "$RPC" --private-key "$K2" "$MARKET" 'addCollateral(bytes32,address,uint256)' "$ID2" "$B2" 100000000000000000000 >/dev/null
ASSET="$A2" PRICE=200000000000000000000 live
cast send --rpc-url "$RPC" --private-key "$K2" "$MARKET" 'borrow(bytes32,uint256,address)' "$ID2" 14800000000 "$B2" >/dev/null
ASSET="$A2" PRICE=180000000000000000000 live
send "$MARKET" 'flagForAuction(bytes32,address[])' "$ID2" "[$B2]"
AID=$(( $(cast call --rpc-url "$RPC" "$HOUSE" 'nextAuctionId()(uint64)') - 1 ))
AT='(uint8,uint8,bytes32,bytes32,uint64,uint64,uint32,uint40[4],uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint16,uint16,bool,bool)'
field() { cast call --json --rpc-url "$RPC" "$HOUSE" "auction(uint64)($AT)" "$AID" | jq -r "flatten | .[$(($1 - 1))]"; }
sleep 16
ASSET="$A2" PRICE=180000000000000000000 live
RF="$(cast send --rpc-url "$RPC" --private-key "$KEY" "$HOUSE" 'fixLots(uint64)' "$AID" --json)"
GAS_FIX="$(echo "$RF" | jq -r .gasUsed | cast to-dec)"
LOT="$(field 12)"; [ "$LOT" != 0 ] || { echo "empty lot" >&2; exit 1; }
BQ=$(python3 -c "print($LOT // 2)"); BP=178200000000000000000   # half the lot at 99% of $180
send "$HOUSE" 'placeBid(uint64,uint128,uint128)' "$AID" "$BQ" "$BP"
CLEAR_AT="$(field 11)"
while [ "$(date +%s)" -le "$CLEAR_AT" ]; do ASSET="$A2" PRICE=180000000000000000000 live; sleep 10; done
ASSET="$A2" PRICE=180000000000000000000 live
RCL="$(cast send --rpc-url "$RPC" --private-key "$KEY" "$HOUSE" 'clear(uint64)' "$AID" --json)"
[ "$(echo "$RCL" | jq -r .status)" = 0x1 ] || { echo "clear reverted: $RCL" >&2; exit 1; }
GAS_CLEAR="$(echo "$RCL" | jq -r .gasUsed | cast to-dec)"
read -r PSTAR FILLED QPOOL PROCEEDS BLENDED RES < <(cast abi-decode 'f()(uint256,uint256,uint256,uint256,uint256,uint256)' \
  "$(logdata "$RCL" 'AuctionCleared(uint64,uint256,uint256,uint256,uint256,uint256,uint256)')" | cut -d' ' -f1 | paste -sd' ')
TIE="$(cast keccak "$(cast abi-encode 'f(uint64,address)' "$AID" "$ME")")"
CLI_C="$("$CLI" clear "{\"qtys\":[\"$BQ\"],\"prices\":[\"$BP\"],\"tieKeys\":[\"$TIE\"],\"lot\":\"$LOT\",\"reserve\":\"$RES\"}")"
check "clear p* (Stylus engine.clear)" "$PSTAR" "$(echo "$CLI_C" | jq -r .pStar)"
check "clear fills" "$FILLED" "$(echo "$CLI_C" | jq -r '.fills[0]')"
check "clear qPool → pool backstop" "$QPOOL" "$(echo "$CLI_C" | jq -r .qPool)"
check "pool inventory (AAPL)" "$(cast call --rpc-url "$RPC" "$POOL" 'inventory(bytes32)((address,uint128,uint128,uint128,uint64))' "$A2" --json | jq -r 'flatten | .[1]')" "$QPOOL"
RS="$(cast send --rpc-url "$RPC" --private-key "$KEY" "$MARKET" 'settlePositions(uint64,address[])' "$AID" "[$B2]" --json)"
GAS_SETTLE="$(echo "$RS" | jq -r .gasUsed | cast to-dec)"
check "auction settled" "$(field 22)" true
send "$HOUSE" 'claim(uint64)' "$AID"
echo "gas: buyCover (writeCover) $GAS_COVER, fixLots (1 position) $GAS_FIX, clear (1 bid, backstop) $GAS_CLEAR, settlePositions (1) $GAS_SETTLE"

# ═══ 6. S4: NAV settlement through the Stylus router (ADR-0111): a solver fill, then a pool advance and its claim ═══
NMARKET="$(jq -r .nav.market "$BOOK")"; NID="$(jq -r .nav.markets.TBILL "$BOOK")"; ADAPTER="$(jq -r .nav.settlement "$BOOK")"
VENUE="$(jq -r .nav.solverAuction "$BOOK")"; NPOOL="$(jq -r .nav.pool "$BOOK")"; FUND="$(jq -r .tokens.tTBILL "$BOOK")"
TB="$(jq -r .assetIds.TBILL "$BOOK")"; FEEDNAV="$(jq -r .shared.feedNav "$BOOK")"; REG="$(jq -r .shared.registry "$BOOK")"
[ "$(cast call --rpc-url "$RPC" "$NMARKET" 'wiring()((address,address,address,address,address,address,address,address,address,address))' \
  | tr -d '()' | cut -d, -f3 | tr -d ' ')" = "$ENGINE" ] || { echo "NAV market is not wired to the Stylus engine" >&2; exit 1; }
send "$ADAPTER" 'setWindow(uint40)' 300   # the 5-min minimum, so the run stays short (launch: 15 min)
NAVP=1000000000000000000
nav_report() { # publish the NAV on the signed feed (what the oracle reads) and on the fund (what redemptions pay)
  # NAV prints must be strictly time-ordered (the feed ignores one at or before the last): never reuse a second
  local at; at="$(stamp)"; [ "$at" -le "${NAV_AT:-0}" ] && at=$(( NAV_AT + 1 )); NAV_AT="$at"
  NAVP="$1"; ASSET="$TB" report_submit "$FEEDNAV" 3 "$NAVP" "$at" 0 0
  send "$FUND" 'publishNav(uint256)' "$NAVP"
}
nav_report "$NAVP"
send "$CLOCK" 'poke(bytes32)' "$TB"
NST="$(cast call --rpc-url "$RPC" "$CLOCK" 'state(bytes32)(uint8)' "$TB")"
if [ "$NST" = 3 ]; then sleep 125; send "$ADAPTER" 'completeReopen(bytes32)' "$TB"; fi
check "TBILL clock REGULAR" "$(cast call --rpc-url "$RPC" "$CLOCK" 'state(bytes32)(uint8)' "$TB")" 0
nav_borrower() { # → private key of an allowlisted borrower with 100,000 tTBILL and 89,900 USDC borrowed (89.9 %)
  local k b; k="$(cast wallet new --json | jq -r '(.data // .)[0].private_key')"; b="$(cast wallet address --private-key "$k")"
  cast send --rpc-url "$RPC" --private-key "$KEY" "$b" --value 1ether >/dev/null
  send "$REG" 'setAllowed(address,bool)' "$b" true
  send "$FUND" 'mint(address,uint256)' "$b" 100000000000000000000000
  cast send --rpc-url "$RPC" --private-key "$k" "$FUND" 'approve(address,uint256)' "$NMARKET" 100000000000000000000000 >/dev/null
  cast send --rpc-url "$RPC" --private-key "$k" "$NMARKET" 'addCollateral(bytes32,address,uint256)' "$NID" "$b" 100000000000000000000000 >/dev/null
  cast send --rpc-url "$RPC" --private-key "$k" "$NMARKET" 'borrow(bytes32,uint256,address)' "$NID" 89900000000 "$b" >/dev/null
  echo "$k"
}
K3="$(nav_borrower)"; B3="$(cast wallet address --private-key "$K3")"
K4="$(nav_borrower)"; B4="$(cast wallet address --private-key "$K4")"
# eight NAV steps of −0.45 % (each under the 0.5 % one-step HALT): HF 1.034 → < 1
for _ in 1 2 3 4 5 6 7 8; do nav_report "$(python3 -c "print($NAVP * 9955 // 10000)")"; done
send "$CLOCK" 'poke(bytes32)' "$TB"
HF3="$(cast call --rpc-url "$RPC" "$NMARKET" 'healthFactor(bytes32,address)(uint256)' "$NID" "$B3" | cut -d' ' -f1)"
[ "$(python3 -c "print(int($HF3 < 10**18))")" = 1 ] || { echo "TBILL position not under water: HF $HF3" >&2; exit 1; }
echo "ok   NAV $NAVP: both TBILL positions at HF < 1 ($HF3)"
ST='(bytes32,bytes32,address,address,uint8,uint8,uint64,uint40,uint40,uint32,uint128,uint128,uint128,uint128,address,uint256,bool)'
sfield() { cast call --json --rpc-url "$RPC" "$ADAPTER" "settlement(uint64)($ST)" "$1" | jq -r "flatten | .[$(($2 - 1))]"; }
open_settlement() { # borrower → settlement id; the market sizes the lot on-chain with the Stylus liquidationLot
  local rc; rc="$(cast send --rpc-url "$RPC" --private-key "$KEY" "$ADAPTER" 'openSettlement(bytes32,address[])' "$NID" "[$1]" --json)"
  [ "$(echo "$rc" | jq -r .status)" = 0x1 ] || { echo "openSettlement reverted: $rc" >&2; exit 1; }
  echo "$rc" | jq -r --arg t "$(cast keccak 'SettlementOpened(uint64,bytes32,address,uint256,uint256,uint40)')" \
    '[.logs[] | select(.topics[0]==$t)][0].topics[1]' | cast to-dec
}
# 6a. B3: the solver (the deployer, allowlisted) bids 0.1 % over the floor → filled at T+0
S1="$(open_settlement "$B3")"; BN="$(cast block latest --field number --rpc-url "$RPC")"
Q1="$(sfield "$S1" 11)"; FLOOR1="$(sfield "$S1" 12)"; END1="$(sfield "$S1" 9)"
D3="$(cast call --rpc-url "$RPC" --block "$BN" "$NMARKET" 'debtOf(bytes32,address)(uint256)' "$NID" "$B3" | cut -d' ' -f1)"
V3="$(cast call --rpc-url "$RPC" --block "$BN" "$(jq -r .shared.oracle "$BOOK")" 'valuationPrice(bytes32)(uint256)' "$TB" | cut -d' ' -f1)"
CLI_X="$("$CLI" liquidation-lot "{\"debt\":\"$D3\",\"qty\":\"100000000000000000000000\",\"sizingPrice\":\"$FLOOR1\",\"hfPrice\":\"$V3\",\"lt\":\"930000000000000000\",\"hStar\":\"1100000000000000000\",\"lambda\":\"10000000000000000\"}" | jq -r .x)"
check "NAV lot (Stylus liquidationLot at κ_nav, floor = NAV × 99.5 %)" "$Q1" "$CLI_X"
check "floor = NAV × 0.995" "$FLOOR1" "$(python3 -c "print($V3 * 995 // 1000)")"
BID="$(python3 -c "print($FLOOR1 * 1001 // 1000)")"
send "$USDC" 'approve(address,uint256)' "$VENUE" 1000000000000
FUND_BEFORE="$(cast call --rpc-url "$RPC" "$FUND" 'balanceOf(address)(uint256)' "$ME" | cut -d' ' -f1)"
send "$VENUE" 'bid(uint64,uint256)' "$S1" "$BID"
echo "     waiting for the solver window to end at $END1 ($(( END1 - $(date +%s) )) s)"
while [ "$(cast block latest --field timestamp --rpc-url "$RPC")" -lt "$END1" ]; do sleep 10; send "$CLOCK" 'poke(bytes32)' "$TB"; done
RF1="$(cast send --rpc-url "$RPC" --private-key "$KEY" "$ADAPTER" 'finalize(uint64)' "$S1" --json)"
[ "$(echo "$RF1" | jq -r .status)" = 0x1 ] || { echo "finalize reverted: $RF1" >&2; exit 1; }
GAS_FIN1="$(echo "$RF1" | jq -r .gasUsed | cast to-dec)"
check "settlement $S1 FILLED" "$(sfield "$S1" 6)" 2
FUND_AFTER="$(cast call --rpc-url "$RPC" "$FUND" 'balanceOf(address)(uint256)' "$ME" | cut -d' ' -f1)"
check "solver received the lot" "$(python3 -c "print($FUND_AFTER - $FUND_BEFORE)")" "$Q1"   # 18-dec: beyond bash's 64 bits
check "cash in (solver escrow) = cash out (market proceeds)" "$(sfield "$S1" 14)" "$(python3 -c "q=$Q1;p=$BID;print(-(-q*p*10**6//10**36))")"
check "positions settled" "$(sfield "$S1" 17)" true

# 6b. B4: nobody bids → the pool advances qty × floor and requests the redemption; the issuer fulfils; the pool claims
S2="$(open_settlement "$B4")"; END2="$(sfield "$S2" 9)"; Q2="$(sfield "$S2" 11)"; FLOOR2="$(sfield "$S2" 12)"
while [ "$(cast block latest --field timestamp --rpc-url "$RPC")" -lt "$END2" ]; do sleep 10; send "$CLOCK" 'poke(bytes32)' "$TB"; done
RF2="$(cast send --rpc-url "$RPC" --private-key "$KEY" "$ADAPTER" 'finalize(uint64)' "$S2" --json)"
[ "$(echo "$RF2" | jq -r .status)" = 0x1 ] || { echo "finalize (advance) reverted: $RF2" >&2; exit 1; }
GAS_FIN2="$(echo "$RF2" | jq -r .gasUsed | cast to-dec)"
check "settlement $S2 ADVANCED" "$(sfield "$S2" 6)" 3
COST="$(python3 -c "print($Q2 * $FLOOR2 // 10**30)")"
check "pool advanced qty × floor" "$(sfield "$S2" 14)" "$COST"
check "claim in pool NAV at cost" "$(cast call --rpc-url "$RPC" "$NPOOL" 'redemptionClaimsOutstanding()(uint256)' | cut -d' ' -f1)" "$COST"
RQ="$(sfield "$S2" 16)"
send "$USDC" 'approve(address,uint256)' "$FUND" 1000000000000   # the fund pays at NAV from its reserve wallet (the deployer)
send "$FUND" 'fulfillRedeem(uint256)' "$RQ"   # the issuer operator (the deployer on local chains), next USBANK session on testnet
RC2="$(cast send --rpc-url "$RPC" --private-key "$KEY" "$NPOOL" 'claimRedemption(uint256)' "$RQ" --json)"
[ "$(echo "$RC2" | jq -r .status)" = 0x1 ] || { echo "claimRedemption reverted: $RC2" >&2; exit 1; }
check "claim cleared" "$(cast call --rpc-url "$RPC" "$NPOOL" 'redemptionClaimsOutstanding()(uint256)' | cut -d' ' -f1)" 0
echo "gas: NAV finalize with a fill $GAS_FIN1, with a pool advance $GAS_FIN2"

[ $fail = 0 ] && echo "devnode integration: market ↔ Stylus engine == risk-cli; real writeCover and clear through the pool and auction house; NAV settlement (solver fill, pool advance + claim)"
exit $fail
