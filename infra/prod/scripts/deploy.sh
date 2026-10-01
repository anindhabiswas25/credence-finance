#!/usr/bin/env bash
# Bring the local testnet stack to an image tag, migrations first, behind a health gate. Owner: BE-backend.
#
#   deploy.sh up                     start the stack at the current tag (make testnet-up)
#   deploy.sh deploy [TAG]           build the images as TAG (default: the git short sha), migrate up, switch, gate;
#                                    a failed gate switches the images back to the previous tag (make services-deploy)
#   deploy.sh rollback [N]           roll back N migrations (default 0), then switch to the previous tag, gate
#                                    (make services-rollback MIGRATIONS=N)
#   deploy.sh service SVC…           rebuild the named services' images at the current tag and recreate only those
#                                    (--no-deps: Postgres and every other service keep running), gate; a failed gate
#                                    restores the images kept as :rollback. No migrations (make services-deploy SVC=…)
#   deploy.sh wait                   the health gate alone
#
# The tags live in $STATE_DIR/tag.current and tag.previous. DC is the compose command (mk/ops.mk).
set -euo pipefail
DC="${DC:?DC=docker compose … (run it through make)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STATE="${STATE_DIR:?STATE_DIR}"
GATE_S="${GATE_S:-600}"
# host dirs the services write, made by the host user (docker would make them root-owned)
mkdir -p "$STATE/navstrike" "${BACKUP_HOST_DIR:-$ROOT/infra/prod/backups}"
cur() { cat "$STATE/tag.current" 2>/dev/null || echo latest; }
prev() { cat "$STATE/tag.previous" 2>/dev/null || true; }
say() { echo "[$(date +%H:%M:%S)] $*"; }

# every service up, healthy where it has a health check, the migration exited 0
wait_healthy() {
  local deadline=$(( $(date +%s) + GATE_S )) bad
  while :; do
    bad="$($DC ps -a --format json | jq -rs 'if (.[0] | type) == "array" then .[0] else . end | .[]
      | select((.Service == "migrate" and (.State != "exited" or .ExitCode != 0))
            or (.Service != "migrate" and (.State != "running" or ((.Health // "") != "" and .Health != "healthy"))))
      | "\(.Service)=\(.State)/\(.Health // "-")"' | paste -sd' ' -)"
    [ -z "$bad" ] && { say "health gate: every service is healthy"; return 0; }
    [ "$(date +%s)" -lt "$deadline" ] || { say "health gate FAILED after ${GATE_S}s: $bad"; return 1; }
    sleep 10
  done
}

migrate() { MIGRATE_CMD="$1" $DC run --rm migrate; }

switch() { # tag → the stack runs it
  TAG="$1" $DC up -d --remove-orphans
}

case "${1:-up}" in
  up)
    say "testnet stack up at tag $(cur)"
    TAG="$(cur)" $DC build
    TAG="$(cur)" $DC up -d --remove-orphans
    TAG="$(cur)" wait_healthy
    ;;
  deploy)
    new="${2:-$(git -C "$ROOT" rev-parse --short HEAD)}"
    old="$(cur)"
    say "services-deploy: $old → $new (build, migrate up, switch, gate)"
    TAG="$new" $DC build
    TAG="$new" migrate up
    switch "$new"
    if TAG="$new" wait_healthy; then
      [ "$old" != "$new" ] && echo "$old" > "$STATE/tag.previous"
      echo "$new" > "$STATE/tag.current"
      say "services-deploy: running $new (previous $old)"
    else
      say "services-deploy: the gate failed; switching the images back to $old (migrations stay; make services-rollback MIGRATIONS=n undoes them)"
      switch "$old"; TAG="$old" wait_healthy || true
      exit 1
    fi
    ;;
  rollback)
    n="${2:-0}"; to="$(prev)"
    [ -n "$to" ] || { echo "services-rollback: no previous tag recorded in $STATE/tag.previous" >&2; exit 1; }
    from="$(cur)"
    say "services-rollback: $from → $to, rolling back $n migration(s) first"
    if [ "$n" -gt 0 ]; then
      # the new code must not run on the old schema: stop it while the migrations roll back
      $DC stop $($DC config --services | grep -vE '^(postgres|prometheus|alertmanager|grafana|pg-backup)$')
      for _ in $(seq "$n"); do TAG="$from" migrate rollback; done
    fi
    switch "$to"
    TAG="$to" wait_healthy
    echo "$to" > "$STATE/tag.current"; echo "$from" > "$STATE/tag.previous"
    say "services-rollback: running $to"
    ;;
  service)
    shift
    [ $# -gt 0 ] || { echo "services-deploy SVC='<service> …': name the service(s)" >&2; exit 2; }
    tag="$(cur)"
    imgs="$(TAG="$tag" $DC config --format json | jq -r --args '.services | to_entries[]
      | select(.key as $k | $ARGS.positional | index($k)) | .value.image' "$@" | sort -u)"
    [ -n "$imgs" ] || { echo "services-deploy: no such service: $*" >&2; exit 2; }
    for i in $imgs; do docker image tag "$i" "${i%:*}:rollback"; done
    say "services-deploy SVC=$*: rebuild $(echo $imgs) at $tag, recreate only these, gate"
    TAG="$tag" $DC build "$@"
    TAG="$tag" $DC up -d --no-deps "$@"
    if TAG="$tag" wait_healthy; then
      say "services-deploy: $* running the new build at $tag (old images kept as :rollback)"
    else
      say "services-deploy: the gate failed; restoring the :rollback images of $*"
      for i in $imgs; do docker image tag "${i%:*}:rollback" "$i"; done
      TAG="$tag" $DC up -d --no-deps --force-recreate "$@"; TAG="$tag" wait_healthy || true
      exit 1
    fi
    ;;
  wait) TAG="$(cur)" wait_healthy ;;
  *) echo "usage: deploy.sh up|deploy [TAG]|service SVC…|rollback [N]|wait" >&2; exit 2 ;;
esac
