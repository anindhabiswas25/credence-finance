# Keeper down (KeeperDown, KeeperLeaderMissing, KeeperPaged, ServiceDown)

**Impact:** while no keeper leads on a chain, nothing pokes the clocks (J1), enforces the Bell (J3), settles epochs or reopens. Positions are not at risk for minutes, but a Friday Bell (RB-01) or a reopen (RB-02) can be missed.

1. Which chain: the alert's `chain` label. Look at the container:
   ```sh
   make testnet-ps | grep keeper-46630
   make testnet-logs SVC=keeper-46630
   ```
2. **Exited or restarting:** read the last error in the log. The usual causes:
   - `no signer for keeper on chain …` / `must not be readable by group`: the keystore is missing or not 0600. See [key-rotation.md](key-rotation.md); `chmod 600 ~/.credence/keys/46630/keeper.*`.
   - `RPC chain id … != CHAIN_ID`, or every RPC failing: see [rpc-outage.md](rpc-outage.md).
   - Postgres refused: `make testnet-ps | grep postgres`; see [disk-full.md](disk-full.md).
3. **Running but not leader** (`credence_keeper_is_leader` 0): the lock is held by a dead session. It expires by itself within the lease. To force it, restart the keeper: `docker compose -p credence-testnet -f infra/prod/docker-compose.yml restart keeper-46630`.
4. **KeeperPaged:** the keeper raised its own page (`check` label). `make testnet-logs SVC=keeper-46630 | grep -i page` names it; follow the matching runbook (Bell → [keeper-enforce.md](keeper-enforce.md)).
5. **ServiceDown** for `api`, `notifier` or `solver`: the same steps with `SVC=api` (and so on). The API must answer `curl -sf http://127.0.0.1:8787/readyz`.
6. When it is back: `make testnet-services-check` is green. A missed Bell or reopen: [keeper-enforce.md](keeper-enforce.md).
