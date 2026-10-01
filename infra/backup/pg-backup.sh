#!/bin/sh
# Postgres backups of the local testnet stack (infra/prod, the pg-backup service). Owner: BE-backend.
#
#   pg-backup.sh loop          nightly at BACKUP_AT_UTC (HH:MM, default 20:30 UTC = 02:00 IST), then prune
#   pg-backup.sh once          one backup now (make db-backup)
#   pg-backup.sh restore FILE  restore FILE (a name in BACKUP_DIR) into the database (make db-restore FILE=…);
#                              the services must be stopped first (make db-restore does it)
#
# Each backup is `pg_dump -Fc` of the whole database (ops, app, the indexers' schemas) into
# BACKUP_DIR/credence-<UTC stamp>.dump, written to a .partial file and renamed when complete. Backups older than
# BACKUP_KEEP_DAYS (default 14) are deleted. The password comes from the 0600 file PGPASSFILE_SRC and never appears
# in a command line or a log.
set -eu
DIR="${BACKUP_DIR:-/backups}"
KEEP="${BACKUP_KEEP_DAYS:-14}"
AT="${BACKUP_AT_UTC:-20:30}"
if [ -n "${PGPASSFILE_SRC:-}" ]; then
  PGPASSWORD="$(cat "$PGPASSFILE_SRC")"
  export PGPASSWORD
fi
log() { echo "pg-backup $(date -u +%FT%TZ) $*"; }

once() {
  mkdir -p "$DIR"
  f="$DIR/credence-$(date -u +%Y%m%dT%H%M%SZ).dump"
  pg_dump -Fc -f "$f.partial"
  mv "$f.partial" "$f"
  log "wrote $(basename "$f") ($(du -h "$f" | cut -f1))"
  find "$DIR" -name 'credence-*.dump' -mtime +"$KEEP" -print -delete | sed 's/^/pg-backup pruned /'
  find "$DIR" -name '*.partial' -mmin +120 -delete
}

case "${1:-loop}" in
  once) once ;;
  restore)
    f="$DIR/$(basename "${2:?restore FILE}")"
    [ -f "$f" ] || { log "no backup $f"; exit 1; }
    log "restoring $(basename "$f") (drops and recreates every object in it)"
    pg_restore --clean --if-exists --no-owner -d "${PGDATABASE:-credence}" "$f"
    log "restored"
    ;;
  loop)
    log "nightly at $AT UTC into $DIR, keeping $KEEP days"
    while :; do
      now="$(date -u +%s)"
      next="$(date -u -d "$(date -u +%F) $AT" +%s)"
      [ "$next" -gt "$now" ] || next=$((next + 86400))
      sleep $((next - now))
      once || log "backup failed (retry tomorrow; make db-backup runs one now)"
    done
    ;;
  *) echo "usage: pg-backup.sh loop|once|restore FILE" >&2; exit 2 ;;
esac
