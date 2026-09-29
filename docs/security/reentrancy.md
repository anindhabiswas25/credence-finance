# Reentrancy coverage (Build Guide §15.1; S4 item B)

Owner: QA-sec. Attacker model: the loan token (USDC) and the collateral (tNVDA) carry ERC-777-style hooks
(`contracts/test/security/mocks/HookToken.sol`, etched over the fixture's tokens with balances kept): an account the
attacker controls gets `tokensToSend` before and `tokensReceived` after every transfer from / to it, and re-enters from
there (`mocks/Reenterer.sol`). NAV stack: USDC hooked; the fund token is the real testnet `CredenceTreasuryFund`
(its only hook is a view compliance check). A re-entry is **guarded** when it reverts with
`ReentrancyGuardReentrantCall`; a **cross-contract** re-entry is checked with `mocks/AccountingProbe.sol` (every
accounting view read mid-transfer must equal its value after the transaction).

Tests: `contracts/test/security/Reentrancy.t.sol` (R) and `SettlementReentrancy.t.sol` (N). All pass on `da70569`.

| Contract | Money function | Attacker's control point | Re-enters | Result | Test |
| --- | --- | --- | --- | --- | --- |
| CredenceMarket | `addCollateral` | collateral SEND (borrower) | `withdrawCollateral` | guarded | R `test_market_addCollateral` |
| | `withdrawCollateral` | collateral RECEIVE | `withdrawCollateral` | guarded; withdrawn once | R `test_market_withdrawCollateral` |
| | `borrow` | USDC RECEIVE | `borrow` | guarded; borrowed once | R `test_market_borrow` |
| | `repay` | USDC SEND | `withdrawCollateral` | guarded | R `test_market_repay` |
| | `buyCover` (wallet) | USDC SEND | `borrow` | guarded | R `test_market_buyCoverFromWallet` |
| | `borrowWithCover` | USDC RECEIVE | `repay` | guarded | R `test_market_borrowWithCover` |
| | `enforceBell` (auto-cover) | keeper tip RECEIVE | `enforceBell` | guarded; covered once | R `test_market_enforceBell_viaKeeperTip` |
| | `flagForAuction` | keeper tip RECEIVE | `withdrawCollateral` | guarded | R `test_market_flagForAuction_viaKeeperTip` |
| | `settlePositions` | keeper tip RECEIVE; borrower refund RECEIVE | `settlePositions` | guarded; settled once, refunded once | R `test_market_settlePositions_viaKeeperTip`, `…_viaBorrowerRefund` |
| | `claimFees` | (no attacker transfer: pool / treasury / reserve only) | locked while a settlement runs | guarded | R `test_market_claimFees_isLockedDuringASettlement` |
| | `supply` / `withdrawSupply` / `releaseLots` / `onAuctionCleared` / `cancelLot` | none: `onlyVault` / `onlyAuction`, transfers between protocol contracts | — | not reachable; all `nonReentrant` | — |
| SeniorVault | `deposit` | USDC SEND | `withdraw` | guarded | R `test_vault_deposit` |
| | `withdraw` | USDC RECEIVE | `deposit` | guarded; paid once | R `test_vault_withdraw` |
| | `redeem` | USDC RECEIVE | `redeem` | guarded | R `test_vault_redeem` |
| | `claimRedeem` (queue) | USDC RECEIVE | `claimRedeem` | guarded; paid once | R `test_vault_redeemQueueClaim` |
| | `requestRedeem` / `processQueue` | none (vault shares have no hook; processing pays nobody) | — | not reachable | — |
| UnderwriterPool | `deposit` | USDC SEND | `deposit` | guarded | R `test_pool_deposit` |
| | `claimWithdraw` | USDC RECEIVE | `claimWithdraw` | guarded; paid once | R `test_pool_claimWithdraw` |
| | `openEpoch` / `snapshotEpoch` / `settleEpoch` | keeper tip RECEIVE | each other | guarded | R `test_pool_epochLifecycle_viaKeeperTip` |
| | backstop (`clear` → `backstopBuy`) and GDA listing | keeper tip RECEIVE | `resellInventory` / `closeResale` | runs after the backstop is final (different contract, correct); `resellInventory` re-entry guarded | R `test_pool_backstopAndResale_viaKeeperTip` |
| | `payShortfall` / `creditPenalty` / `fallbackAdvance` | none: `onlyMarket` / `onlySettlement` | — | not reachable; `nonReentrant` where they move money | — |
| | `claimRedemption` | keeper tip RECEIVE | `claimRedemption` | guarded | N `test_adapter_finalizeAdvance_andPoolClaim_viaTip` |
| AuctionHouse | `placeBid` | USDC SEND | `placeBid` | guarded | R `test_auction_placeBid` |
| | `commitBid` / `revealBid` | USDC SEND | `commitBid` / `clear` | guarded | R `test_auction_commitAndReveal` |
| | `fixLots` / `clear` | keeper tip RECEIVE | `clear` / `fixLots` | guarded | R `test_auction_clearAndFixLots_viaKeeperTip` |
| | `claim` | collateral RECEIVE, USDC RECEIVE | `claim` | guarded; filled once | R `test_auction_claim` |
| | `completeReopen` | keeper tip RECEIVE | `completeReopen` | guarded | R `test_auction_completeReopen_viaKeeperTip` |
| | `gdaBuy` | collateral RECEIVE | `gdaBuy` | guarded | R `test_auction_gdaBuy` |
| SolverAuction | `bid` | USDC SEND | `bid` | guarded | N `test_solver_bid` |
| | outbid refund (inside `bid`) | USDC RECEIVE (outbid solver) | `bid` | guarded; refunded once, cannot retake the lead | N `test_solver_outbidRefund` |
| | `withdrawRefund` | USDC RECEIVE (after a refused refund) | `withdrawRefund` | guarded; a refused refund never blocks the better bid | N `test_solver_withdrawRefund` |
| SettlementAdapter | `openSettlement` | forwarded FLAG tip RECEIVE (mid-function, before the window opens) | `openSettlement`, `finalize` | guarded | N `test_adapter_openSettlement_viaForwardedTip` |
| | `finalize` (fill) | forwarded tips RECEIVE | `finalize`; probe | guarded; accounting final at the last tip | N `test_adapter_finalizeFill_viaForwardedTip` |
| | `finalize` (no bid → pool advance) | forwarded tips RECEIVE | `openSettlement` | guarded | N `test_adapter_finalizeAdvance_andPoolClaim_viaTip` |

## Cross-contract (enter A, re-enter B)
Per-contract guards do not stop a hook from calling a *different* contract. Checked with the probe:

| Entered | Hook | Read / call in B | Result | Test |
| --- | --- | --- | --- | --- |
| market `borrow` | USDC RECEIVE | vault, pool, market views | final | R `test_cross_borrow_accountingIsFinal` |
| market `withdrawCollateral` | collateral RECEIVE | same | final | R `test_cross_withdrawCollateral_accountingIsFinal` |
| vault `withdraw` | USDC RECEIVE | same | final | R `test_cross_vaultWithdraw_accountingIsFinal` |
| market `buyCover` (wallet) | USDC SEND | `pool.deposit` | pool NAV is low mid-transfer (premium booked before the cash arrives), but a deposit in an open epoch is queued, not priced | R `test_cross_buyCover_poolDepositFromTheHookIsQueued` |
| auction house `claim` | collateral RECEIVE | views | final | R `test_cross_auctionClaim_accountingIsFinal` |
| auction house `gdaBuy` | collateral RECEIVE | pool NAV; `pool.settleEpoch` | **was QA-01**: NAV +9,494 USDC mid-transfer, withdrawal price +1.59 %. Fixed (`61761b9`): the pool books the sale before the tokens leave | R `test_cross_gdaBuy_poolNavIsFinal`, `test_cross_gdaBuy_settleEpochInflatesTheWithdrawalPrice` |
| adapter `finalize` | last forwarded tip | views | final | N `test_adapter_finalizeFill_viaForwardedTip` |

## Not a reentrancy vector (and why)
- Keeper tips use a low-level `transfer` that never reverts the caller (`KeeperTips.pay`), but the keeper *can* run
  code in it with a hooked token: every tip is therefore paid at the end of its job or inside a locked function (above).
- Testnet collateral tokens (`CredenceStockToken`, `CredenceTreasuryFund`) call only a **view** compliance hook; the
  suite assumes the worst case (a real token with receive hooks, §15.1) regardless.
