#!/bin/sh
# Credence service entrypoint (infra/prod, owner: DevOps). Config is env only (Railway-ready): on Railway every
# variable is set directly and this script changes nothing. On this machine the secrets live in 0600 files, mounted
# read-only, and are turned into env here, inside the container, so they never appear in compose or `docker inspect`:
#
#   FILE__<NAME>=<path>      export <NAME>="$(cat <path>)" (one trailing newline dropped)
#   RPC_ENV_FILE=<path>      a KEY=VALUE file with RPC_<chainId>_PRIMARY / _SECONDARY (the user's keyed URLs)
#   RPC_CHAINS="<id> [<id>]" the chains this service talks to; with RPC_<id>_PUBLIC (keyless, from compose) builds
#                            RPC_URL_<id>          the whole ordered list (the API and the notifier fail over through it)
#                            PONDER_RPC_URL_<id>   the same list (the indexer), or only the tiers in PONDER_RPC_TIERS
#                                                  (e.g. "PRIMARY PUBLIC": Chainstack free refuses non-recent eth_getLogs)
#                            and, when exactly one chain is listed:
#                            RPC_URL               the first URL, RPC_URL_FALLBACK the rest (keeper, relayer, solver)
#   DATABASE_URL unset and PGHOST set: DATABASE_URL=postgres://PGUSER:PGPASSWORD@PGHOST:PGPORT/PGDATABASE
#
# Nothing here prints a value.
set -eu

for name in $(env | sed -n 's/^\(FILE__[A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'); do
  eval "path=\${$name}"
  [ -r "$path" ] || { echo "entrypoint: $name points to an unreadable file" >&2; exit 64; }
  target="${name#FILE__}"
  value="$(cat "$path")"
  export "$target=$value"
  unset "$name"
done

if [ -n "${RPC_ENV_FILE:-}" ]; then
  [ -r "$RPC_ENV_FILE" ] || { echo "entrypoint: RPC_ENV_FILE is unreadable" >&2; exit 64; }
  set -a
  # shellcheck disable=SC1090
  . "$RPC_ENV_FILE"
  set +a
fi

if [ -n "${RPC_CHAINS:-}" ]; then
  n=0
  for id in $(echo "$RPC_CHAINS" | tr ',' ' '); do n=$((n + 1)); done
  for id in $(echo "$RPC_CHAINS" | tr ',' ' '); do
    list=""
    for tier in PRIMARY SECONDARY PUBLIC; do
      eval "u=\${RPC_${id}_${tier}:-}"
      [ -n "$u" ] && list="${list:+$list,}$u"
    done
    [ -n "$list" ] || { echo "entrypoint: no RPC for chain $id (RPC_${id}_PRIMARY/_SECONDARY/_PUBLIC)" >&2; exit 64; }
    first="${list%%,*}"
    rest=""
    case "$list" in *,*) rest="${list#*,}" ;; esac
    plist=""
    for tier in ${PONDER_RPC_TIERS:-PRIMARY SECONDARY PUBLIC}; do
      eval "u=\${RPC_${id}_${tier}:-}"
      [ -n "$u" ] && plist="${plist:+$plist,}$u"
    done
    [ -n "$plist" ] || plist="$list"
    export "RPC_URL_${id}=$list" "PONDER_RPC_URL_${id}=$plist"
    if [ "$n" = 1 ]; then
      export "RPC_URL=$first" "RPC_URL_FALLBACK=$rest"
    fi
    echo "entrypoint: chain $id has $(echo "$list" | tr ',' '\n' | wc -l) RPC(s)" >&2
  done
fi

if [ -z "${DATABASE_URL:-}" ] && [ -n "${PGHOST:-}" ]; then
  export DATABASE_URL="postgres://${PGUSER:-credence}:${PGPASSWORD:-}@${PGHOST}:${PGPORT:-5432}/${PGDATABASE:-credence}"
fi

exec "$@"
