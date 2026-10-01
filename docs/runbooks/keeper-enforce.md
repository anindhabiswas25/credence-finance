# Manual keeper actions (RB-01 Friday Bell, RB-02 reopen: BellNotEnforced, ReopenStuck, EpochNotSettled)

The keeper normally does all of this. These are the manual equivalents; anyone may call them (the contracts check everything), but sign with the keeper's keystore so it pays the gas and earns the tip.

```sh
C=46630; BOOK=infra/prod/generated/$C/book.json; KS=~/.credence/keys/$C
set -a; . infra/prod/secrets/rpc.env; set +a; RPC=$RPC_46630_PRIMARY
SEND="cast send --rpc-url $RPC --keystore $KS/keeper.json --password-file $KS/keeper.password"
MARKET=$(jq -r .equity.market $BOOK); MID=$(jq -r '.equity.markets.NVDA' $BOOK)   # the market and the asset's market id
```

**BellNotEnforced** (NEEDS_ACTION positions left at bellAt + 10 min): enforce the Bell for them, in batches of ≤ 9 (ADR-0114's J3 batch). Do it before `close − 5 min` (QA-10: after the PRECLOSE fixing, a batch that needs a pre-close sale reverts).
The borrowers: the keeper's log names the NEEDS_ACTION positions it could not enforce (`make testnet-logs SVC=keeper-46630 | grep J3`).
```sh
cast call $MARKET 'enforceBell(bytes32,address[])' $MID '[0xBorrower1,0xBorrower2]' --rpc-url $RPC   # pre-check
$SEND $MARKET 'enforceBell(bytes32,address[])' $MID '[0xBorrower1,0xBorrower2]'
```

**ReopenStuck** (REOPEN not complete 15 min after the open print): poke the clock, then complete the reopen.
```sh
ASSET=$(jq -r .assetIds.NVDA $BOOK)
$SEND $(jq -r .shared.clock $BOOK) 'poke(bytes32)' $ASSET
$SEND $(jq -r .equity.auctionHouse $BOOK) 'completeReopen(bytes32)' $ASSET        # 421614: .nav.settlement
```
If it reverts `ReopenNotOver`, the auction phases are still running: wait for them. Check the keeper log for the reason it did not finish.

**EpochNotSettled** (2 h after reopenAt):
```sh
POOL=$(jq -r .equity.pool $BOOK)
curl -s "http://127.0.0.1:8787/v1/pool/equity/epochs?chain=$C" | jq '.items[0]'   # the unsettled epoch's id
$SEND $POOL 'settleEpoch(uint64)' <epochId>
```

Every manual call is pre-checked the same way: run it with `cast call` first (same arguments) and send only when it does not revert.
