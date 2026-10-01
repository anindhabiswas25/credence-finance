#!/usr/bin/env bash
# make testnet-services-check: the local testnet stack's steady state after a deploy (or the dry run's). Exits
# non-zero on any failure. Read-only: it changes nothing, and prints no secret or RPC URL.
#   1 every service is up (healthy where it has a health check; the migration exited 0)
#   2 the indexers of both chains are caught up (Ponder /ready)
#   3 feed A and feed B publish on 46630 (a report in the last 10 min), unless XNYS is outside its extended hours
#   4 each chain's keeper is the leader, healthy and idle: no reverted tx and no page firing
#   5 the API answers for both chains (/readyz, /v1/markets?chain=…)
#   6 the first NAV print landed on 421614 (indexed on feedNav), or TBILL is HALTED with its reason until it does
#   7 Alertmanager reaches the API's ops inbox (no failed webhook notification)
# DC is the compose command (mk/ops.mk sets it, with the project name and env); API_PORT, PROMETHEUS_PORT,
# ALERTMANAGER_PORT the host ports.
set -uo pipefail
DC="${DC:?DC=docker compose … (run it through make testnet-services-check)}"
API="http://127.0.0.1:${API_PORT:-8787}"
PROM="http://127.0.0.1:${PROMETHEUS_PORT:-19090}"
AM="http://127.0.0.1:${ALERTMANAGER_PORT:-19093}"
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHAINS="${CHAINS:-46630 421614}"
fail=0
ok() { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fail=1; }
note() { printf '  --    %s\n' "$*"; }
psql_() { $DC exec -T postgres psql -U credence -d credence -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
prom() { curl -sf --max-time 10 "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r "$2" 2>/dev/null; }

echo "1. services"
ps="$($DC ps -a --format json 2>/dev/null | jq -s 'if type == "array" and (.[0] | type) == "array" then .[0] else . end')"
[ -n "$ps" ] && [ "$ps" != "[]" ] || { bad "the stack is not running (make testnet-up)"; exit 1; }
while IFS='|' read -r svc state health code; do
  case "$svc" in
    migrate) [ "$state" = exited ] && [ "$code" = 0 ] && ok "migrate exited 0" || bad "migrate: $state (exit $code)" ;;
    *) if [ "$state" != running ]; then bad "$svc: $state"
       elif [ -n "$health" ] && [ "$health" != healthy ]; then bad "$svc: $health"
       else ok "$svc ${health:-running}"; fi ;;
  esac
done < <(echo "$ps" | jq -r '.[] | [.Service, .State, (.Health // ""), (.ExitCode // 0 | tostring)] | join("|")' | sort)

echo "2. indexers caught up"
for c in $CHAINS; do
  if $DC exec -T "indexer-$c" curl -sf --max-time 5 http://127.0.0.1:42069/ready >/dev/null 2>&1; then
    ok "indexer-$c ready (historical sync done, following the head)"
  else bad "indexer-$c not ready (still syncing, or down)"; fi
done

echo "3. feeds on 46630"
if [[ " $CHAINS " == *" 46630 "* ]]; then
  cal="$(ls "$P"/../../calibration/out/calendars/XNYS-*.json 2>/dev/null | sort | tail -1)"
  now="$(date +%s)"
  open="$(jq --argjson n "$now" '[.sessions[] | select(.extOpen <= $n and $n < .extClose)] | length' "$cal" 2>/dev/null || echo 1)"
  for f in A B; do
    n="$(psql_ "select count(*) from ix_46630.price_point where feed = '$f' and observed_at > extract(epoch from now())::bigint - 600")"
    if [ "${n:-0}" -gt 0 ]; then ok "feed $f: $n report(s) in the last 10 min"
    elif [ "$open" = 0 ]; then note "feed $f: nothing in 10 min, XNYS is outside its extended hours (expected)"
    else bad "feed $f: no report in the last 10 min while XNYS is open"; fi
  done
fi

echo "4. keepers"
for c in $CHAINS; do
  if $DC exec -T "keeper-$c" curl -sf --max-time 5 http://127.0.0.1:9102/readyz >/dev/null 2>&1; then ok "keeper-$c ready"
  else bad "keeper-$c not ready"; fi
  leader="$(prom "max(credence_keeper_is_leader{chain=\"$c\"})" '.data.result[0].value[1] // "none"')"
  [ "$leader" = 1 ] && ok "keeper-$c holds the leader lock" || bad "keeper-$c leader: $leader"
  rev="$(prom "sum(increase(credence_keeper_failed_txs_total{chain=\"$c\",reason=\"reverted\"}[1h]))" '.data.result[0].value[1] // "0"')"
  [ "${rev%%.*}" = 0 ] && ok "keeper-$c: no reverted tx in the last hour" || bad "keeper-$c: $rev reverted tx in the last hour"
done
pages="$(prom 'ALERTS{alertstate="firing",severity="page"}' '[.data.result[].metric | "\(.alertname)\(if .chain then " chain " + .chain else "" end)"] | join(", ")')"
if [ -z "$pages" ]; then ok "no page firing"; else bad "pages firing: $pages"; fi

echo "5. API"
curl -sf --max-time 5 "$API/readyz" >/dev/null && ok "API ready on ${API#http://}" || bad "API /readyz"
for c in $CHAINS; do
  n="$(curl -sf --max-time 15 "$API/v1/markets?chain=$c" | jq -r '(.items // .markets // .) | length' 2>/dev/null)"
  [ "${n:-0}" -gt 0 ] 2>/dev/null && ok "API chain $c: $n market(s)" || bad "API chain $c: no markets (${n:-error})"
done

echo "6. NAV print on 421614"
if [[ " $CHAINS " == *" 421614 "* ]]; then
  n="$(psql_ "select count(*) from ix_421614.price_point where feed = 'NAV'")"
  if [ "${n:-0}" -gt 0 ]; then ok "feedNav: $n NAV print(s) indexed"
  else
    clock="$(curl -sf --max-time 10 "$API/v1/clock/TBILL:USBANK?chain=421614")"
    state="$(echo "$clock" | jq -r '.state.name // empty')"; why="$(echo "$clock" | jq -r '.pause.reason // empty')"
    if [ "$state" = HALTED ] && [ -n "$why" ]; then note "no NAV print yet: TBILL is HALTED ($why) until the first nav-strike"
    else bad "no NAV print, and TBILL is ${state:-unknown} (${why:-no reason})"; fi
  fi
fi

echo "7. Alertmanager → ops inbox"
failed="$(curl -sf --max-time 5 "$AM/metrics" | awk '/^alertmanager_notifications_failed_total\{.*integration="webhook"/ {s += $2} END {print s + 0}')"
if ! curl -sf --max-time 5 "$AM/-/ready" >/dev/null; then bad "Alertmanager not ready"
elif [ "${failed:-0}" = 0 ]; then ok "Alertmanager ready, no failed webhook notification"
else bad "Alertmanager: $failed failed webhook notification(s) (the API's secret or /v1/ops/alerts)"; fi

echo
if [ "$fail" = 0 ]; then echo "testnet-services-check: GREEN"; else echo "testnet-services-check: FAILED" >&2; fi
exit "$fail"
