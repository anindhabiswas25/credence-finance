#!/usr/bin/env bash
# Public access to the local testnet API for the Vercel frontend, through a Cloudflare quick tunnel.
#
# Runs cloudflared against the local API and keeps it healthy: every CHECK_S seconds it fetches
# /v1/markets through the public tunnel URL, and after FAILS_MAX failures in a row (while the local API
# itself answers) it restarts the tunnel. A quick tunnel gets a new trycloudflare.com URL on every start, so
# the new URL is written into the prebuilt Vercel output (.vercel/output, where the /v1 rewrite is baked in)
# and redeployed with `vercel deploy --prebuilt`: no rebuild, and the local `next start` build is untouched.
#
# Needs: a prebuilt output from `CREDENCE_API_URL=<tunnel url> vercel build --prod` at the repo root, and
# VERCEL_TOKEN in $TOKEN_FILE (or the environment).
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$REPO/.vercel/output"
API="${API:-http://localhost:8787}"
PROBE="${PROBE:-/v1/markets?chain=46630}"
CHECK_S="${CHECK_S:-30}"
FAILS_MAX="${FAILS_MAX:-3}"
CLOUDFLARED="${CLOUDFLARED:-$HOME/.local/bin/cloudflared}"
VERCEL="${VERCEL:-$(command -v vercel)}"
TOKEN_FILE="${TOKEN_FILE:-$HOME/.config/credence/vercel.env}"
LOG_DIR="${LOG_DIR:-$HOME/.local/state/credence}"
mkdir -p "$LOG_DIR"
TLOG="$LOG_DIR/cloudflared.log"

# shellcheck disable=SC1090
[ -z "${VERCEL_TOKEN:-}" ] && [ -f "$TOKEN_FILE" ] && . "$TOKEN_FILE"
: "${VERCEL_TOKEN:?set VERCEL_TOKEN or write VERCEL_TOKEN=... to $TOKEN_FILE}"

say() { echo "[$(date -u +%FT%TZ)] $*"; }
ok() { [ "$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$1$PROBE")" = 200 ]; }

pid=""
stop() { [ -n "$pid" ] && kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; pid=""; }
trap 'stop; exit 0' INT TERM

start() {
  stop
  : >"$TLOG"
  "$CLOUDFLARED" tunnel --no-autoupdate --protocol http2 --url "$API" >>"$TLOG" 2>&1 &
  pid=$!
  url=""
  for _ in $(seq 1 60); do
    url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TLOG" | head -1)"
    [ -n "$url" ] && grep -q 'Registered tunnel connection' "$TLOG" && break
    sleep 2
  done
  [ -n "$url" ] || { say "cloudflared gave no URL; see $TLOG"; return 1; }
  for _ in $(seq 1 30); do ok "$url" && break; sleep 2; done
  say "tunnel up: $url"
  publish "$url"
}

# Point the deployed frontend at $1 (skip when the prebuilt output already uses it).
publish() {
  local new="$1" old
  old="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$OUT/config.json" 2>/dev/null | head -1)"
  [ -n "$old" ] || { say "no tunnel URL in $OUT/config.json: run a prebuilt vercel build first"; return 1; }
  if [ "$old" != "$new" ]; then
    grep -rlF "$old" "$OUT" | xargs sed -i "s#$old#$new#g"
  fi
  if [ "$old" != "$new" ] || ! ok "${FRONTEND:-https://credence-finance-swart.vercel.app}"; then
    say "redeploying the frontend with /v1 -> $new"
    (cd "$REPO" && "$VERCEL" deploy --prebuilt --prod --yes --token "$VERCEL_TOKEN" >>"$LOG_DIR/vercel.log" 2>&1) \
      && say "frontend redeployed" || say "vercel deploy failed; see $LOG_DIR/vercel.log"
  fi
}

start
fails=0
while sleep "$CHECK_S"; do
  if ok "$url"; then fails=0; continue; fi
  if ! ok "$API"; then say "local API at $API is down; leaving the tunnel alone"; fails=0; continue; fi
  fails=$((fails + 1))
  say "tunnel check failed ($fails/$FAILS_MAX)"
  if [ "$fails" -ge "$FAILS_MAX" ] || ! kill -0 "$pid" 2>/dev/null; then
    say "restarting the tunnel"
    start || sleep 30
    fails=0
  fi
done
