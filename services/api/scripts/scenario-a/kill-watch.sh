#!/usr/bin/env bash
# Acceptance 4 (S3): SIGKILL the keeper right after its first REOPEN fixLots is done, and restart it (same env,
# same instance id) 20 s later, before the auction's clear at +7:00. Usage: kill-watch.sh <OUT dir> <keeper cmd…>
OUT=$1; shift
cd "$(dirname "$0")/../../../.."
for i in $(seq 1 4000); do
  n=$(docker compose -f infra/docker-compose.yml exec -T postgres psql -U credence -d credence -tAc \
        "select count(*) from ops.keeper_job where key like 'J5:%:fixLots:%' and status = 'done'" 2>/dev/null || echo 0)
  [ "${n:-0}" -ge 1 ] && break; sleep 3
done
KP=$(pgrep -x credence-keeper | head -1)
[ -n "$KP" ] && kill -9 "$KP" && echo "$(date -u +%T) killed the keeper (pid $KP) between fixLots and clear" >> "$OUT/restart.log"
sleep 20
"$@" >> "$OUT/keeper.log" 2>&1 &
echo "$(date -u +%T) restarted the keeper (pid $!)" >> "$OUT/restart.log"
wait
