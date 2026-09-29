#!/usr/bin/env bash
# Long-run wrapper (charter §2a): runs a command detached from the session, keeps the laptop awake, and leaves an
# explicit verdict line in the log: "DONE exit=N" when the command ends, "ABORTED …" if it is killed. A run whose log
# has neither line and whose pid is gone died with the machine: `long_run.sh status <log>` reports it as ABORTED.
#
#   long_run.sh start <log> -- <command …>     start detached (setsid nohup systemd-inhibit), print the pid
#   long_run.sh status <log>                    RUNNING / DONE exit=N / ABORTED
set -uo pipefail

mode=${1:?start|status}
log=${2:?log file}
shift 2

case "$mode" in
start)
  [ "${1:-}" = "--" ] && shift
  mkdir -p "$(dirname "$log")"
  : > "$log"
  inner=$(cat <<'EOF'
log=$1; shift
echo "START $(date -u +%FT%TZ) pid=$$ cmd=$*" >> "$log"
trap 'echo "ABORTED $(date -u +%FT%TZ) signal" >> "$log"; exit 130' INT TERM HUP
"$@" >> "$log" 2>&1
rc=$?
echo "DONE exit=$rc $(date -u +%FT%TZ)" >> "$log"
exit $rc
EOF
)
  inhibit=()
  command -v systemd-inhibit >/dev/null && inhibit=(systemd-inhibit --what=idle:sleep:handle-lid-switch --who=qa-sec --why="long run: $log")
  setsid nohup "${inhibit[@]}" bash -c "$inner" long_run "$log" "$@" >/dev/null 2>&1 &
  echo "$!" > "$log.pid"
  echo "started pid $(cat "$log.pid"), log $log"
  ;;
status)
  if grep -q '^DONE ' "$log" 2>/dev/null; then grep '^DONE ' "$log" | tail -1
  elif grep -q '^ABORTED ' "$log" 2>/dev/null; then grep '^ABORTED ' "$log" | tail -1
  elif [ -f "$log.pid" ] && kill -0 "$(cat "$log.pid")" 2>/dev/null; then echo "RUNNING pid $(cat "$log.pid")"
  else echo "ABORTED (no verdict line and the process is gone)" | tee -a "$log"; fi
  ;;
*) echo "usage: $0 start|status <log> [-- cmd …]" >&2; exit 2 ;;
esac
