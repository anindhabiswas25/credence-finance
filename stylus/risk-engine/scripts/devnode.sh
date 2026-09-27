#!/usr/bin/env bash
# Local nitro-devnode (Stylus-capable) on :8547.
# BE-backend's `make infra-up` (infra/docker-compose.yml) is the canonical way to run it, with the bootstrap that
# deploys the StylusDeployer. This script only reports whether a devnode is answering; if none is and compose is
# available it delegates to `make infra-up`.
set -euo pipefail
RPC="${DEVNODE_RPC:-http://127.0.0.1:8547}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
case "${1:-up}" in
  up)
    if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
      echo "devnode up at $RPC (chain $(cast chain-id --rpc-url "$RPC"))"
    elif [ -f "$ROOT/infra/docker-compose.yml" ]; then
      make -C "$ROOT" infra-up
    else
      echo "no devnode at $RPC and no infra/docker-compose.yml" >&2; exit 1
    fi ;;
  down)
    if [ -f "$ROOT/infra/docker-compose.yml" ]; then make -C "$ROOT" infra-down; fi ;;
  *) echo "usage: devnode.sh up|down" >&2; exit 2 ;;
esac
