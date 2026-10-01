# The disk is full

Postgres, the backups, Prometheus (30 days) and the container logs (20 MB × 5 per service) live on this machine.

1. Where the space went:
   ```sh
   df -h / /var/lib/docker
   docker system df
   du -sh infra/prod/backups
   ```
2. Free space, in this order (never `docker volume prune` or `docker system prune --volumes`: that deletes the database):
   - old backups: `ls -1t infra/prod/backups | tail -n +8` → delete the oldest ones by hand (the nightly job keeps 14 days);
   - unused images and build cache: `docker image prune -f && docker builder prune -f --filter until=72h`;
   - Prometheus history: lower `PROM_RETENTION` in `infra/prod/.env.prod` (e.g. `15d`), then `make testnet-up`.
3. If Postgres stopped (`could not extend file`), it restarts by itself once there is space (`restart: unless-stopped`); check `make testnet-ps`.
4. Then `make testnet-services-check`. If the indexers lost writes, they resume from their last checkpoint; a corrupt state needs [indexer-reindex.md](indexer-reindex.md) or [postgres-restore.md](postgres-restore.md).
