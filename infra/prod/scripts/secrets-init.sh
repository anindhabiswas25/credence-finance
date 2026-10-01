#!/usr/bin/env bash
# make ops-secrets-init: the stack's secret files, 0600 in a 0700 directory (git-ignored). Never overwrites a file
# that exists, and prints file names only.
#   rpc.env            from secrets-template/rpc.env.example: the user fills in the 2 keyed providers per chain
#   pg_password, session_secret, ops_alert_webhook (>= 32 bytes, B's webhook contract), relayer_a_token,
#   relayer_b_token (the signer nodes' bearer, OFF-02), grafana_admin: random
# Also copies .env.prod.example to .env.prod (non-secret settings) when it is missing.
set -euo pipefail
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="${SECRETS_DIR:-$P/secrets}"
umask 077
mkdir -p "$S"; chmod 700 "$S"
made() { echo "  created ${1#$P/}"; }
if [ ! -f "$S/rpc.env" ]; then cp "$P/secrets-template/rpc.env.example" "$S/rpc.env"; chmod 600 "$S/rpc.env"; made "$S/rpc.env"; fi
for name in pg_password session_secret ops_alert_webhook relayer_a_token relayer_b_token grafana_admin; do
  f="$S/$name"
  [ -f "$f" ] && continue
  openssl rand -hex 32 | tr -d '\n' > "$f"; chmod 600 "$f"; made "$f"
done
for f in "$S"/*; do
  m="$(stat -c %a "$f")"; [ "$m" = 600 ] || { echo "ops-secrets-init: $f is $m, must be 0600" >&2; exit 1; }
done
if [ -z "${SECRETS_DIR:-}" ] && [ ! -f "$P/.env.prod" ]; then cp "$P/.env.prod.example" "$P/.env.prod"; echo "  created infra/prod/.env.prod (set OPS_ADMIN_ADDRESSES there)"; fi
echo "ops-secrets-init: secrets in ${S#$P/} (0600). Next: fill in secrets/rpc.env (4 lines), then make ops-rpc-check."
