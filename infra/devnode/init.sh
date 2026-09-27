#!/bin/sh
# Bootstraps a fresh nitro-devnode exactly like OffchainLabs/nitro-devnode run-dev-node.sh
# (pinned at ebb523d, Oct 2025): chain owner, zero L1 price, CREATE2 factory, Stylus cache manager,
# StylusDeployer. Idempotent: a second run on an already-bootstrapped node is a no-op.
set -eu

RPC="${DEVNODE_RPC:-http://devnode:8547}"
# Well-known nitro --dev prefunded key (public; local chain only).
PK="${DEVNODE_PRIVATE_KEY:-0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659}"
CREATE2_FACTORY=0x4e59b44847b379578588920ca78fbf26c0b4956c
STYLUS_DEPLOYER=0xcEcba2F1DC234f70Dd89F2041029807F8D03A990
SALT=0x0000000000000000000000000000000000000000000000000000000000000000
DIR="$(dirname "$0")"

echo "devnode-init: waiting for $RPC"
i=0
until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 300 ] && { echo "devnode did not come up"; exit 1; }
  sleep 1
done

if [ "$(cast code --rpc-url "$RPC" "$STYLUS_DEPLOYER")" != "0x" ]; then
  echo "devnode-init: already bootstrapped"; exit 0
fi

echo "devnode-init: becomeChainOwner"
cast send --rpc-url "$RPC" --private-key "$PK" 0x00000000000000000000000000000000000000FF "becomeChainOwner()" >/dev/null
echo "devnode-init: L1 price per unit = 0"
cast send --rpc-url "$RPC" --private-key "$PK" 0x0000000000000000000000000000000000000070 'setL1PricePerUnit(uint256)' 0x0 >/dev/null

if [ "$(cast code --rpc-url "$RPC" "$CREATE2_FACTORY")" = "0x" ]; then
  echo "devnode-init: CREATE2 factory"
  cast send --rpc-url "$RPC" --private-key "$PK" --value "1 ether" 0x3fab184622dc19b6109349b94811493bf2a45362 >/dev/null
  cast publish --rpc-url "$RPC" 0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222 >/dev/null
  [ "$(cast code --rpc-url "$RPC" "$CREATE2_FACTORY")" != "0x" ] || { echo "CREATE2 factory failed"; exit 1; }
fi

echo "devnode-init: Stylus cache manager"
out=$(cast send --rpc-url "$RPC" --private-key "$PK" --create 0x60a06040523060805234801561001457600080fd5b50608051611d1c61003060003960006105260152611d1c6000f3fe)
cm=$(echo "$out" | awk '/contractAddress/ {print $2}')
[ -n "$cm" ] || { echo "cache manager deploy failed: $out"; exit 1; }
cast send --rpc-url "$RPC" --private-key "$PK" 0x0000000000000000000000000000000000000070 "addWasmCacheManager(address)" "$cm" >/dev/null

echo "devnode-init: StylusDeployer"
cast send --rpc-url "$RPC" --private-key "$PK" "$CREATE2_FACTORY" "$SALT$(cat "$DIR/stylus-deployer-bytecode.txt")" >/dev/null
[ "$(cast code --rpc-url "$RPC" "$STYLUS_DEPLOYER")" != "0x" ] || { echo "StylusDeployer failed"; exit 1; }
echo "devnode-init: done (cache manager $cm, StylusDeployer $STYLUS_DEPLOYER)"
