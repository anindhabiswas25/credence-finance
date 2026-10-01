# A corporate action: split, reverse split, dividend (ERC-8056, RB-07)

The collateral tokens follow ERC-8056: a multiplier (`sharesPerToken`). The oracle caches it: a step ≤ 2 % is synced automatically on each poke; a larger one needs a corporate-action closure. The keeper's notifier sends the corporate-action alerts (scheduled / cancelled / begun / confirmed) to the holders' inboxes.

1. See the token's schedule and the oracle's view:
   ```sh
   BOOK=infra/prod/generated/46630/book.json; ASSET=$(jq -r .assetIds.NVDA $BOOK)
   cast call $(jq -r .shared.oracle $BOOK) 'multiplierState(bytes32)(uint256,uint256,uint256,uint256,bool)' $ASSET --rpc-url $RPC
   ```
   (cached, live, next, at, corporateAction)
2. **Before the effective date:** the guardian begins the corporate action (`beginCorporateAction`, the Guardian Safe). The asset goes CORP_ACTION; borrowing pauses (the API says `pause.reason = CORP_ACTION`).
3. **After it takes effect** and both feeds print the adjusted price: `syncMultiplier(asset)` caches the new multiplier when the prints × the new multiplier match the closure's reference (anyone may call it; the keeper's poke does). If the step is too large for that, the timelock confirms it (`confirmCorporateAction(newSharesPerToken)`, a `make gov-propose` batch).
4. REOPEN follows: [keeper-enforce.md](keeper-enforce.md).
5. Our own test tokens on 46630 only change their multiplier when the Ops Safe schedules it (a test of this runbook). The official RHTSLA follows Robinhood's.
