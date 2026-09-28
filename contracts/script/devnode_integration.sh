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
BUNDLE="${RISK_BUNDLE:-$ROOT/calibration/out/risk-bundle-889d50e4.json}"
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

# 2. a synthetic calendar centred on the devnode's clock (it cannot be warped): today's session runs from now − 2 h
#    to now + 4 h and is followed by a WEEKEND closure, so the market is in REGULAR with live prices
mkdir -p "$FIX"
python3 "$ROOT/contracts/script/synthetic_calendar.py" "$NOW" "$FIX" --after 7 --regular-hours 4 >/dev/null
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
    report_submit "$FEED" 0 "$PRICE" "$(cast block latest --field timestamp --rpc-url "$RPC")" 0 2
  done
}
live
send "$CLOCK" 'poke(bytes32)' "$ASSET"
STATE="$(cast call --rpc-url "$RPC" "$CLOCK" 'state(bytes32)(uint8)' "$ASSET")"
echo "ok   clock state $STATE (0 REGULAR, 1 EXTENDED, 2 CLOSED)"

# σ through the real J7 path: a 2-of-3 EIP-712 SigmaUpdate to SigmaOracle, which writes the engine (R-15):
# NVDA WEEKEND σ → 4%, so the weekend safe LTV drops below 75%
SO="$(jq -r .shared.sigmaOracle "$BOOK")"
U="($ASSET,2,40000000000000000,$(( $(cast block latest --field timestamp --rpc-url "$RPC") / 86400 )),1)"
UD="$(cast call --rpc-url "$RPC" "$SO" 'hashUpdate((bytes32,uint8,uint256,uint32,uint64))(bytes32)' "$U")"
send "$SO" 'submit((bytes32,uint8,uint256,uint32,uint64),bytes[])' "$U" \
  "[$(cast wallet sign --no-hash --private-key "${SIGNER_KEYS[0]}" "$UD"),$(cast wallet sign --no-hash --private-key "${SIGNER_KEYS[1]}" "$UD")]"
check "σ written through SigmaOracle" "$(cast call --rpc-url "$RPC" "$ENGINE" 'sigma(bytes32,uint8)(uint256)' "$ASSET" 2 | cut -d' ' -f1)" 40000000000000000

# a real position: 100 tNVDA, borrow 13,000 USDC (72%: allowed at maxLtv before the Bell window; the borrow calls
# engine.safeLtv on-chain), which is above the weekend safe LTV at the Bell
send "$TOKEN" 'mint(address,uint256)' "$ME" 100000000000000000000
send "$TOKEN" 'approve(address,uint256)' "$MARKET" 100000000000000000000
send "$MARKET" 'addCollateral(bytes32,address,uint256)' "$ID" "$ME" 100000000000000000000
live   # the borrow's cross-check needs both feeds fresh (60 s in REGULAR)
send "$MARKET" 'borrow(bytes32,uint256,address)' "$ID" 13000000000 "$ME"
live
echo "ok   borrow of 13,000 USDC through the market (safeLtv checked by the Stylus engine)"

# 4. compare with risk-cli on the same set
CT="$(cast call --rpc-url "$RPC" "$CLOCK" 'closureWindow(bytes32)(uint40,uint40,uint8)' "$ASSET" | tail -1)"
SETFILE="$(python3 -c "
import json,os,sys; b=json.load(open('$BUNDLE')); d=os.path.dirname('$BUNDLE')
print(next(os.path.join(d,f) for f in b['scenarioSets'] if json.load(open(os.path.join(d,f))).get('asset')=='NVDA:XNAS' and json.load(open(os.path.join(d,f)))['closureType']==$CT))")"
SIGMA="$(cast call --rpc-url "$RPC" "$ENGINE" 'sigma(bytes32,uint8)(uint256)' "$ASSET" "$CT" | cut -d' ' -f1)"
PARAMS="$(cast call --rpc-url "$RPC" "$ENGINE" 'params()((uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint32))' | tr -d '() ' | sed 's/\[[^]]*\]//g')"
IFS=, read -r ALPHA KAPPA THETA COC ETA BETA UMAX MINP KSTRESS <<< "$PARAMS"
Z="$(jq -c .z "$SETFILE")"

MKT_LIMIT="$(cast call --rpc-url "$RPC" "$MARKET" 'borrowLimitLtv(bytes32,address)(uint256)' "$ID" "$ME" | cut -d' ' -f1)"
CLI_SAFE="$("$CLI" safe-ltv-from-set "{\"set\":$Z,\"alpha\":\"$ALPHA\",\"sigma\":\"$SIGMA\",\"kappa\":\"$KAPPA\",\"maxLtv\":\"750000000000000000\"}" | jq -r .safeLtv)"
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

[ $fail = 0 ] && echo "devnode integration: market ↔ Stylus engine == risk-cli"
exit $fail
