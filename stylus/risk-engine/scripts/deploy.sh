#!/usr/bin/env bash
# Deploy the Risk Engine on a LOCAL devnode (R-24 split, ADR-0108):
#   1. RiskEngineRouter (Solidity, IRiskEngine): timelock = deployer, σ writer = SIGMA_ORACLE (default: deployer)
#   2. PricingEngine (stylus/risk-engine) and AuctionMath (stylus/auction-math), deployed + activated through the
#      StylusDeployer, each constructed with the router as its only writer
#   3. router.initializeWiring(pricing, auction)
# Records THE local address book deployments/<chainId>.local.json (charter §2a, ADR-0105): .shared.riskEngine = the
# router; .stylus.riskEngine / .stylus.auctionMath = the programs (address, tx, compressed size, toolchain, wasm
# sha256). Refuses Arbitrum Sepolia / One.
#   DEVNODE_RPC      default http://127.0.0.1:8547
#   DEVNODE_KEY      deployer key (default: the public nitro-devnode dev key); the router's timelock locally
#   SIGMA_ORACLE     the router's σ writer (default: the deployer; DeployCoreLocal re-points it to its SigmaOracle)
#   ENGINE_BOOK      address book to write (default the chain's book; `make stylus-diff` uses a separate one)
#   STYLUS_DEPLOYER  default 0xcEcba2F1DC234f70Dd89F2041029807F8D03A990 (bootstrapped by infra/devnode/init.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RPC="${DEVNODE_RPC:-http://127.0.0.1:8547}"
KEY="${DEVNODE_KEY:-0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659}"
DEPLOYER="${STYLUS_DEPLOYER:-0xcEcba2F1DC234f70Dd89F2041029807F8D03A990}"
CHAIN_ID="$(cast chain-id --rpc-url "$RPC")"
case "$CHAIN_ID" in 421614|42161) echo "refusing to run against chain $CHAIN_ID (local only)" >&2; exit 1 ;; esac
ME="$(cast wallet address --private-key "$KEY")"
SIGMA_ORACLE="${SIGMA_ORACLE:-$ME}"

# 1. the router
ROUTER="$(cd "$ROOT/contracts" && forge create src/risk/RiskEngineRouter.sol:RiskEngineRouter --rpc-url "$RPC" \
  --private-key "$KEY" --broadcast --constructor-args "$ME" "$SIGMA_ORACLE" 2>&1 \
  | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}')"
[ -n "$ROUTER" ] || { echo "router deploy failed" >&2; exit 1; }

# 2. the two Stylus programs
WS="$("$ROOT/stylus/risk-engine/scripts/stylus-ws.sh")"
TC="$(grep channel "$WS/rust-toolchain.toml" | cut -d'"' -f2)"
deploy_program() { # contract constructor-args… → "address tx size sha"
  local c="$1"; shift
  local log; log="$(mktemp)"
  (cd "$WS" && cargo stylus deploy --no-verify --contract "$c" --endpoint "$RPC" --private-key "$KEY" \
    --deployer-address "$DEPLOYER" --constructor-args "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$log") || { cat "$log" >&2; exit 1; }
  local addr tx size wasm sha
  addr="$(grep -oE 'deployed code at address: 0x[0-9a-fA-F]{40}' "$log" | grep -oE '0x[0-9a-fA-F]{40}')"
  tx="$(grep -oE 'deployment tx hash: 0x[0-9a-fA-F]{64}' "$log" | grep -oE '0x[0-9a-fA-F]{64}')"
  size="$(grep -oE 'contract size: [0-9.]+ KB \([0-9]+ bytes\)' "$log" | tail -1 | grep -oE '\([0-9]+' | tr -d '(')"
  [ -n "$addr" ] || { cat "$log" >&2; echo "deploy of $c failed" >&2; exit 1; }
  rm -f "$log"
  wasm="$WS/target/wasm32-unknown-unknown/release/deps/$(echo "$c" | tr - _).wasm"
  sha="$( [ -f "$wasm" ] && sha256sum "$wasm" | cut -d' ' -f1 || echo unknown)"
  echo "$addr $tx $size $sha"
}
read -r PRICING P_TX P_SIZE P_SHA < <(deploy_program credence-risk-engine "$ROUTER" "$ROUTER")
read -r AUCTION A_TX A_SIZE A_SHA < <(deploy_program credence-auction-math "$ROUTER")

# 3. wire
cast send --rpc-url "$RPC" --private-key "$KEY" "$ROUTER" "initializeWiring(address,address)" "$PRICING" "$AUCTION" >/dev/null
lc() { tr '[:upper:]' '[:lower:]'; }
[ "$(cast call --rpc-url "$RPC" "$ROUTER" 'pricing()(address)' | lc)" = "$(echo "$PRICING" | lc)" ] \
  || { echo "wiring failed: router $ROUTER, pricing $PRICING" >&2; exit 1; }

BOOK="${ENGINE_BOOK:-$ROOT/deployments/$CHAIN_ID.local.json}"
mkdir -p "$ROOT/deployments"
[ -f "$BOOK" ] || printf '{ "chainId": %s, "startBlock": 0, "release": "local", "shared": {} }\n' "$CHAIN_ID" > "$BOOK"
TMP="$(mktemp)"
jq --arg r "$ROUTER" --arg tc "$TC" \
   --arg pa "$PRICING" --arg ptx "$P_TX" --argjson ps "$P_SIZE" --arg psha "$P_SHA" \
   --arg aa "$AUCTION" --arg atx "$A_TX" --argjson as "$A_SIZE" --arg asha "$A_SHA" \
   '# lift a flat S1 book into the §13.2 shape first, so `shared` is never partial (the SDK validates it)
    .shared = (({calendar: .calendar, clock: .clock, oracle: .oracle, feedA: .feedA, feedB: .feedB,
                 feedNav: .navFeed, sequencerHealth: .sequencerHealth, registry: .registry, faucet: .faucet}
                | with_entries(select(.value != null))) + (.shared // {}))
    | .tokens = ((to_entries | map(select((.key | test("^t[A-Z]+$")) or .key == "usdc")) | from_entries)
                 + (.tokens // {}))
    | .assetIds = ((to_entries | map(select(.key | startswith("assetId_")) | .key |= ltrimstr("assetId_"))
                   | from_entries) + (.assetIds // {}))
    | .shared.riskEngine = $r
    | .stylus.riskEngine = {address: $pa, router: $r, deploymentTx: $ptx, compressedSizeBytes: $ps, toolchain: $tc,
                            wasmSha256: $psha}
    | .stylus.auctionMath = {address: $aa, deploymentTx: $atx, compressedSizeBytes: $as, toolchain: $tc,
                             wasmSha256: $asha}' "$BOOK" > "$TMP" && mv "$TMP" "$BOOK"
[ -z "${ENGINE_BOOK:-}" ] && rm -f "$ROOT/deployments/devnode.engine.json"   # retired (charter §2a): one address book per chain
echo "risk engine router $ROUTER → PricingEngine $PRICING ($P_SIZE B) + AuctionMath $AUCTION ($A_SIZE B) → $BOOK"
