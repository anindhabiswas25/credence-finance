# Stale feed, or the two feeds disagree (RB-04: FeedStale, FeedDisagreement, FeedDisagreementSevere, RelayerNodeDown)

**Testnet setup:** on 46630 feed A and feed B are two RedStone committees (3 signer nodes + an aggregator each, threshold 2; PM 16:30 ruling 1). 421614 has no price relayer (only the NAV strike).

**Not an incident:** MSFT, GOOGL and AMZN have no RedStone extended-hours feed, so out of the regular session they go stale and borrowing on them pauses. The API shows `pause.reason = STALE_EXTENDED`, and no page fires (FeedStale is REGULAR only).

1. Which feed and asset: the alert's `feed` / `asset` labels. Check the committee:
   ```sh
   make testnet-ps | grep relayer-a
   make testnet-logs SVC=relayer-a-agg
   ```
2. **One node down (RelayerNodeDown):** the committee still publishes with 2 of 3. Restart it: `docker compose -p credence-testnet -f infra/prod/docker-compose.yml restart relayer-a-node-2`.
3. **Every node of a feed says `no LIVE observation`:** RedStone has no fresh package. Check it from the host: `make relayer-redstone-smoke`. If the gateway is down, there is no second vendor on testnet: the feed stays stale, and the market pauses (fail-closed). Note it on the board.
4. **The aggregator can't submit** (`submit failed`, `insufficient funds`): the submitter wallet is empty. See [wallet-low.md](wallet-low.md) (`relayer-a-submitter`).
5. **Disagreement > 1.5 % / > 5 %:** both committees use RedStone, so a disagreement means one committee reads a stale or wrong package. Compare the two prices: `curl -s 'http://127.0.0.1:8787/v1/clock/NVDA:XNAS?chain=46630' | jq .feeds`. Restart the lagging committee's nodes. The oracle already uses min(p1, p2) above 1.5 %. If it persists past 15 min and prices are clearly wrong, the guardian (a Safe) may pause the asset.
6. Done when `make testnet-services-check` shows both feeds publishing.
