# Postgres restore

The `pg-backup` service dumps the whole database (`ops`, `app`, the indexers' schemas) every night at `BACKUP_AT_UTC` (default 20:30 UTC = 02:00 IST) into `infra/prod/backups/credence-<UTC stamp>.dump`, keeping `BACKUP_KEEP_DAYS` (14).

1. A backup now (before anything risky): `make db-backup`.
2. Pick the dump: `ls -lt infra/prod/backups`.
3. Restore it (stops every service but Postgres and the observability, restores with `pg_restore --clean`, starts them, then the health gate):
   ```sh
   make db-restore FILE=credence-20261002T203000Z.dump
   ```
4. After a restore, the indexers resume from the restored checkpoint and catch up to the head (minutes). The keepers' job keys (`ops.keeper_job`) make every job idempotent, so nothing is sent twice; jobs after the dump's time are simply re-checked on chain.
5. `make testnet-services-check` green.

**Only the indexers' data is bad** (not the app/ops tables): a reindex is lighter than a restore: [indexer-reindex.md](indexer-reindex.md).
