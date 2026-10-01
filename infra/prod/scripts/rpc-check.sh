#!/usr/bin/env bash
# make ops-rpc-check: every RPC of both chains, in failover order (secrets/rpc.env, then the keyless public endpoint):
# the chain id and the head block, or why it failed. Prints the provider's host only, never the URL (its path holds
# the key). Exits non-zero if a chain has no working RPC or an endpoint answers with the wrong chain id.
set -uo pipefail
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV="${SECRETS_DIR:-$P/secrets}/rpc.env"
[ -r "$ENV" ] || { echo "ops-rpc-check: no $ENV (make ops-secrets-init, then fill it in)" >&2; exit 1; }
set -a; . "$ENV"; set +a
RPC_46630_PUBLIC="${RPC_46630_PUBLIC:-https://rpc.testnet.chain.robinhood.com}"
RPC_421614_PUBLIC="${RPC_421614_PUBLIC:-https://sepolia-rollup.arbitrum.io/rpc}"
host() { echo "$1" | sed -E 's#^[a-z]+://##; s#[/?].*$##'; }
rc=0
for c in 46630 421614; do
  ok=0
  for tier in PRIMARY SECONDARY PUBLIC; do
    v="RPC_${c}_${tier}"; u="${!v:-}"
    if [ -z "$u" ]; then printf '  %-7s %-9s (not set)\n' "$c" "$tier"; [ "$tier" = PUBLIC ] || rc=1; continue; fi
    id="$(timeout 10 cast chain-id --rpc-url "$u" 2>/dev/null)"
    head="$(timeout 10 cast block-number --rpc-url "$u" 2>/dev/null)"
    if [ -z "$id" ] || [ -z "$head" ]; then printf '  %-7s %-9s %-40s DOWN\n' "$c" "$tier" "$(host "$u")"; rc=1
    elif [ "$id" != "$c" ]; then printf '  %-7s %-9s %-40s WRONG CHAIN %s\n' "$c" "$tier" "$(host "$u")" "$id"; rc=1
    else printf '  %-7s %-9s %-40s chain %s head %s\n' "$c" "$tier" "$(host "$u")" "$id" "$head"; ok=1; fi
  done
  [ "$ok" = 1 ] || { echo "ops-rpc-check: chain $c has no working RPC" >&2; rc=1; }
done
[ "$rc" = 0 ] && echo "ops-rpc-check: OK" || echo "ops-rpc-check: FAILED (2 keyed providers per chain are expected)" >&2
exit "$rc"
