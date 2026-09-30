#!/usr/bin/env bash
# Stylus live check on a public testnet (S5 Amendment 1, check 1): deploy + activate both engine programs behind a
# fresh RiskEngineRouter, load a small test set (the bundle's params and NVDA's three closure-type sets), set σ, then
# compare safeLtv, bellStatus, quoteCover and liquidationLot with risk-cli. A CHECK, not a deploy: the router's timelock
# and σ writer are the check key, nothing goes into an address book, and the key gets no protocol role.
#   RPC            default https://rpc.testnet.chain.robinhood.com (46630)
#   KEYSTORE       an encrypted cast keystore file (never a raw key)   PASSWORD_FILE  its password file
#   RISK_BUNDLE    default calibration/out/risk-bundle-cfbb86cb.json    OUT  default target/chain/stylus-live-<chain>
# Output: $OUT/result.json (addresses, txs, gas, activation fees, every comparison) and $OUT/*.log.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RPC="${RPC:-https://rpc.testnet.chain.robinhood.com}"
: "${KEYSTORE:?an encrypted cast keystore}"; : "${PASSWORD_FILE:?its password file}"
BUNDLE="${RISK_BUNDLE:-$ROOT/calibration/out/risk-bundle-cfbb86cb.json}"
CHAIN="$(cast chain-id --rpc-url "$RPC")"
case "$CHAIN" in 46630|421614|412346) ;; *) echo "testnets / devnode only (46630, 421614, 412346), not $CHAIN" >&2; exit 1 ;; esac
OUT="${OUT:-$ROOT/target/chain/stylus-live-$CHAIN}"; mkdir -p "$OUT"
KS=(--keystore "$KEYSTORE" --password-file "$PASSWORD_FILE")
# cargo stylus reads the password file verbatim (foundry trims it): hand it a copy without the trailing newline
PW_STYLUS="$(umask 077 && mktemp)"; trap 'rm -f "$PW_STYLUS"' EXIT
tr -d '\r\n' < "$PASSWORD_FILE" > "$PW_STYLUS"
ME="$(cast wallet address "${KS[@]}")"
DEPLOYER="${STYLUS_DEPLOYER:-0xcEcba2F1DC234f70Dd89F2041029807F8D03A990}"
CLI="$ROOT/target/release/risk-cli"
say() { echo "[$(date +%H:%M:%S)] $*"; }
fail=0; RES="$OUT/checks.txt"; : > "$RES"
check() { if [ "$2" = "$3" ]; then echo "ok   $1 = $2" | tee -a "$RES"; else echo "MISMATCH $1: engine $2, risk-cli $3" | tee -a "$RES"; fail=1; fi; }
send() { cast send --rpc-url "$RPC" "${KS[@]}" "$@" --json | tee -a "$OUT/sends.jsonl" | jq -e '.status == "0x1"' >/dev/null; }
[ -n "$(cast code "$DEPLOYER" --rpc-url "$RPC" | sed 's/^0x$//')" ] || { echo "no StylusDeployer at $DEPLOYER" >&2; exit 1; }
cargo build -q --release -p credence-risk-cli --manifest-path "$ROOT/Cargo.toml"
BAL0="$(cast balance "$ME" --rpc-url "$RPC")"
say "chain $CHAIN, key $ME, balance $(cast from-wei "$BAL0") ETH; ArbOS $(( $(cast call 0x0000000000000000000000000000000000000064 'arbOSVersion()(uint64)' --rpc-url "$RPC" | cut -d' ' -f1) - 55 )), stylusVersion $(cast call 0x0000000000000000000000000000000000000071 'stylusVersion()(uint16)' --rpc-url "$RPC")"

# 1. the router (timelock = σ writer = the check key). REUSE=1 keeps the router and programs of the last run in $OUT.
ROUTER_LOG="$OUT/router.log"
if [ "${REUSE:-0}" != 1 ]; then
(cd "$ROOT/contracts" && forge create src/risk/RiskEngineRouter.sol:RiskEngineRouter --rpc-url "$RPC" "${KS[@]}" \
  --broadcast --constructor-args "$ME" "$ME") > "$ROUTER_LOG" 2>&1 || { cat "$ROUTER_LOG" >&2; exit 1; }
fi
ROUTER="$(grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' "$ROUTER_LOG" | grep -oE '0x[0-9a-fA-F]{40}')"
ROUTER_TX="$(grep -oE 'Transaction hash: 0x[0-9a-fA-F]{64}' "$ROUTER_LOG" | grep -oE '0x[0-9a-fA-F]{64}')"
say "router $ROUTER"

# 2. both programs: deploy + activate through the StylusDeployer, constructed with the router as their only writer
WS="$("$ROOT/stylus/risk-engine/scripts/stylus-ws.sh")"
program() { # contract log args… → address
  local c="$1" log="$2"; shift 2
  (cd "$WS" && cargo stylus deploy --no-verify --contract "$c" --endpoint "$RPC" --keystore-path "$KEYSTORE" \
    --keystore-password-path "$PW_STYLUS" --deployer-address "$DEPLOYER" --constructor-args "$@" 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g') > "$log" || { cat "$log" >&2; exit 1; }
  grep -oE 'deployed code at address: 0x[0-9a-fA-F]{40}' "$log" | grep -oE '0x[0-9a-fA-F]{40}'
}
addr_in() { grep -oE 'deployed code at address: 0x[0-9a-fA-F]{40}' "$1" | grep -oE '0x[0-9a-fA-F]{40}'; }
if [ "${REUSE:-0}" = 1 ]; then
  PRICING="$(addr_in "$OUT/pricing.log")"; AUCTION="$(addr_in "$OUT/auction.log")"
else
  PRICING="$(program credence-risk-engine "$OUT/pricing.log" "$ROUTER" "$ROUTER")"
  AUCTION="$(program credence-auction-math "$OUT/auction.log" "$ROUTER")"
fi
[ -n "$PRICING" ] && [ -n "$AUCTION" ] || { echo "program deploy failed" >&2; exit 1; }
say "programs: pricing $PRICING, auction math $AUCTION"
lc() { tr '[:upper:]' '[:lower:]'; }
[ "$(cast call --rpc-url "$RPC" "$ROUTER" 'pricing()(address)' | lc)" = "$(echo "$PRICING" | lc)" ] \
  || send "$ROUTER" 'initializeWiring(address,address)' "$PRICING" "$AUCTION"
for p in "$PRICING" "$AUCTION"; do
  echo "$p activation time left: $(cast call 0x0000000000000000000000000000000000000071 'programTimeLeft(address)(uint64)' "$p" --rpc-url "$RPC" | cut -d' ' -f1) s" | tee -a "$RES"
done

# 3. a small test set: params + NVDA's three sets (the bundle's own calls), σ 4 % for each closure type
PLAN="$ROOT/deployments/.check-plan.stylus-live-$CHAIN.json"   # forge writes under deployments/ only (git-ignored name)
(cd "$ROOT/contracts" && SENDER="$ME" RISK_ENGINE="$ROUTER" RISK_BUNDLE="$BUNDLE" RISK_BUNDLE_DIR="$(dirname "$BUNDLE")" \
  PLAN_OUT="$PLAN" forge script script/LoadScenarioSet.s.sol:LoadScenarioSet --sig "plan()" --rpc-url "$RPC" >/dev/null)
mv "$PLAN" "$OUT/plan.json"; PLAN="$OUT/plan.json"
loaded() { jq -c '.checks[] | select(.what | test("NVDA-XNAS"))' "$PLAN" | while read -r c; do
  [ "$(cast call --rpc-url "$RPC" "$ROUTER" "$(echo "$c" | jq -r .data)")" = "$(echo "$c" | jq -r .want)" ] || echo no; done; }
if [ -n "$(loaded)" ]; then
  jq -c '.calls[] | select(.what == "setParams" or (.what | test("NVDA-XNAS")))' "$PLAN" | while read -r c; do
    send "$(echo "$c" | jq -r .to)" "$(echo "$c" | jq -r .data)" || { echo "load $(echo "$c" | jq -r .what) failed" >&2; exit 1; }
  done
fi
jq -c '.checks[] | select(.what | test("NVDA-XNAS"))' "$PLAN" | while read -r c; do
  got="$(cast call --rpc-url "$RPC" "$ROUTER" "$(echo "$c" | jq -r .data)")"
  [ "$got" = "$(echo "$c" | jq -r .want)" ] && echo "ok   hash $(echo "$c" | jq -r .what) $got" | tee -a "$RES" \
    || { echo "MISMATCH hash $(echo "$c" | jq -r .what)" | tee -a "$RES"; exit 1; }
done
ASSET="$(cast keccak "NVDA:XNAS")"; SIGMA=40000000000000000
for ct in 1 2 3; do
  [ "$(cast call --rpc-url "$RPC" "$ROUTER" 'sigma(bytes32,uint8)(uint256)' "$ASSET" "$ct" | cut -d' ' -f1)" = "$SIGMA" ] \
    || send "$ROUTER" 'updateSigma(bytes32,uint8,uint256)' "$ASSET" "$ct" "$SIGMA"
done
PARAMS="$(cast call --rpc-url "$RPC" "$ROUTER" 'params()((uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint32))' | tr -d '() ' | sed 's/\[[^]]*\]//g')"
IFS=, read -r ALPHA KAPPA THETA COC ETA BETA UMAX MINP KSTRESS <<< "$PARAMS"

# 4. engine vs risk-cli
C=100000000000; D=70000000000; MAXLTV=750000000000000000; U=200000000000000000
for ct in 1 2 3; do
  SET="$(python3 -c "
import json,os; b=json.load(open('$BUNDLE')); d=os.path.dirname('$BUNDLE')
print(next(os.path.join(d,f) for f in b['scenarioSets'] if json.load(open(os.path.join(d,f))).get('asset')=='NVDA:XNAS' and json.load(open(os.path.join(d,f)))['closureType']==$ct))")"
  Z="$(jq -c .z "$SET")"; DAYS=$([ $ct = 1 ] && echo 1 || echo 3)
  # the σ the engine prices with (sigmaAt is when σ was last written, for J7)
  SIG="$(cast call --rpc-url "$RPC" "$ROUTER" 'sigma(bytes32,uint8)(uint256)' "$ASSET" "$ct" | cut -d' ' -f1)"
  CLI_SAFE="$("$CLI" safe-ltv-from-set "{\"set\":$Z,\"alpha\":\"$ALPHA\",\"sigma\":\"$SIG\",\"kappa\":\"$KAPPA\",\"maxLtv\":\"$MAXLTV\"}" | jq -r .safeLtv)"
  check "safeLtv NVDA type $ct" "$(cast call --rpc-url "$RPC" "$ROUTER" 'safeLtv(bytes32,uint8,uint256,uint256)(uint256)' "$ASSET" "$ct" "$MAXLTV" 0 | cut -d' ' -f1)" "$CLI_SAFE"
  read -r ST RP CV < <(cast call --rpc-url "$RPC" "$ROUTER" 'bellStatus(bytes32,uint8,uint256,uint256,uint256,uint256,bool)(uint8,uint256,uint256)' \
    "$ASSET" "$ct" "$C" "$D" "$MAXLTV" 0 false | cut -d' ' -f1 | paste -sd' ')
  check "bellStatus NVDA type $ct" "$ST $RP $CV" "$("$CLI" bell-status "{\"collateralValue\":\"$C\",\"debtProjected\":\"$D\",\"safeLtv\":\"$CLI_SAFE\",\"covered\":false}" | jq -r '[.status,.cureRepay,.cureCollateralValue] | join(" ")')"
  read -r PR EL ES < <(cast call --rpc-url "$RPC" "$ROUTER" 'quoteCover(bytes32,uint8,uint16,uint256,uint256,uint256)(uint256,uint256,uint256)' \
    "$ASSET" "$ct" "$DAYS" "$C" "$D" "$U" | cut -d' ' -f1 | paste -sd' ')
  check "quoteCover NVDA type $ct ($DAYS d)" "$PR $EL $ES" "$("$CLI" quote-cover "{\"set\":$Z,\"sigma\":\"$SIG\",\"kappa\":\"$KAPPA\",\"collateralValue\":\"$C\",\"debtProjected\":\"$D\",\"closureDays\":$DAYS,\"utilAfter\":\"$U\",\"theta\":\"$THETA\",\"costOfCap\":\"$COC\",\"eta\":\"$ETA\",\"beta\":\"$BETA\",\"minPremium\":\"$MINP\"}" | jq -r '[.premium,.expectedLoss,.expectedShortfall] | join(" ")')"
done
# liquidationLot: an equity lot (HF < 1 at 1.1 target) and a NAV-like lot (κ 1 %, LT 93 %)
for args in "80000000000 1000000000000000000000 95000000000000000000 100000000000000000000 800000000000000000 1100000000000000000 10000000000000000" \
            "91000000000 1000000000000000000000 99500000000000000000 100000000000000000000 930000000000000000 1100000000000000000 10000000000000000"; do
  read -r DEBT QTY SP HP LT HS LAM <<< "$args"
  check "liquidationLot debt $DEBT lt $LT" "$(cast call --rpc-url "$RPC" "$ROUTER" 'liquidationLot(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint8,uint8)(uint256)' \
    "$DEBT" "$QTY" "$SP" "$HP" "$LT" "$HS" "$LAM" 18 6 | cut -d' ' -f1)" \
    "$("$CLI" liquidation-lot "{\"debt\":\"$DEBT\",\"qty\":\"$QTY\",\"sizingPrice\":\"$SP\",\"hfPrice\":\"$HP\",\"lt\":\"$LT\",\"hStar\":\"$HS\",\"lambda\":\"$LAM\"}" | jq -r .x)"
done

# 5. gas and fees
row() { # label tx → json
  local r g l p v; r="$(cast receipt "$2" --rpc-url "$RPC" --json)"
  g="$(cast to-dec "$(echo "$r" | jq -r .gasUsed)")"; l="$(cast to-dec "$(echo "$r" | jq -r '.gasUsedForL1 // "0x0"')")"
  p="$(cast to-dec "$(echo "$r" | jq -r .effectiveGasPrice)")"
  v="$(cast tx "$2" value --rpc-url "$RPC" 2>/dev/null || echo 0)"; [ -n "$v" ] || v=0   # the activation fee rides as value
  jq -n --arg l "$1" --arg tx "$2" --argjson g "$g" --argjson l1 "$l" --argjson p "$p" --arg v "$v" \
    '{what: $l, tx: $tx, gasUsed: $g, gasUsedForL1: $l1, effectiveGasPrice: $p, valueWei: $v, feeWei: ($g * $p)}'
}
PTX="$(grep -oE 'deployment tx hash: 0x[0-9a-fA-F]{64}' "$OUT/pricing.log" | grep -oE '0x[0-9a-fA-F]{64}' | tail -1)"
ATX="$(grep -oE 'deployment tx hash: 0x[0-9a-fA-F]{64}' "$OUT/auction.log" | grep -oE '0x[0-9a-fA-F]{64}' | tail -1)"
BAL1="$(cast balance "$ME" --rpc-url "$RPC")"
{ row router "$ROUTER_TX"; row "pricing deploy+activate" "$PTX"; row "auction math deploy+activate" "$ATX"; } | jq -s \
  --arg chain "$CHAIN" --arg router "$ROUTER" --arg p "$PRICING" --arg a "$AUCTION" --arg spent "$(( BAL0 - BAL1 ))" \
  --arg pfee "$(grep -iE 'data fee' "$OUT/pricing.log" | head -1)" --arg afee "$(grep -iE 'data fee' "$OUT/auction.log" | head -1)" \
  --rawfile checks "$RES" \
  --arg bal "$BAL1" \
  '{chainId: ($chain | tonumber), router: $router, pricing: $p, auctionMath: $a, txs: ., spentThisRunWei: $spent, balanceAfterWei: $bal,
    activationDataFee: {pricing: $pfee, auctionMath: $afee}, checks: ($checks | split("\n") | map(select(. != "")))}' \
  > "$OUT/result.json"
say "spent $(cast from-wei $(( BAL0 - BAL1 ))) ETH; result $OUT/result.json"
[ $fail = 0 ] && say "STYLUS LIVE CHECK PASSED on chain $CHAIN" || say "STYLUS LIVE CHECK FAILED on chain $CHAIN"
exit $fail
