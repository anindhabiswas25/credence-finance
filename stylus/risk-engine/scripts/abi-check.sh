#!/usr/bin/env bash
# Every function and error the Stylus engine exports must exist, with the same selector, in the frozen
# Solidity interface deployments/abis/<ABI_VERSION>/IRiskEngine.json (Build Guide §8.9.1).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ABI="$ROOT/deployments/abis/${ABI_VERSION:-v0}/IRiskEngine.json"
cd "$ROOT"
EXPORT="$(cargo run -q -p credence-risk-engine --features export-abi --bin credence-risk-engine)"
# canonical signatures of the interface ABI
WANT="$(jq -r '.[] | select(.type=="function" or .type=="error") |
  .name + "(" + ([.inputs[] | if .type=="tuple" then "(" + ([.components[].type] | join(",")) + ")" else .type end] | join(",")) + ")"' "$ABI" | sort -u)"
RISKPARAMS="(uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint32)"
fail=0
while IFS= read -r line; do
  sig="$(echo "$line" | sed -E 's/^ *(function|error) ([A-Za-z0-9_]+)\(([^)]*)\).*/\2(\3)/')"
  name="${sig%%(*}"; args="${sig#*(}"; args="${args%)}"
  types="$(echo "$args" | tr ',' '\n' | sed -E 's/^ *//; s/ (memory|calldata)//; s/ [A-Za-z0-9_]+$//' | sed "s/^RiskParams\$/$RISKPARAMS/" | paste -sd, -)"
  canon="$name($types)"
  if echo "$WANT" | grep -qxF "$canon"; then echo "ok   $canon"; else echo "MISSING in IRiskEngine: $canon"; fail=1; fi
done < <(echo "$EXPORT" | grep -E '^ *(function|error) ')
exit $fail
