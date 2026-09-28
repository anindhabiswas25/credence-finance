#!/usr/bin/env bash
# ABI parity of the split Risk Engine (Build Guide §8.9.1, R-24, ADR-0108), in both directions:
#   stylus/risk-engine  (PricingEngine) == IPricingEngine   (contracts/src/risk/IStylusPrograms.sol)
#   stylus/auction-math (AuctionMath)   == IAuctionMath
# The router implements IRiskEngine (checked by the compiler), so together the whole interface is live on-chain.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
RISKPARAMS="(uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint32)"
fail=0

# canonical "name(types)" of every function + error of a Solidity interface
want_sigs() {
  (cd contracts && forge inspect "$1" abi --json) | jq -r '.[] | select(.type=="function" or .type=="error") |
    .name + "(" + ([.inputs[] | if .type=="tuple" then "(" + ([.components[].type] | join(",")) + ")" else .type end] | join(",")) + ")"' | sort -u
}

# canonical "name(types)" of every function + error a Stylus crate exports
got_sigs() {
  cargo run -q -p "$1" --features export-abi --bin "$1" | grep -E '^ *(function|error) ' | while IFS= read -r line; do
    sig="$(echo "$line" | sed -E 's/^ *(function|error) ([A-Za-z0-9_]+)\(([^)]*)\).*/\2(\3)/')"
    name="${sig%%(*}"; args="${sig#*(}"; args="${args%)}"
    types="$(echo "$args" | tr ',' '\n' | sed -E 's/^ *//; s/ (memory|calldata)//; s/ [A-Za-z0-9_]+$//' \
      | sed "s/^RiskParams\$/$RISKPARAMS/" | paste -sd, -)"
    echo "$name($types)"
  done | sort -u
}

check() { # crate interface
  local got want
  got="$(got_sigs "$1")"
  want="$(want_sigs "$2")"
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    if echo "$want" | grep -qxF "$s"; then echo "ok   $1: $s"; else echo "NOT IN $2: $s"; fail=1; fi
  done <<< "$got"
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    echo "$got" | grep -qxF "$s" || { echo "NOT EXPORTED by $1: $s"; fail=1; }
  done <<< "$want"
}

check credence-risk-engine IPricingEngine
check credence-auction-math IAuctionMath
exit $fail
