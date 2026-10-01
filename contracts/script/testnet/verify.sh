#!/usr/bin/env bash
# make testnet-verify STACK=equity|nav (ADR-0122): verify every contract a testnet deploy created, and record each
# one's status in the stack's address book (.verify). Idempotent: a "verified" entry is skipped, anything else is
# retried, so a failure never undoes the deploy, it only leaves the target to re-run.
#   Solidity: every contract the deploy created (the book's .creations, written by book_meta.sh from the broadcast),
#     with its linked libraries and constructor arguments. 46630: Blockscout (`verify.url` in the config; no key). 421614: Arbiscan through the Etherscan v2 API
#     (ETHERSCAN_API_KEY). The Safes are canonical Safe v1.4.1 proxies (the explorers know the singleton): "canonical".
#     The size-profile contracts (optimizer_runs 200, ADR-0107) are verified with --compilation-profile size.
#   Stylus: `cargo stylus verify --deployment-tx <tx>` for pricing and auction-math, against the same local build that
#     deploy.sh deployed (--no-verify: deploy.sh builds outside docker, as live-check.sh proved on 46630; R-24's
#     stylus-repro shows that build is reproducible). The explorers' own Stylus source verification is a pre-mainnet row.
# Needs the book (deployments/<chainId>.json) and, for Stylus, the deployment txs deploy.sh wrote into it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STACK="${1:?usage: verify.sh equity|nav}"
# shellcheck source=env.sh
source "$ROOT/contracts/script/testnet/env.sh"
[ "${DRY_RUN:-0}" = 1 ] && { echo "nothing to verify on plain anvil" >&2; exit 2; }
[ -f "$BOOK" ] || { echo "no book $BOOK" >&2; exit 1; }
[ "$(jq '.creations | length' "$BOOK")" -gt 0 ] || { echo "no .creations in $BOOK (book_meta.sh)" >&2; exit 1; }
VERIFIER="$(cfg .verify.verifier)"
case "$VERIFIER" in
  blockscout) VARGS=(--verifier blockscout --verifier-url "$(cfg .verify.url)") ;;
  etherscan) : "${ETHERSCAN_API_KEY:?ETHERSCAN_API_KEY (an Etherscan v2 key; it covers Arbiscan)}"
    VARGS=(--verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY") ;;
  *) echo "unknown verifier $VERIFIER" >&2; exit 1 ;;
esac
say() { echo "[$(date +%H:%M:%S)] $*"; }
status() { jq -r --arg a "$(echo "$1" | tr A-F a-f)" '.verify[$a].status // "pending"' "$BOOK"; }
record() { # address name status [detail]
  local t; t="$(mktemp)"
  jq --arg a "$(echo "$1" | tr A-F a-f)" --arg n "$2" --arg s "$3" --arg d "${4:-}" --arg at "$(date -u +%FT%TZ)" \
    '.verify[$a] = ({name: $n, status: $s, at: $at} + (if $d == "" then {} else {detail: $d} end))' "$BOOK" > "$t" \
    && mv "$t" "$BOOK"
}

cd "$ROOT/contracts"
# linked libraries: path:Name:address for every library the deploy created
LIBS=()
while IFS=$'\t' read -r name src addr; do LIBS+=(--libraries "$src:$name:$addr"); done \
  < <(jq -r '.creations[] | select(.kind == "CREATE2") | [.name, .source, .address] | @tsv' "$BOOK")

ok=0; bad=0
while IFS=$'\t' read -r name src addr size args; do
  [ "$(status "$addr")" = verified ] && { ok=$((ok + 1)); continue; }
  extra=(); [ "$size" = true ] && extra=(--compilation-profile size)
  say "verify $name $addr"
  if out="$(forge verify-contract "$addr" "$src:$name" --chain "$CID" "${VARGS[@]}" "${LIBS[@]}" "${extra[@]}" \
      ${args:+--constructor-args "$args"} --watch --retries 10 --delay 15 2>&1)" \
      || echo "$out" | grep -qi "already verified"; then
    record "$addr" "$name" verified; ok=$((ok + 1))
  else
    record "$addr" "$name" failed "$(echo "$out" | grep -iE 'error|fail|reason' | tail -1 | cut -c1-200)"
    bad=$((bad + 1)); echo "$out" | tail -5 >&2
  fi
done < <(jq -r '.creations[] | [.name, .source, .address, (.sizeProfile | tostring), .constructorArgs] | @tsv' "$BOOK")

for s in gov guardian ops; do
  a="$(jq -r ".safes.$s" "$BOOK")"
  [ "$(status "$a")" = verified ] || record "$a" "Safe($s)" canonical "SafeProxy of the canonical Safe v1.4.1 factory"
done

# Stylus programs
if [ "$(jq -r '.stylus.pricing.deployTx // ""' "$BOOK")" = "" ]; then
  say "no Stylus deployment txs in the book: Stylus not verified"; bad=$((bad + 1))
else
  WS="$("$ROOT/stylus/risk-engine/scripts/stylus-ws.sh")"
  for p in pricing:credence-risk-engine auctionMath:credence-auction-math; do
    key="${p%%:*}"; crate="${p#*:}"
    a="$(jq -r ".stylus.$key.address" "$BOOK")"; tx="$(jq -r ".stylus.$key.deployTx" "$BOOK")"
    [ "$(status "$a")" = verified ] && { ok=$((ok + 1)); continue; }
    say "cargo stylus verify $crate $a"
    if out="$(cd "$WS" && cargo stylus verify --no-verify --contract "$crate" --endpoint "$RPC" --deployment-tx "$tx" 2>&1 \
        | sed 's/\x1b\[[0-9;]*m//g')" && echo "$out" | grep -q 'Verification successful'; then
      record "$a" "stylus:$crate" verified; ok=$((ok + 1))
    else
      record "$a" "stylus:$crate" failed "$(echo "$out" | tail -1 | cut -c1-200)"; bad=$((bad + 1))
      echo "$out" | tail -5 >&2
    fi
  done
fi

say "verified $ok, failed $bad (status in $BOOK .verify)"
[ "$bad" = 0 ]
