# NAV print missing (NavPrintMissing, 421614)

The `navstrike-421614` service runs `credence-relayer nav-strike --publish` once per USBANK session, `NAVSTRIKE_OFFSET_S` (30 min) after it opens: the NAV committee (`nav-1..3`, threshold 2) signs the report, `nav-submitter` submits it to `feedNav`, and the issuer EOA calls `publishNav` on the fund (PM 16:30 ruling 3; testnet only). The keeper's `credence_keeper_nav_print_overdue_seconds` counts from the session's end when no print landed. **One missed session marks the feed stale, two make TBILL `navInvalid` (HALTED).**

1. The timer's log: `make testnet-logs SVC=navstrike-421614` (`strike failed` and the reason).
2. Common causes:
   - `nav-submitter` or `issuer` out of gas: [wallet-low.md](wallet-low.md);
   - a keystore missing / not 0600: [key-rotation.md](key-rotation.md);
   - every RPC down: [rpc-outage.md](rpc-outage.md);
   - `NotEnoughSigners`: fewer than 2 `nav-*` keystores load.
3. Strike by hand (the same command the timer runs):
   ```sh
   docker compose -p credence-testnet -f infra/prod/docker-compose.yml --env-file infra/prod/.env.prod \
     exec navstrike-421614 credence-relayer nav-strike --publish
   ```
   `--dry-run` signs and prints without sending.
4. The timer then sees the session as done only after its own successful run; a manual strike plus the timer's makes two prints in one session, which is harmless (a tiny extra accrual).
5. The first print after a deploy takes TBILL out of HALTED; until then the API shows `pause.reason = HALTED` on TBILL.
