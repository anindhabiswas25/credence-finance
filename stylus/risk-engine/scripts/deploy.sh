#!/usr/bin/env bash
# Deploy + activate the Stylus Risk Engine on a LOCAL devnode, with its constructor, through the StylusDeployer.
# Writes deployments/devnode.engine.json (git-ignored). Refuses Arbitrum Sepolia / One.
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
mkdir -p "$ROOT/deployments"
cat > "$ROOT/deployments/devnode.engine.json" <<JSON
{
  "chainId": $CHAIN_ID,
  "address": "$ADDR",
  "deploymentTx": "$TX",
  "compressedSizeBytes": $SIZE,
  "timelock": "$ME",
  "sigmaOracle": "$ME",
  "toolchain": "$(grep channel "$WS/rust-toolchain.toml" | cut -d'"' -f2)"
}
JSON
echo "engine at $ADDR ($SIZE bytes compressed) → deployments/devnode.engine.json"
