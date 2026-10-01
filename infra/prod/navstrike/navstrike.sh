#!/bin/sh
# The NAV strike timer on 421614 (PM 16:30 ruling 3; testnet only): once per USBANK session, NAVSTRIKE_OFFSET_S
# (default 30 min) after the session opens, `credence-relayer nav-strike --publish` signs the NAV report with the NAV
# committee (nav-1..N, threshold 2), submits it to feedNav and publishes it on the fund as the issuer EOA.
# A session whose strike is done leaves a marker in $NAVSTRIKE_STATE, so a restart never strikes twice; a failed strike
# is retried every NAVSTRIKE_RETRY_S. A session missed while the machine was off is struck when it comes back, if that
# session is still the latest one. The keeper's credence_keeper_nav_print_overdue_seconds pages when no print lands.
set -u
STATE="${NAVSTRIKE_STATE:-/state}"
OFFSET="${NAVSTRIKE_OFFSET_S:-1800}"
RETRY="${NAVSTRIKE_RETRY_S:-300}"
CAL="${NAVSTRIKE_CALENDAR:-$(ls /app/calibration/out/calendars/USBANK-*.json | sort | tail -1)}"
mkdir -p "$STATE"
log() { echo "navstrike $(date -u +%FT%TZ) $*"; }
log "calendar $(basename "$CAL"), strike at open + ${OFFSET}s"
while :; do
  touch "$STATE/alive"
  now="$(date +%s)"
  # the latest session whose strike time has passed
  open="$(jq -r --argjson n "$now" --argjson o "$OFFSET" '[.sessions[] | select(.open + $o <= $n)] | last | .open // empty' "$CAL")"
  if [ -z "$open" ]; then
    log "no USBANK session in $(basename "$CAL") has started: nothing to strike"
  elif [ ! -f "$STATE/session-$open.done" ]; then
    log "session opening $(date -u -d "@$open" +%FT%TZ): striking"
    if credence-relayer nav-strike --publish; then
      touch "$STATE/session-$open.done"
      log "session $open struck"
      # keep the markers of the last 30 sessions
      ls -1 "$STATE"/session-*.done 2>/dev/null | sort | head -n -30 | xargs -r rm -f
    else
      log "strike failed: retry in ${RETRY}s"
      sleep "$RETRY"
      continue
    fi
  fi
  sleep 60
done
