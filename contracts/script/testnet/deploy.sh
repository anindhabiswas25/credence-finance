#!/usr/bin/env bash
# One testnet stack, end to end (ADR-0122):
#   deploy.sh equity   → Robinhood Chain testnet (46630), book deployments/46630.json
#   deploy.sh nav      → Arbitrum Sepolia (421614),       book deployments/421614.json
#   DRY_RUN=1 deploy.sh <stack>   → plain anvil (chain 31337, DRY_RPC, default :8560): the canonical Safe v1.4.1
#     contracts copied in from the stack's chain, Solidity stand-ins for the Stylus programs, anvil accounts for the
#     user / Engineer B inputs; book deployments/31337.<stack>.dryrun.json
# Steps: 1 DeployTestnet (Safes, timelock at delay 0 with the deployer, every contract, listing) → 2 the Stylus
# programs (cargo stylus deploy; stand-ins on anvil) → 3 router wiring → 4 the risk bundles, each call scheduled and
# executed through the timelock, every hash read back → 5 FinalizeTestnet (Gov Safe, 1 h, no deployer role) →
# 6 postdeploy_check.sh. The book also gets each contract's deploy block, the linked libraries and the ABI tag
# (book_meta.sh). Refuses a re-run (the book exists), a missing input, and another chain.
# Real chains: DEPLOYER_KEYSTORE (a keystore file) or DEPLOYER_ACCOUNT (a `cast wallet import`ed name), and
# DEPLOYER_PASSWORD_FILE; never a key in the env. FORK=1 (fork_rehearsal.sh): the same path against an anvil fork of the
# stack's chain, with the Stylus stand-ins and the book deployments/<chainId>.fork.json.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STACK="${1:?usage: deploy.sh equity|nav}"
# shellcheck source=env.sh
source "$ROOT/contracts/script/testnet/env.sh"
say() { echo "[$(date +%H:%M:%S)] $*"; }
# a deployed stack is never deployed twice: refuse before anything is sent (or copied, in the dry run)
refuse_if_deployed() {
  [ -f "$BOOK" ] && { echo "refusing: $BOOK exists (a stack is deployed; a re-run would make a second one)" >&2; exit 1; }
  return 0
}

if [ "${DRY_RUN:-0}" = 1 ]; then
  if ! cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
    port="${RPC##*:}"; anvil --port "$port" --chain-id 31337 --silent & ANVIL_PID=$!
    trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
    until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do sleep 0.2; done
    rm -f "$BOOK"   # a fresh anvil: the old dry-run book describes nothing
  fi
  [ "$(cast chain-id --rpc-url "$RPC")" = 31337 ] || { echo "DRY_RPC is not plain anvil (31337)" >&2; exit 1; }
  refuse_if_deployed
  REAL_RPC="$(cfg .rpc)"
  # Safe v1.4.1 factory, singleton, fallback handler, and MultiSendCallOnly (gov.sh); read-only, a public RPC that
  # hangs fails the dry run
  for a in 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762 \
           0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99 0x9641d764fc13c8B624c04430C7356C1C7C8102e2; do
    code="$(timeout 60 cast code "$a" --rpc-url "$REAL_RPC")" && [ "${#code}" -gt 2 ] \
      || { echo "could not read the canonical Safe contract $a from $REAL_RPC" >&2; exit 1; }
    cast rpc --rpc-url "$RPC" anvil_setCode "$a" "$code" >/dev/null
  done
  KEY=(--private-key "$PRIVATE_KEY")
  if [ "$STACK" = equity ]; then   # the official Robinhood test TSLA does not exist on anvil: its behavioural copy
    REG="$(cd "$ROOT/contracts" && forge create test/mocks/MockRobinhoodStock.sol:MockAccessControlsRegistry \
      --rpc-url "$RPC" "${KEY[@]}" --broadcast | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}')"
    RH="$(cd "$ROOT/contracts" && forge create test/mocks/MockRobinhoodStock.sol:MockRobinhoodStock --rpc-url "$RPC" \
      "${KEY[@]}" --broadcast --constructor-args Tesla TSLA "$REG" \
      | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}')"
    export ASSET_TOKENS="$(echo "$ASSET_TOKENS" | sed -E "s/0x[0-9a-fA-F]{40}/$RH/")"
  fi
else
  [ "$(cast chain-id --rpc-url "$RPC")" = "$CID" ] || { echo "RPC is not chain $CID" >&2; exit 1; }
  refuse_if_deployed
  # DEPLOYER_KEYSTORE (a keystore file), or DEPLOYER_ACCOUNT (a name in ~/.foundry/keystores)
  if [ -z "${DEPLOYER_KEYSTORE:-}" ]; then
    : "${DEPLOYER_ACCOUNT:?a cast keystore account (cast wallet import <name> --interactive) or DEPLOYER_KEYSTORE}"
    DEPLOYER_KEYSTORE="$HOME/.foundry/keystores/$DEPLOYER_ACCOUNT"
  fi
  [ -f "$DEPLOYER_KEYSTORE" ] || { echo "no keystore $DEPLOYER_KEYSTORE" >&2; exit 1; }
  : "${DEPLOYER_PASSWORD_FILE:?the keystore password file}"
  export DEPLOYER="$(cast wallet address --keystore "$DEPLOYER_KEYSTORE" --password-file "$DEPLOYER_PASSWORD_FILE")"
  KEY=(--keystore "$DEPLOYER_KEYSTORE" --password-file "$DEPLOYER_PASSWORD_FILE")
fi
send() { cast send --rpc-url "$RPC" "${KEY[@]}" "$@" --json | jq -e '.status == "0x1"' >/dev/null; }

say "1/6 DeployTestnet ($STACK, chain $(cast chain-id --rpc-url "$RPC"), deployer $DEPLOYER)"
(cd "$ROOT/contracts" && forge script script/testnet/DeployTestnet.s.sol:DeployTestnet --rpc-url "$RPC" \
  --broadcast --slow "${KEY[@]}" --sender "$DEPLOYER" >/dev/null)
ROUTER="$(jq -r .shared.riskEngine "$BOOK")"; TL="$(jq -r .shared.timelock "$BOOK")"

say "2/6 risk-engine programs for router $ROUTER"
STYLUS_FROM_BLOCK="$(cast block-number --rpc-url "$RPC")"   # the programs' start block (a lower bound) for the book
if [ "${DRY_RUN:-0}" = 1 ] || [ "${FORK:-0}" = 1 ]; then   # anvil (plain or a fork) cannot run WASM: the stand-ins
  create() { (cd "$ROOT/contracts" && forge create "script/testnet/DryRunPrograms.sol:$1" --rpc-url "$RPC" "${KEY[@]}" \
    --broadcast --constructor-args "$ROUTER" | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}'); }
  PRICING="$(create DryRunPricingProgram)"; AUCTION="$(create DryRunAuctionMathProgram)"; P_META=dry-run; A_META=dry-run
  P_TX=""; A_TX=""
else
  WS="$("$ROOT/stylus/risk-engine/scripts/stylus-ws.sh")"
  KS="$DEPLOYER_KEYSTORE"
  # cargo stylus reads the password file verbatim (foundry trims it): a copy without the trailing newline
  PW_STYLUS="$(umask 077 && mktemp)"; trap 'rm -f "$PW_STYLUS"' EXIT
  tr -d '\r\n' < "$DEPLOYER_PASSWORD_FILE" > "$PW_STYLUS"
  LOGS="$ROOT/target/testnet-deploy/$CID"; mkdir -p "$LOGS"   # kept: the deploy logs survive a failed run
  program() { # contract args… → address (the deployment tx stays in $LOGS/<contract>.log for testnet-verify)
    (cd "$WS" && cargo stylus deploy --no-verify --contract "$1" --endpoint "$RPC" --keystore-path "$KS" \
      --keystore-password-path "$PW_STYLUS" --constructor-args "${@:2}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g') \
      > "$LOGS/$1.log"
    grep -oE 'deployed code at address: 0x[0-9a-fA-F]{40}' "$LOGS/$1.log" | grep -oE '0x[0-9a-fA-F]{40}' | tail -1
  }
  dtx() { grep -oE 'deployment tx hash: 0x[0-9a-fA-F]{64}' "$LOGS/$1.log" | grep -oE '0x[0-9a-fA-F]{64}' | tail -1; }
  PRICING="$(program credence-risk-engine "$ROUTER" "$ROUTER")"; AUCTION="$(program credence-auction-math "$ROUTER")"
  P_TX="$(dtx credence-risk-engine)"; A_TX="$(dtx credence-auction-math)"
  P_META="$(sha256sum "$WS/target/wasm32-unknown-unknown/release/deps/credence_risk_engine.wasm" | cut -d' ' -f1)"
  A_META="$(sha256sum "$WS/target/wasm32-unknown-unknown/release/deps/credence_auction_math.wasm" | cut -d' ' -f1)"
fi
[ -n "$PRICING" ] && [ -n "$AUCTION" ] || { echo "program deploy failed" >&2; exit 1; }

say "3/6 router.initializeWiring($PRICING, $AUCTION)"
send "$ROUTER" 'initializeWiring(address,address)' "$PRICING" "$AUCTION"

say "4/6 risk bundles through the timelock"
for b in "${RISK_BUNDLES[@]}"; do
  PLAN="$ROOT/deployments/$(cast chain-id --rpc-url "$RPC").$STACK.risk-plan.$(basename "$b")"
  (cd "$ROOT/contracts" && SENDER="$TL" RISK_ENGINE="$ROUTER" RISK_BUNDLE="$b" RISK_BUNDLE_DIR="$(dirname "$b")" \
    PLAN_OUT="$PLAN" forge script script/LoadScenarioSet.s.sol:LoadScenarioSet --sig "plan()" --rpc-url "$RPC" >/dev/null)
  n="$(jq '.calls | length' "$PLAN")"
  for i in $(seq 0 $((n - 1))); do
    to="$(jq -r ".calls[$i].to" "$PLAN")"; data="$(jq -r ".calls[$i].data" "$PLAN")"
    salt="$(cast keccak "$(basename "$b")-$i")"
    send "$TL" 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' "$to" 0 "$data" 0x"$(printf '0%.0s' {1..64})" "$salt" 0
    send "$TL" 'execute(address,uint256,bytes,bytes32,bytes32)' "$to" 0 "$data" 0x"$(printf '0%.0s' {1..64})" "$salt" \
      || { echo "bundle call $i ($(jq -r ".calls[$i].what" "$PLAN")) failed" >&2; exit 1; }
  done
  m="$(jq '.checks | length' "$PLAN")"
  for i in $(seq 0 $((m - 1))); do
    got="$(cast call --rpc-url "$RPC" "$ROUTER" "$(jq -r ".checks[$i].data" "$PLAN")")"
    [ "$got" = "$(jq -r ".checks[$i].want" "$PLAN")" ] \
      || { echo "MISMATCH $(jq -r ".checks[$i].what" "$PLAN"): engine $got" >&2; exit 1; }
  done
  say "     $(basename "$b"): $n calls, $m hashes verified"
done

say "5/6 FinalizeTestnet (Gov Safe, delay $TIMELOCK_DELAY s, deployer roles revoked)"
(cd "$ROOT/contracts" && BOOK="$BOOK" forge script script/testnet/FinalizeTestnet.s.sol:FinalizeTestnet \
  --rpc-url "$RPC" --broadcast --slow "${KEY[@]}" --sender "$DEPLOYER" >/dev/null)
TMP="$(mktemp)"
jq --arg p "$PRICING" --arg a "$AUCTION" --arg pm "$P_META" --arg am "$A_META" --arg pt "$P_TX" --arg at "$A_TX" \
  '.stylus = {pricing: {address: $p, wasmSha256: $pm, deployTx: $pt}, auctionMath: {address: $a, wasmSha256: $am, deployTx: $at}}' \
  "$BOOK" > "$TMP" \
  && mv "$TMP" "$BOOK"
STYLUS_FROM_BLOCK="$STYLUS_FROM_BLOCK" bash "$ROOT/contracts/script/testnet/book_meta.sh" "$BOOK" "$(cast chain-id --rpc-url "$RPC")"

say "6/6 post-deploy check"
bash "$ROOT/contracts/script/testnet/postdeploy_check.sh" "$STACK"
say "done: $BOOK"
