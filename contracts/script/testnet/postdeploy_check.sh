#!/usr/bin/env bash
# make testnet-postdeploy-check (ADR-0122; Build Guide §13.3): exits non-zero on any mismatch.
#   postdeploy_check.sh equity|nav   (DRY_RUN=1 for the anvil dry run's book)
# 1. PostDeployCheck.s.sol (forge, read-only): roles, Safes, timelock, calendar, committees, markets, caps, oracle
#    wiring, faucet, issuers.
# 2. The engine (cast: forge cannot run the Stylus programs): every set / joint hash and the params of every configured
#    bundle; the ADR-0116 local TBILL fixture is NOT loaded; the programs have code and, on a real chain, more than
#    360 days of activation left (ArbWasm.programTimeLeft).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STACK="${1:?usage: postdeploy_check.sh equity|nav}"
# shellcheck source=env.sh
source "$ROOT/contracts/script/testnet/env.sh"
[ -f "$BOOK" ] || { echo "no book $BOOK" >&2; exit 1; }
DEPLOYER="${DEPLOYER:-$(jq -r '.deployer // empty' "$BOOK")}"
: "${DEPLOYER:?DEPLOYER, the address of the deploy account}"
export DEPLOYER BOOK
fail=0

echo "== contracts"
OUT="$(mktemp)"
(cd "$ROOT/contracts" && forge script script/testnet/PostDeployCheck.s.sol:PostDeployCheck --rpc-url "$RPC" > "$OUT" 2>&1) \
  || fail=1
grep -E "post-deploy checks|MISMATCH|OK:|Error|revert" "$OUT" | grep -vE "console::log|[├└]─" \
  | sed 's/ | MISMATCH /\n  MISMATCH /g' | awk '!seen[$0]++' || cat "$OUT"
rm -f "$OUT"

echo "== engine"
ROUTER="$(jq -r .shared.riskEngine "$BOOK")"
for b in "${RISK_BUNDLES[@]}"; do
  PLAN="$ROOT/deployments/.check-plan.$$.json"
  (cd "$ROOT/contracts" && SENDER="$(jq -r .shared.timelock "$BOOK")" RISK_ENGINE="$ROUTER" RISK_BUNDLE="$b" \
    RISK_BUNDLE_DIR="$(dirname "$b")" PLAN_OUT="$PLAN" \
    forge script script/LoadScenarioSet.s.sol:LoadScenarioSet --sig "plan()" --rpc-url "$RPC" >/dev/null)
  m="$(jq '.checks | length' "$PLAN")"; bad=0
  for i in $(seq 0 $((m - 1))); do
    got="$(cast call --rpc-url "$RPC" "$ROUTER" "$(jq -r ".checks[$i].data" "$PLAN")")"
    [ "$got" = "$(jq -r ".checks[$i].want" "$PLAN")" ] || { echo "MISMATCH $(jq -r ".checks[$i].what" "$PLAN")"; bad=1; }
  done
  rm -f "$PLAN"
  [ $bad = 0 ] && echo "ok   $(basename "$b"): $m hashes" || fail=1
done
if [ "$STACK" = nav ]; then
  TB="$(jq -r .assetIds.TBILL "$BOOK")"
  for f in "$ROOT"/contracts/test/fixtures/risk/tbill-local/TBILL-USBANK-*.json; do
    t="$(jq -r .closureType "$f")"
    if [ "$(cast call --rpc-url "$RPC" "$ROUTER" 'scenarioHash(bytes32,uint8)(bytes32)' "$TB" "$t")" = "$(jq -r .scenarioHash "$f")" ]; then
      echo "MISMATCH the ADR-0116 local TBILL fixture is loaded (closure type $t)"; fail=1
    fi
  done
  [ $fail = 0 ] && echo "ok   ADR-0116 fixture not loaded"
fi
for p in pricing auction; do
  a="$(cast call --rpc-url "$RPC" "$ROUTER" "$p()(address)")"
  [ -n "$(cast code --rpc-url "$RPC" "$a" | sed 's/^0x$//')" ] || { echo "MISMATCH engine $p program has no code"; fail=1; }
  if [ "${DRY_RUN:-0}" != 1 ]; then
    left="$(cast call --rpc-url "$RPC" 0x0000000000000000000000000000000000000071 'programTimeLeft(address)(uint64)' "$a" | cut -d' ' -f1)"
    [ "$left" -gt $((360 * 86400)) ] && echo "ok   $p program: $((left / 86400)) days of activation left" \
      || { echo "MISMATCH $p program: $left s of activation left (< 360 days)"; fail=1; }
  fi
done
[ "${DRY_RUN:-0}" = 1 ] && echo "note: DRY RUN: the programs are Solidity stand-ins (anvil cannot run WASM); not a real engine"

if [ $fail = 0 ]; then echo "POST-DEPLOY CHECK PASSED ($STACK, $BOOK)"; else echo "POST-DEPLOY CHECK FAILED ($STACK)"; fi
exit $fail
