#!/usr/bin/env bash
# Called by deploy.sh after FinalizeTestnet (ADR-0122): adds to the stack's address book what the indexers and the
# verifier need, read from the DeployTestnet broadcast (contracts/broadcast/DeployTestnet.s.sol/<chainId>/run-latest.json):
#   .deployBlocks  {"shared.timelock": <block>, "equity.market": <block>, …}: the block that created each contract in
#                  the book (the indexers' start blocks). The Stylus programs get the block read just before their
#                  deploy (STYLUS_FROM_BLOCK, a lower bound: safe for a start block). Contracts the deploy did not
#                  create (the official RHTSLA, Circle's USDC) are left out.
#   .libraries     {"BorrowLogic": "0x…", …}: the linked libraries (forge verify-contract --libraries)
#   .abiTag        the frozen ABI set the book was deployed with (ABI_TAG, default v5-testnet)
#   .creations     [{name, source, address, kind, block, sizeProfile, constructorArgs}] for every contract the
#                  broadcast created: testnet-verify works from the book alone (broadcast/ is git-ignored)
#   usage: book_meta.sh <book> <chainId>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BOOK="${1:?book}"; CHAIN="${2:?chainId}"
BC="$ROOT/contracts/${FOUNDRY_BROADCAST:-broadcast}/DeployTestnet.s.sol/$CHAIN/run-latest.json"
[ -f "$BC" ] || { echo "no broadcast $BC" >&2; exit 1; }
TMP="$(mktemp)"
jq --slurpfile bc "$BC" --arg stylus "${STYLUS_FROM_BLOCK:-}" --arg tag "${ABI_TAG:-v5-testnet}" '
  def h: ltrimstr("0x") | ascii_downcase | explode
    | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end));
  ($bc[0].receipts | map({key: .transactionHash, value: (.blockNumber | h)}) | from_entries) as $blk
  | ([$bc[0].transactions[]
      | .hash as $t
      | ((select(.transactionType == "CREATE" or .transactionType == "CREATE2")
          | {key: (.contractAddress | ascii_downcase), value: $blk[$t]}),
         (.additionalContracts[]? | {key: (.address | ascii_downcase), value: $blk[$t]}))]
     | from_entries) as $made
  | . as $book
  | .deployBlocks = (
      [paths(type == "string" and test("^0x[0-9a-fA-F]{40}$")) as $p
        | select($p[0] | IN("safes", "shared", "equity", "nav", "tokens"))
        | ($book | getpath($p) | ascii_downcase) as $a
        | select($made[$a] != null)
        | {key: ($p | map(tostring) | join(".")), value: $made[$a]}]
      + (if $stylus == "" or ($book.stylus // null) == null then []
         else [{key: "stylus.pricing", value: ($stylus | tonumber)}, {key: "stylus.auctionMath", value: ($stylus | tonumber)}]
         end)
      | from_entries)
  # the chain'"'"'s own first deploy block. DeployTestnet'"'"'s `block.number` is the parent chain'"'"'s block on Arbitrum chains
  # (L1 Sepolia on 421614 and 46630), so the indexers backfilled from ~11.8M (2026-10-02); the receipts are L2 blocks
  | .startBlock = ([$blk[]] | min)
  | .libraries = ([$bc[0].transactions[] | select(.transactionType == "CREATE2" and .contractName != null)
      | {key: (.contractName | rtrimstr(".size")), value: .contractAddress}] | from_entries)
  | .abiTag = $tag
' "$BOOK" > "$TMP"
mv "$TMP" "$BOOK"
# constructor arguments: the creation input past the linked bytecode (CREATE2: past the 32-byte salt first)
CR="$(mktemp)"
while IFS=$'\t' read -r name addr kind hash input; do
  # forge names a size-profile build (optimizer_runs 200, ADR-0107) "<Name>.size"; the script picks it for every
  # contract its compilation unit shares with the market, so most of the stack is deployed from that profile
  base="${name%.size}"; art="$ROOT/contracts/out/$base.sol/$name.json"
  [ -f "$art" ] || { echo "no artifact $art" >&2; exit 1; }
  code="$(jq -r '.bytecode.object' "$art" | sed 's/^0x//')"
  body="${input#0x}"; [ "$kind" = CREATE2 ] && body="${body:64}"
  [ "${#body}" -ge "${#code}" ] || { echo "creation input of $name is shorter than its bytecode" >&2; exit 1; }
  jq -n --arg n "$base" --arg a "$addr" --arg k "$kind" --arg h "$hash" --arg args "${body:${#code}}" \
    --arg src "$(jq -r '.metadata.settings.compilationTarget | keys[0]' "$art")" \
    --argjson runs "$(jq '.metadata.settings.optimizer.runs' "$art")" \
    '{name: $n, source: $src, address: $a, kind: $k, tx: $h, sizeProfile: ($runs == 200),
      constructorArgs: (if $args == "" then "" else "0x" + $args end)}' >> "$CR"
done < <(jq -r '.transactions[] | select(.contractName != null and (.transactionType == "CREATE" or .transactionType == "CREATE2"))
  | [.contractName, .contractAddress, .transactionType, .hash, .transaction.input] | @tsv' "$BC")
TMP="$(mktemp)"
jq --slurpfile c "$CR" --slurpfile bc "$BC" '
  def h: ltrimstr("0x") | ascii_downcase | explode
    | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end));
  ($bc[0].receipts | map({key: .transactionHash, value: (.blockNumber | h)}) | from_entries) as $blk
  | .creations = ($c | map(. + {block: $blk[.tx]}))' "$BOOK" > "$TMP" && mv "$TMP" "$BOOK"
rm -f "$CR"
echo "book: $(jq '.creations | length' "$BOOK") creations, $(jq '.deployBlocks | length' "$BOOK") deploy blocks, $(jq '.libraries | length' "$BOOK") libraries, ABI tag $(jq -r .abiTag "$BOOK")"
