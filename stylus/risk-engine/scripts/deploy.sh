#!/usr/bin/env bash
# Deploy + activate the Stylus Risk Engine on a LOCAL devnode, with its constructor, through the StylusDeployer.
# Records the engine in THE local address book deployments/<chainId>.local.json (charter §2a, ADR-0105):
#   .shared.riskEngine (address) and .stylus.riskEngine (tx, size, toolchain, wasm sha256). Refuses Arbitrum Sepolia / One.
#   DEVNODE_RPC   default http://127.0.0.1:8547
#   DEVNODE_KEY   deployer key (default: the public nitro-devnode dev key); also timelock + sigma oracle locally
#   STYLUS_DEPLOYER  default 0xcEcba2F1DC234f70Dd89F2041029807F8D03A990 (bootstrapped by infra/devnode/init.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RPC="${DEVNODE_RPC:-http://127.0.0.1:8547}"
KEY="${DEVNODE_KEY:-0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659}"
DEPLOYER="${STYLUS_DEPLOYER:-0xcEcba2F1DC234f70Dd89F2041029807F8D03A990}"
CHAIN_ID="$(cast chain-id --rpc-url "$RPC")"
case "$CHAIN_ID" in 421614|42161) echo "refusing to run against chain $CHAIN_ID (local only)" >&2; exit 1 ;; esac
ME="$(cast wallet address --private-key "$KEY")"
WS="$("$ROOT/stylus/risk-engine/scripts/stylus-ws.sh")"
cd "$WS"
LOG="$(mktemp)"
cargo stylus deploy --no-verify --contract credence-risk-engine --endpoint "$RPC" --private-key "$KEY" \
  --deployer-address "$DEPLOYER" --constructor-args "$ME" "$ME" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tee "$LOG"
ADDR="$(grep -oE 'deployed code at address: 0x[0-9a-fA-F]{40}' "$LOG" | grep -oE '0x[0-9a-fA-F]{40}')"
TX="$(grep -oE 'deployment tx hash: 0x[0-9a-fA-F]{64}' "$LOG" | grep -oE '0x[0-9a-fA-F]{64}')"
SIZE="$(grep -oE 'contract size: [0-9.]+ KB \([0-9]+ bytes\)' "$LOG" | tail -1 | grep -oE '\([0-9]+' | tr -d '(')"
rm -f "$LOG"
[ -n "$ADDR" ] || { echo "deploy failed" >&2; exit 1; }
[ "$(cast call --rpc-url "$RPC" "$ADDR" 'timelock()(address)')" = "$ME" ] || { echo "constructor did not run" >&2; exit 1; }
WASM="$WS/target/wasm32-unknown-unknown/release/credence_risk_engine.wasm"
WASM_SHA="$( [ -f "$WASM" ] && sha256sum "$WASM" | cut -d' ' -f1 || echo unknown)"
BOOK="$ROOT/deployments/$CHAIN_ID.local.json"
mkdir -p "$ROOT/deployments"
[ -f "$BOOK" ] || printf '{ "chainId": %s, "startBlock": 0, "release": "local", "shared": {} }\n' "$CHAIN_ID" > "$BOOK"
TMP="$(mktemp)"
jq --arg a "$ADDR" --arg tx "$TX" --argjson size "$SIZE" --arg tc "$(grep channel "$WS/rust-toolchain.toml" | cut -d'"' -f2)" \
   --arg sha "$WASM_SHA" \
   '# lift a flat S1 book into the §13.2 shape first, so `shared` is never partial (the SDK validates it)
    .shared = (({calendar: .calendar, clock: .clock, oracle: .oracle, feedA: .feedA, feedB: .feedB,
                 feedNav: .navFeed, sequencerHealth: .sequencerHealth, registry: .registry, faucet: .faucet}
                | with_entries(select(.value != null))) + (.shared // {}))
    | .tokens = ((to_entries | map(select((.key | test("^t[A-Z]+$")) or .key == "usdc")) | from_entries)
                 + (.tokens // {}))
    | .assetIds = ((to_entries | map(select(.key | startswith("assetId_")) | .key |= ltrimstr("assetId_"))
                   | from_entries) + (.assetIds // {}))
    | .shared.riskEngine = $a
    | .stylus.riskEngine = {address: $a, deploymentTx: $tx, compressedSizeBytes: $size, toolchain: $tc,
                            wasmSha256: $sha}' "$BOOK" > "$TMP" && mv "$TMP" "$BOOK"
rm -f "$ROOT/deployments/devnode.engine.json"   # retired (charter §2a): one address book per chain
echo "engine at $ADDR ($SIZE bytes compressed, wasm sha256 $WASM_SHA) → $BOOK .shared.riskEngine"
