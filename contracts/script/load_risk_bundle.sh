#!/usr/bin/env bash
# Load an ADR-0106 risk bundle into a Stylus Risk Engine (router) on a local chain and verify every hash on-chain.
# forge cannot execute WASM, so `LoadScenarioSet.plan()` writes the calls and the checks, and cast sends / reads them.
#   RISK_BUNDLE (abs path)  RISK_BUNDLE_DIR (abs path)  RISK_ENGINE  PRIVATE_KEY  LOCAL_RPC
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHAIN="$(cast chain-id --rpc-url "$LOCAL_RPC")"
case "$CHAIN" in 421614|42161) echo "local only" >&2; exit 1 ;; esac
SENDER="$(cast wallet address --private-key "$PRIVATE_KEY")"
PLAN="$ROOT/deployments/$CHAIN.risk-load.local.json"
(cd "$ROOT/contracts" && SENDER="$SENDER" RISK_ENGINE="$RISK_ENGINE" RISK_BUNDLE="$RISK_BUNDLE" RISK_BUNDLE_DIR="$RISK_BUNDLE_DIR" \
  forge script script/LoadScenarioSet.s.sol:LoadScenarioSet --sig "plan()" --rpc-url "$LOCAL_RPC" >/dev/null)
n="$(jq '.calls | length' "$PLAN")"
for i in $(seq 0 $((n - 1))); do
  to="$(jq -r ".calls[$i].to" "$PLAN")"; data="$(jq -r ".calls[$i].data" "$PLAN")"; what="$(jq -r ".calls[$i].what" "$PLAN")"
  status="$(cast send --rpc-url "$LOCAL_RPC" --private-key "$PRIVATE_KEY" "$to" "$data" --json | jq -r .status)"
  [ "$status" = "0x1" ] || { echo "call $i ($what) reverted" >&2; exit 1; }
done
fail=0
m="$(jq '.checks | length' "$PLAN")"
for i in $(seq 0 $((m - 1))); do
  data="$(jq -r ".checks[$i].data" "$PLAN")"; want="$(jq -r ".checks[$i].want" "$PLAN")"; what="$(jq -r ".checks[$i].what" "$PLAN")"
  got="$(cast call --rpc-url "$LOCAL_RPC" "$RISK_ENGINE" "$data")"
  if [ "$got" = "$want" ]; then echo "ok   $what $got"; else echo "MISMATCH $what: engine $got, file $want"; fail=1; fi
done
[ $fail = 0 ] && echo "risk bundle loaded: $n calls, $m hashes verified on $RISK_ENGINE (chain $CHAIN)"
exit $fail
