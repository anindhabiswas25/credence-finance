# An asset is HALTED (RB-03), a shortfall escalated (RB-12), pool utilisation high

**Why an asset is HALTED** (the API says it: `curl -s 'http://127.0.0.1:8787/v1/clock/<TICKER:MIC>?chain=<id>' | jq '.state, .pause'`):
- a single-stock halt from the STATUS report (Nasdaq halt feed);
- the issuer froze the token, or a paused Robinhood Stock Token (RHTSLA);
- **TBILL on 421614 before its first NAV print**, or after two missed USBANK strikes: see [nav-print-missing.md](nav-print-missing.md).

1. Confirm there are no liquidations running on that asset: `curl -s 'http://127.0.0.1:8787/v1/auctions?chain=46630' | jq '.items[] | select(.asset == "<id>")'`.
2. On resume, the first cross-checked print becomes the open print, then the REOPEN auction runs. Watch the reopen in [keeper-enforce.md](keeper-enforce.md); if the open print is ±50 % off, [open-print.md](open-print.md).
3. A halt across an epoch settlement: check `pendingLossReserve` (R-11) on the pool: `cast call $(jq -r '.equity.pool' infra/prod/generated/46630/book.json) 'pendingLossReserve()(uint256)' --rpc-url $RPC`.

**ShortfallEscalated** (a loss reached the reserve or the senior vault): post on the board at once (RB-12: a post-mortem is due). Collect `make testnet-logs SVC=keeper-46630` around the event and the Shortfall tx from the indexer.

**PoolUtilisation > 45 %:** a ticket. Note it on the board; underwriters can add capital. Borrowing stops by itself at `uMax`.
