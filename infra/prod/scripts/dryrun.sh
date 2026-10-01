#!/usr/bin/env bash
# The stack's one end-to-end run before the deploy (Amendment 4): A's two dry-run deploys on two local anvils, then
# the whole local testnet stack against them, under its own compose project and ports. Owner: BE-backend.
#
#   dryrun.sh up     1 a git worktree of HEAD in target/testnet-dry (A's dry-run books land there, never in the
#                      shared tree); 2 two anvils (equity :18545, nav :18546; chain 31337 for A's deploy.sh);
#                    3 DRY_RUN=1 deploy.sh equity / nav; 4 each anvil switched to 46630 / 421614 (anvil_setChainId)
#                      and to 1 s blocks; 5 encrypted keystores of the anvil accounts A's dry run committed to, in the
#                      agreed roles; 6 secrets, services-config DRYRUN=1 for both chains; 7 the stack, project
#                      credence-testnet-dry, API on 127.0.0.1:18787
#   dryrun.sh down   the stack (with its volumes), the anvils and the worktree
#
# Never touches the devnode (:8547), the dev Postgres (:5433), A's books or the real stack. Dev keys only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DRY="${DRY_DIR:-$ROOT/target/testnet-dry}"
WT="$DRY/wt"
DC="${DC:?DC=docker compose … (run it through make testnet-dry-up)}"
EQ_PORT="${DRY_EQUITY_PORT:-18545}"; NAV_PORT="${DRY_NAV_PORT:-18546}"
MNEMONIC="test test test test test test test test test test test junk"
say() { echo "[$(date +%H:%M:%S)] dry-run: $*"; }

down() {
  $DC down -v --remove-orphans 2>/dev/null || true
  for s in equity nav; do
    [ -f "$DRY/anvil-$s.pid" ] && kill "$(cat "$DRY/anvil-$s.pid")" 2>/dev/null || true
    rm -f "$DRY/anvil-$s.pid"
  done
  if [ -d "$WT" ]; then git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null || true; fi
  git -C "$ROOT" worktree prune
  rm -rf "$DRY/generated" "$DRY/keys" "$DRY/secrets" "$DRY/state" "$DRY/backups"
  say "down"
}

# role → anvil mnemonic index: the accounts A's DRY_RUN env.sh puts into the committees, the fund and the solvers
# (6-8 committees, 9 issuer + reserve + solver, 1-5 Safe owners: the submitters and keepers pay gas from 1-4)
roles_equity="keeper:4 relayer-a-node-1:6 relayer-a-node-2:7 relayer-a-node-3:8 relayer-b-node-1:6 relayer-b-node-2:7
  relayer-b-node-3:8 relayer-a-submitter:1 relayer-b-submitter:2 sigma-1:6 sigma-2:7 sigma-3:8"
roles_nav="keeper:4 sigma-1:6 sigma-2:7 sigma-3:8 nav-1:6 nav-2:7 nav-3:8 nav-submitter:3 issuer:9 solver-main:9"
keys() { # chain roles
  local dir="$DRY/keys/$1" r i pk pw
  umask 077; mkdir -p "$dir"
  for ri in $2; do
    r="${ri%%:*}"; i="${ri##*:}"
    [ -f "$dir/$r.json" ] && continue
    pw="$(openssl rand -hex 16)"
    pk="$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index "$i")"
    cast wallet import "$r" --keystore-dir "$dir" --private-key "$pk" --unsafe-password "$pw" >/dev/null
    mv "$dir/$r" "$dir/$r.json"; printf '%s' "$pw" > "$dir/$r.password"
    chmod 600 "$dir/$r.json" "$dir/$r.password"
  done
  pk=""
}

up() {
  mkdir -p "$DRY"
  # 1 the worktree: A's deploy scripts and the contracts at HEAD, with the shared tree's build output and libs
  if [ ! -d "$WT" ]; then
    say "worktree of $(git -C "$ROOT" rev-parse --short HEAD) in ${WT#$ROOT/}"
    git -C "$ROOT" worktree add --detach "$WT" HEAD >/dev/null
    ln -s "$ROOT/contracts/lib" "$WT/contracts/lib"
    cp -a "$ROOT/contracts/out" "$ROOT/contracts/cache" "$WT/contracts/"
  fi
  # 2-4 the chains
  for s in equity nav; do
    port="$EQ_PORT"; cid=46630; [ "$s" = nav ] && { port="$NAV_PORT"; cid=421614; }
    rpc="http://127.0.0.1:$port"
    if [ -f "$DRY/anvil-$s.pid" ] && kill -0 "$(cat "$DRY/anvil-$s.pid")" 2>/dev/null; then
      say "$s anvil already up (chain $(cast chain-id --rpc-url "$rpc"))"; continue
    fi
    say "$s: anvil :$port, A's DRY_RUN deploy"
    anvil --host 0.0.0.0 --port "$port" --chain-id 31337 --silent > "$DRY/anvil-$s.log" 2>&1 &
    echo $! > "$DRY/anvil-$s.pid"
    until cast chain-id --rpc-url "$rpc" >/dev/null 2>&1; do sleep 0.2; done
    rm -f "$WT/deployments/31337.$s.dryrun.json"
    DRY_RUN=1 DRY_RPC="$rpc" bash "$WT/contracts/script/testnet/deploy.sh" "$s" 2>&1 | sed "s/^/  [$s] /"
    cast rpc --rpc-url "$rpc" anvil_setChainId "$cid" >/dev/null
    cast rpc --rpc-url "$rpc" evm_setIntervalMining 1 >/dev/null
    say "$s: deployed, the anvil now reports chain $(cast chain-id --rpc-url "$rpc"), 1 s blocks"
  done
  # 5 keystores, 6 secrets and the per-chain env
  keys 46630 "$roles_equity"; keys 421614 "$roles_nav"
  SECRETS_DIR="$DRY/secrets" bash "$ROOT/infra/prod/scripts/secrets-init.sh" >/dev/null
  for c in 46630 421614; do
    s=equity; port="$EQ_PORT"; [ "$c" = 421614 ] && { s=nav; port="$NAV_PORT"; }
    CHAIN="$c" DRYRUN=1 BOOK="$WT/deployments/31337.$s.dryrun.json" KEYS_DIR="$DRY/keys" GEN_DIR="$DRY/generated" \
      DRY_RPC_URL="http://host.docker.internal:$port" bash "$ROOT/infra/prod/scripts/services-config.sh"
  done
  # 7 the stack
  mkdir -p "$DRY/state/navstrike" "$DRY/backups"
  [ -f "$DRY/state/tag.current" ] || echo dry > "$DRY/state/tag.current"   # the images `make ops-check` builds
  STATE_DIR="$DRY/state" bash "$ROOT/infra/prod/scripts/deploy.sh" up
}

case "${1:-up}" in
  up) up ;;
  down) down ;;
  *) echo "usage: dryrun.sh up|down" >&2; exit 2 ;;
esac
