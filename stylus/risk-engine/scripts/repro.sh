#!/usr/bin/env bash
# Byte-reproducibility of the Stylus artifacts (R-24): build both programs from two fresh clones of HEAD at different
# paths and require identical WASM sha256. Prints the hashes; exit 1 on any difference. Needs the pinned nightly.
#   REPRO_DIR   scratch directory (default: a mktemp dir, removed afterwards)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BASE="${REPRO_DIR:-$(mktemp -d)}"
trap '[ -z "${REPRO_DIR:-}" ] && rm -rf "$BASE"' EXIT
build() { # dir → "contract sha256" lines
  local dir="$1"
  git clone --quiet --no-hardlinks "$ROOT" "$dir"
  local ws
  ws="$(bash "$dir/stylus/risk-engine/scripts/stylus-ws.sh")"
  (cd "$ws" && for c in credence-risk-engine credence-auction-math; do
     cargo stylus build --contract "$c" >/dev/null 2>&1 || { echo "build of $c failed in $dir" >&2; exit 1; }
     f="$(echo "$c" | tr - _)"
     echo "$c $(sha256sum "target/wasm32-unknown-unknown/release/deps/$f.wasm" | cut -d' ' -f1)"
   done)
}
A="$(build "$BASE/a/credence")"
B="$(build "$BASE/elsewhere/b/credence")"
echo "$A"
if [ "$A" != "$B" ]; then echo "NOT reproducible:" >&2; echo "$B" >&2; exit 1; fi
echo "reproducible: identical WASM from two checkouts"
