#!/usr/bin/env bash
# make testnet-fork-rehearsal STACK=equity|nav (S5 item 3, ADR-0122): the deploy pre-flight, run once per stack right
# before the real deploy. ≤ 30 min. It runs the whole deploy.sh (DeployTestnet, the programs, the risk bundles through
# the timelock, FinalizeTestnet, book_meta, the post-deploy check) against `anvil --fork-url` of the stack's real chain,
# with the configs exactly as they will be deployed (fill them first: owners, `make testnet-keys`). What it proves that
# the plain-anvil dry run cannot: the real chain id, the real canonical Safe v1.4.1 factory / singleton / handler, the
# real official Robinhood test TSLA (RHTSLA, 0xC9f9…Bd4E, and its transfer rules) on 46630, and Circle's test USDC on
# 421614; and that the configs, the calendars and the bundles go through on that state.
# What it does NOT prove: anvil cannot run Stylus WASM, so the two risk-engine programs are the Solidity stand-ins
# (DryRunPrograms.sol) here, exactly as in the dry run. The real Stylus path is proven by live-check.sh on 46630
# (2026-09-30, 11/11 exact) and by the real deploy itself on 421614 (step 2 of deploy.sh).
# The deployer is a throwaway keystore of anvil's account 0 (funded by the fork), so the real keystore path of deploy.sh
# (--keystore + --password-file) runs; nothing is sent to the real chain. Its book is deployments/<chainId>.fork.json
# and its broadcasts go to contracts/broadcast-fork/ (both git-ignored), so the real book and broadcast stay untouched.
#   FORK_URL (default: the config's rpc) FORK_PORT (default 8561) FORK_FILL=1 (fill empty inputs with anvil accounts,
#   only to try the tool before the inputs exist; the pre-flight itself runs without it)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STACK="${1:?usage: fork_rehearsal.sh equity|nav}"
PORT="${FORK_PORT:-8561}"
export FORK=1 FORK_RPC="http://127.0.0.1:$PORT" FOUNDRY_BROADCAST=broadcast-fork
# shellcheck source=env.sh
source "$ROOT/contracts/script/testnet/env.sh"
UPSTREAM="${FORK_URL:-$(cfg .rpc)}"
say() { echo "[$(date +%H:%M:%S)] $*"; }

if cast chain-id --rpc-url "$FORK_RPC" >/dev/null 2>&1; then
  echo "something already answers on $FORK_RPC: stop it or set FORK_PORT" >&2; exit 1
fi
T="$(mktemp -d)"
anvil --fork-url "$UPSTREAM" --port "$PORT" --silent --no-rate-limit & ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true; rm -rf "$T"' EXIT
for _ in $(seq 1 300); do cast chain-id --rpc-url "$FORK_RPC" >/dev/null 2>&1 && break; sleep 0.2; done
[ "$(cast chain-id --rpc-url "$FORK_RPC")" = "$CID" ] || { echo "the fork is not chain $CID" >&2; exit 1; }
say "fork of $CID at block $(cast block-number --rpc-url "$FORK_RPC") on $FORK_RPC"

# a throwaway deployer keystore: anvil's account 0 (a public test key), funded on the fork
(umask 077 && openssl rand -base64 24 | tr -d '\r\n' > "$T/pw")
CAST_UNSAFE_PASSWORD="$(cat "$T/pw")" cast wallet import --keystore-dir "$T" deployer \
  --private-key "$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index 0)" >/dev/null
rm -f "$BOOK"
rm -rf "$ROOT/contracts/broadcast-fork"
start=$(date +%s)
DEPLOYER_KEYSTORE="$T/deployer" DEPLOYER_PASSWORD_FILE="$T/pw" bash "$ROOT/contracts/script/testnet/deploy.sh" "$STACK"
say "FORK REHEARSAL PASSED ($STACK on a fork of $CID, $(( ($(date +%s) - start) / 60 )) min); book $BOOK"
