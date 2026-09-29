# Edge-case matrix

Owner: QA-sec · Sprint 4 item H (user decision 2026-09-29 18:30). The deep audit, the 256 × 512 nightlies and the long
soaks moved to pre-mainnet (`docs/security/pre-mainnet.md`). Until then, this is the QA bar: **every probable path, at
its edges.**

Each row gives the trigger, the expected behaviour (with the Guide or ADR reference), the test that proves it, and a
status.
- Contract tests are under `contracts/test/` and run in `forge test`. The QA-sec edge suite is
  `contracts/test/security/edge/` (`make security-test`); its test names start with the row id.
- Off-chain tests belong to BE-backend and run in `make backend-edge` (`mk/backend.mk`). QA-sec reviewed that each one
  really triggers its case.

**Status:**
- **proven**: a test triggers the case and asserts the expected behaviour.
- **DEFECT**: the test fails today (run it with `QA_FINDINGS=1`); a REQUEST is open with the owner.
- **pinned**: today's behaviour is asserted, but it is a design question; a REQUEST or PM ruling is open.
- **partly**: the test covers part of the case (the note says what is missing).
- **gap**: no test yet; a REQUEST is open with the owner.

Last run (2026-09-29, `3c82b87` + this commit): `forge test --match-path 'test/security/edge/*'` gave 48 passed and
1 skipped (QA-10). After BE-chain's fix (`1e07b99`, ADR-0115) the QA-10 test runs unconditionally and passes: 49 passed, 0 skipped.

## 1. Contracts

### 1.1 Market: limits, dust and races (`CredenceMarket`, `BorrowLogic`)

| ID | Trigger | Expected (ref.) | Test | Status |
| --- | --- | --- | --- | --- |
| E-M-01 | Borrow to exactly maxLtv; then 1 unit more | Exactly at the limit passes; +1 reverts `LtvAboveLimit` (§8.4.2) | `edge/MarketEdges.t.sol: test_E_M01_…` | proven |
| E-M-02 | Two borrowers race for the last liquidity in one block | The exact remainder passes; +1 reverts `InsufficientLiquidity`; the vault then cannot pull from the market | `test_E_M02_…` | proven |
| E-M-03 | Borrow cap exactly reached; then +1 | `CapExceeded(cap + 1, cap)` | `test_E_M03_…` | proven |
| E-M-04 | Borrow 1 unit; "repay max" by assets while interest accrues; full repay by shares | A 1-unit debt exists; repay by assets > debt reverts `InvalidParam` (the UI must repay max **by shares**); by shares costs exactly `debtOf` and leaves 0 | `test_E_M04_…` | proven (UI note → BE-backend / Frontend) |
| E-M-05 | Repay 1 base unit when a share is worth > 1 unit | Never takes the unit without burning a share (`ZeroAmount`) | `test_E_M05_…`; `fuzz/RoundingFuzz.t.sol` | proven |
| E-M-06 | Withdraw collateral within the LTV limit but HF < 1.05 (LT = maxLtv + 3 pp) | `HealthFactorTooLow` (§12.2); just above 1.05 passes | `test_E_M06_…` | proven |
| E-M-07 | Zero amounts, zero addresses, unknown ids | `ZeroAmount` / `ZeroAddress` / `MarketNotFound` | `unit/CredenceMarketPaths.t.sol: test_borrowWithCoverAndErrors`, `test_createMarketValidation` | proven |
| E-M-08 | Borrow while REOPEN / CORP_ACTION / stress flag / guardian pause | Refused (`ActionNotAllowedInState`, `BorrowPaused`) | `unit/CredenceMarket.t.sol: test_borrowBlockedByState`, `test_guardianPauseAndHaircut` | proven |
| E-M-09 | Clock goes HALTED between a quote and the borrow | Borrow held to the safe LTV on projected debt; flagging refused | `test_E_M18_haltBetweenQuoteAndBorrow` | proven |
| E-M-10 | Empty position (no debt) withdraws in any clock state | Always allowed (ADR-0107) | `test_E_M04_…` (tail), `unit/CredenceMarketPaths.t.sol: test_withdrawCollateralRules` | proven |
| E-M-11 | Supply-side withdrawal when the market is fully borrowed | Refused; the vault queues (R-17) | `test_E_M02_…`, `unit/CredenceMarketPaths.t.sol: test_redeemQueueStopsAtLiquidity` | proven |

### 1.2 Market: cover and the Bell (`CoverLogic`)

| ID | Trigger | Expected (ref.) | Test | Status |
| --- | --- | --- | --- | --- |
| E-B-01 | `buyCover` at bellAt − 1 s, then at bellAt | Accepted, then `ActionNotAllowedInState(BUY_COVER)` (INV-COV-01) | `test_E_M07_…` | proven |
| E-B-02 | `enforceBell` at bellAt − 1 s, at bellAt, at closeAt | Refused, runs, refused (§8.4.3 `[bellAt, closeAt)`) | `test_E_M08_…` | proven |
| E-B-03 | The same borrower twice in one batch; a second keeper's batch in the same block | Enforced once, tipped once; the second batch is a no-op | `test_E_M09_…` | proven |
| E-B-04 | Bell with 0 positions; with a debt-free or unknown address | No-op, no revert, no event | `test_E_M10_…` | proven |
| E-B-05 | Manual cover at exactly maxLtv + δ (75.5 %), and just above | Accepted; `LtvAboveCoverable` (R-03) | `test_E_M11_…` | proven |
| E-B-06 | **A Bell batch sent after the PRECLOSE fixing (close − 5 min) that holds one sale candidate** | The batch goes on ("skip, don't revert", §8.4.3); the others are auto-covered | `test_E_M12_QA10_lateBellBatchStillAutoCovers` | proven — **QA-10** (Medium) fixed `1e07b99` (SALE_TOO_LATE, the batch goes on), verified by QA-sec |
| E-B-07 | The same batch 1 s before the PRECLOSE fixing | Both processed (cover + pre-close lot) | `test_E_M12b_…` | proven |
| E-B-08 | Pool capacity exhausted / cover refused at the Bell | Auto-cover fails closed → pre-close sale | `unit/CredenceMarket.t.sol: test_enforceBellAutoCoverAndPreclose`; `edge/PoolEdges.t.sol: test_E_P05_…` | proven |
| E-B-09 | Last night's epoch still unsettled at the next Bell | Cover refused (`PolicyEpochMismatch`); the Bell falls back to the pre-close sale (ADR-0110 §3) | `test_E_P05_…` | proven |
| E-B-10 | A chosen gas limit on `enforceBell` (deep out-of-gas in the auto-cover) | Cannot turn a cover into a sale (ADR-0109, QA-09) | `security/GasGriefing.t.sol: test_enforceBell_gasCannotForceASale` | proven |
| E-B-11 | Bell with 35+ NEEDS_ACTION positions (4+ J3 txs) | Each tx ≤ 50 positions within the block gas limit; all inside the deadline | `unit/BellBatch.t.sol` (batch ≡ full computation); off-chain row K-06 | partly (the gas per 50-position batch on the real engine is BE-chain's `make devnode-gas`, S4 item E) |

### 1.3 Liquidation queue and lots (`LiquidationLogic`)

| ID | Trigger | Expected (ref.) | Test | Status |
| --- | --- | --- | --- | --- |
| E-L-01 | HF exactly 1.0; then 1 wei of price lower | Not flagged; flagged (§8.4.3 "HF < 1") | `test_E_M14_…` | proven |
| E-L-02 | A queued position tries to borrow, withdraw or buy cover; then repays or adds collateral | Frozen (`PositionInAuction`), but it can cure | `test_E_M13_…` | proven |
| E-L-03 | 129 positions: the lot fills at 128, and the 129th is flagged in a later call | Goes into the next tranche (not `TooManyPositions`) (§8.7.1) | `test_E_M15_…` | proven |
| E-L-04 | A position flagged after the current INTRADAY lot was fixed | Starts a new lot (not `LotAlreadyReleased`) | `test_E_M16_…` | proven |
| E-L-05 | REOPEN flag at openPrintAt + 119 s and at + 120 s | Joins; refused | `test_E_M17_…` | proven |
| E-L-06 | Everyone in a lot cures before fixing | Empty lot counts as cleared and settled (ADR-0107 §7) | `unit/AuctionHouse.t.sol: test_emptyLotCountsAsSettled` | proven |
| E-L-07 | The clock leaves the lot's state before fixing (e.g. INTRADAY after the close) | Lot cancelled, positions free | `unit/AuctionHouse.t.sol: test_lotThatCanNoLongerBeFixedIsCancelled` | proven |
| E-L-08 | A chosen gas limit on `fixLots` | Cannot cancel a lot (ADR-0109) | `security/GasGriefing.t.sol: test_fixLots_gasCannotCancelALot` | proven |
| E-L-09 | A shortfall at settlement, with a chosen gas limit | The pool pays before the senior vault | `security/GasGriefing.t.sol: test_settle_gasCannotPushAShortfallToSeniors`; `unit/CredenceMarket.t.sol: test_waterfallReachesSeniorOnlyAfterPoolAndReserve` | proven |
| E-L-10 | Settle before clear; partial settlement over several calls | `LotNotCleared`; partial is fine | `unit/CredenceMarketPaths.t.sol: test_settleBeforeClearReverts`, `test_partialSettlementAndReserveFeeShare` | proven |

### 1.4 Auction house

| ID | Trigger | Expected (ref.) | Test | Status |
| --- | --- | --- | --- | --- |
| E-A-01 | A bid in the fixing second, ordered before `fixLots` in the block; `fixLots` 1 s early | `PhaseClosed(QUEUE)` (the bot retries); `TooEarly` | `edge/AuctionEdges.t.sol: test_E_A01_…` | proven |
| E-A-02 | A bid in the last second and in the first late second; clear early; clear twice; claim twice | Accepted / `TooLate` / `TooEarly` / `PhaseClosed` / `NothingToClaim` | `test_E_A02_…` | proven |
| E-A-03 | Two bidders at the same price in one block, together over the lot | Fills sum to the lot, each ≤ its qty; the pool takes nothing; cash and tokens conserved (INV-AH-01/04) | `test_E_A03_…` | proven |
| E-A-04 | A 1-wei bid | `BidTooSmall`, no slot taken | `test_E_A04_…` | proven |
| E-A-05 | REOPEN: everyone commits, nobody reveals; a reveal at deadlines[3] | Bonds to the pool, the pool backstops the whole lot at R; `TooLate` | `test_E_A05_…` | proven |
| E-A-06 | No bids at all | The pool backstops at R | `unit/AuctionHouse.t.sol`, `security/GasGriefing.t.sol` (no-bid clear) | proven |
| E-A-07 | Partial fill (bids < lot) | Uniform p*; the pool takes the rest at R | `unit/AuctionHouse.t.sol: test_intradayClearsAtUniformPriceWithBackstop` | proven |
| E-A-08 | 64 below-reserve bids fill the slots; low-ball reveals | Refused / bond forfeited (QA-02) | `security/AuctionFindings.t.sol: test_QA02_*` | proven |
| E-A-09 | GDA across a closure; GDA still unsold at the next closure | No buys outside REGULAR; never below (1 − κ)·V (QA-03/04) | `security/AuctionFindings.t.sol: test_QA03_*`, `test_QA04_*` | proven |
| E-A-10 | Resale with nothing to sell; an unknown GDA | `NoInventory`; `UnknownGda` | `edge/PoolEdges.t.sol: test_E_P07_…` | proven |

### 1.5 Underwriter pool

| ID | Trigger | Expected (ref.) | Test | Status |
| --- | --- | --- | --- | --- |
| E-P-01 | Withdraw request of exactly the balance, then +1 | Accepted; `InsufficientShares` | `edge/PoolEdges.t.sol: test_E_P01_…` | proven |
| E-P-02 | Withdraw request at bellWindowAt − 1 s and at bellWindowAt | Tonight's epoch; the next epoch (ADR-0110) | `test_E_P02_…` | proven |
| E-P-03 | Claims before settlement; claims twice | `EpochNotSettled`; `NothingToClaim` | `test_E_P03_…` | proven |
| E-P-04 | `settleEpoch` at reopenAt + delay − 1 s and at + delay | `EpochNotReady(e, 1)`; settles | `test_E_P04_…` | proven |
| E-P-05 | Unsettled epoch at the next Bell | See E-B-09 | `test_E_P05_…` | proven |
| E-P-06 | 1-unit deposits in and out of an epoch | Mint > 0 shares; queued, then shares at settlement | `test_E_P06_…` | proven |
| E-P-07 | Withdraw queue with a cash shortage; > 64 withdrawal epochs | Partial pay, FIFO across epochs; the head advances (QA-07) | `security/PoolFindings.t.sol: test_QA07_fifoBeyondSixtyFourWithdrawalEpochs`, `unit/UnderwriterPool.t.sol: test_payShortfallIsBoundedByFreeCash` | proven (within one epoch it is first come, first served: by design) |
| E-P-08 | Capacity exhausted; concentration > 35 % on one asset | `CapacityExceeded`; `ConcentrationExceeded` (§15.1, ADR-0112) | `unit/UnderwriterPool.t.sol: test_capacityExceededReverts`; `unit/ConcentrationLimit.t.sol`; `security/Concentration.t.sol` | proven |
| E-P-09 | A REOPEN lot still unsettled at settlement time | `EpochNotReady(e, 2)`; the loss reserve is held (R-11) | `unit/UnderwriterPoolEdges.t.sol: test_settlementPreconditions`; `unit/UnderwriterPool.t.sol: test_epochLifecycle` | proven |
| E-P-10 | A tip that cannot be paid | Never blocks the job | `unit/UnderwriterPoolEdges.t.sol: test_aTipThatCannotBePaidDoesNotBlock` | proven |
| E-P-11 | Calendar coverage runs out | Pool epoch calls revert `NoCalendarCoverage`; the clock HALTs (fail closed); ops alert `programTimeLeft` / calendar coverage | `unit/AssetClock.t.sol: test_calendarStates`; `edge/ClockEdges.t.sol: test_E_C04_…` | partly (no pool-side test of `NoCalendarCoverage`; low risk, the clock HALTs first) |

### 1.6 Senior vault

| ID | Trigger | Expected (ref.) | Test | Status |
| --- | --- | --- | --- | --- |
| E-V-01 | Withdraw exactly `maxWithdraw`, and 1 unit more, with a market fully borrowed | Pays; `ERC4626ExceededMaxWithdraw` (no partial pay) | `edge/VaultEdges.t.sol: test_E_V01_…` | proven |
| E-V-02 | A head redeem request larger than the liquidity, a small one behind it | Strict FIFO: both wait, both go once liquidity returns (R-17) | `test_E_V02_…` | proven |
| E-V-03 | Claim: unknown id, stranger, receiver, twice; `processQueue(0)` | `RequestNotFound`, `NotRequestOwner`, receiver OK, `RequestAlreadyClaimed`; no-op | `test_E_V03_…` | proven |
| E-V-04 | The 33rd market; a market "removed" with cap 0 | `QueueTooLong` at 33 while the market lists 64; no slot is ever freed | `test_E_V04_QA11_…` | **pinned QA-11** (Low; design REQUEST to BE-chain / PM) |
| E-V-05 | First depositor / donation / 1-wei deposits | Dead + virtual shares; the attacker loses (§15.1) | `fuzz/InflationFuzz.t.sol`; `unit/CredenceMarketPaths.t.sol: test_firstDepositTooSmall`; `security/MarketFindings.t.sol: test_QA05_*` | proven |

### 1.7 Clock and calendar (real XNYS calendar)

| ID | Trigger | Expected (ref.) | Test | Status |
| --- | --- | --- | --- | --- |
| E-C-01 | DST ends (Fri 2026-10-30 → Mon 11-02) | 13:30 UTC is pre-market; opens 14:30 UTC to the second; Bell window 19:00 UTC; weekend = 3 days | `edge/ClockEdges.t.sol: test_E_C01_…` | proven |
| E-C-02 | DST starts (Fri 2027-03-12 → Mon 03-15) | Opens 13:30 UTC; Bell 19:45 UTC | `test_E_C02_…` | proven |
| E-C-03 | Thanksgiving: holiday Thursday, early close Friday 13:00 ET | HOLIDAY_WEEKEND closure (2 days); Thursday CLOSED; Friday Bell 17:45 UTC, none at the usual time | `test_E_C03_…`; `scenario/ClockWeek.t.sol: test_thanksgivingWeek` | proven |
| E-C-04 | Good Friday (4-day closure, R-07) | One closure; REOPEN Monday | `scenario/ClockWeek.t.sol: test_goodFridayWeek` | proven |
| E-C-05 | Calendar coverage runs out | Open-ended closure (`closureDays` reverts), no Bell; poke → HALTED | `test_E_C04_…`; `unit/AssetClock.t.sol: test_calendarStates`, `test_bellAndWindows` | proven |
| E-C-06 | Exact state boundaries (extOpen, open, close, extClose) | EXTENDED / REGULAR / EXTENDED / CLOSED at the second | `unit/AssetClock.t.sol: test_calendarStates` | proven |
| E-C-07 | Missed pokes over several closes | Every close is processed | `unit/AssetClock.t.sol: test_missedPokesProcessEveryClose` | proven |
| E-C-08 | Sequencer gap (R-20) | Phase extended | `unit/AssetClock.t.sol: test_sequencerGapExtendsPhase`; `unit/SequencerHealth.t.sol` | proven |
| E-C-09 | Open print missing at the open; TWAP fallback after 15 min | REOPEN waits, then the fallback | `unit/OracleAdapter.t.sol: test_openPrintFallback`, `test_openPrintAfterHalt` | proven |
| E-C-10 | Missing reference close | HALT (fail closed) | `unit/AssetClock.t.sol: test_missingReferenceHalts` | proven |
| E-C-11 | Gas-starved poke | Reverts instead of HALTing | `unit/AssetClock.t.sol: test_gasStarvedPokeRevertsInsteadOfHalting` | proven |
| E-C-12 | Corporate action / stock split | CORP_ACTION; `sharesPerToken` change bounded | `unit/AssetClock.t.sol: test_corporateAction`; `unit/OracleAdapter.t.sol: test_setSharesPerToken`; `unit/TestAssets.t.sol: test_stockRatioFreezeCompliance` | proven |

### 1.8 Oracle

| ID | Trigger | Expected (ref.) | Test | Status |
| --- | --- | --- | --- | --- |
| E-O-01 | Feeds disagree by exactly 1.5 % / 1.5 % + 1 wei; exactly 5 % / 5 % + 1 wei | Agreement / borrowing paused; not severe / severe (HALT while open) | `edge/OracleEdges.t.sol: test_E_O01_…` | proven |
| E-O-02 | A print exactly 60 s / 61 s old (REGULAR), 300 s / 301 s (EXTENDED) | Fresh / stale | `test_E_O02_…` | proven |
| E-O-03 | One vendor (feed) down: the secondary silent; the primary silent | Not stale but no cross-check → borrowing paused; primary silent → stale → HALT | `test_E_O03_…` | proven |
| E-O-04 | observedAt = now + 5 s / + 6 s; zero price; replayed seq; seq step 2^32 / 2^32 + 1 | Accepted / `ReportFromFuture`; `ZeroPrice`; `StaleReport`; accepted / `SeqStepTooLarge` | `test_E_O04_…` | proven |
| E-O-05 | One vendor prints an outlier (× 10) | Severe disagreement; the valuation does not jump to it | `test_E_O05_…` | proven |
| E-O-06 | The **primary** off by 1.5–5 % (not severe) | Borrowing paused, but liquidation still values at the primary | — | pinned by design (liquidations continue; reserve (1 − κ)·V and bidders bound the price); listed for the audit in `pre-mainnet.md` |
| E-O-07 | 1 of 3 signatures; unsorted or duplicate signers; wrong domain | Refused | `unit/CredencePriceFeed.t.sol: test_rejects1of3`, `test_rejectsUnsortedAndDuplicate`, `test_rejectsWrongDomainAndGarbage` | proven |
| E-O-08 | An out-of-order live print | Seq advances, price not stored | `unit/CredencePriceFeed.t.sol: test_liveOrderingAndRegular` | proven |
| E-O-09 | NAV: normal weekend, holiday weekend, one or two missed strikes | Fresh / stale (CLOSED) / invalid (HALTED) (R-23) | `scenario/NavStaleness.t.sol` (4 tests) | proven |

### 1.9 NAV settlement

| ID | Trigger | Expected (ref.) | Test | Status |
| --- | --- | --- | --- | --- |
| E-S-01 | A solver bid in the last second; finalize 1 s early; finalize twice | Accepted; `TooEarly`; `SettlementNotOpen` | `edge/SettlementEdges.t.sol: test_E_S01_…` | proven |
| E-S-02 | Two solvers at the same price in one block | The incumbent stays (minimum increment) | `test_E_S02_…`; `unit/NavSettlement.t.sol: test_bid_rules_andOutbidRefund` | proven |
| E-S-03 | 129 positions in one `openSettlement` | `TooManyPositions` (the keeper splits) | `test_E_S03_…` | proven |
| E-S-04 | The same borrower twice in one call | Settled once | `test_E_S04_…` | proven |
| E-S-05 | No bid (pool advance); `RedemptionsGated` (retry); the winner lost its allowlist; the pool short of cash | Advance at the floor; revert until ungated; falls back to the pool; pays what it has | `unit/NavSettlement.t.sol: test_finalize_noBid_*`, `test_finalize_winnerLostAllowlist_*`, `test_finalize_poolShortOfCash_*` | proven |
| E-S-06 | A blocklisted solver's refund | Credited, withdrawn later | `unit/SolverAuctionRefund.t.sol` | proven |
| E-S-07 | Settlement while HALTED / CLOSED / CORP_ACTION | Refused; repay stays open | `unit/NavSettlement.t.sol: test_open_whenHalted_*`, `test_open_whenClosedOrCorpAction_reverts` | proven |
| E-S-08 | T+1 claim delayed by a holiday | Claim at the next USBANK strike | `scenario/NavSettlementScenario.t.sol`; `scenario/NavStaleness.t.sol: test_holidayWeekend` | partly (the holiday delay is not asserted on the claim itself) |

### 1.10 Cross-cutting

| ID | Trigger | Expected (ref.) | Test | Status |
| --- | --- | --- | --- | --- |
| E-X-01 | Reentrancy through a hooked collateral / loan token into every money function | Guarded (§15.1) | `security/Reentrancy.t.sol`, `security/SettlementReentrancy.t.sol` (`docs/security/reentrancy.md`) | proven |
| E-X-02 | Every dependency reverting (clock, oracle, engine) during repay / add collateral | A borrower can always repay and add collateral | `unit/CredenceMarket.t.sol: test_repayAndAddCollateralWithEverythingReverting` | proven |
| E-X-03 | Guardian: pause, haircut only upward, delayed unpause, halt / extend | As §15.1 | `unit/Governance.t.sol` | proven |

## 2. Off-chain (owner BE-backend; `make backend-edge`)

"Reviewed" means QA-sec read the test and confirmed that it triggers the case.

### 2.1 Relayer

| ID | Trigger | Expected | Test | Status |
| --- | --- | --- | --- | --- |
| R-01 | 1 of 3 signer nodes down | Still signs (threshold 2) | `relayer/src/ocr.rs: edge_one_of_three_nodes_down_still_reports` | proven (reviewed) |
| R-02 | 2 of 3 nodes down | No report → the feed goes stale → HALT (fail closed) | `edge_two_of_three_nodes_down_publish_nothing_fail_closed`; on-chain E-O-02/03 | proven (reviewed) |
| R-03 | Outlier node / vendor price | Median used; the outlier node refuses | `edge_an_outlier_node_is_outvoted_and_refuses_the_median` | proven (reviewed) |
| R-04 | Zero or stale price | Never signed | `edge_zero_and_stale_prices_are_never_signed` | proven (reviewed) |
| R-05 | One vendor down (for the whole feed, not one node) | That feed stops; on-chain borrowing paused (E-O-03) | `edge_one_vendor_down_on_one_node_…` covers a single node only | **partly → gap**: a test where vendor B is down for every node, so feed B publishes nothing and feed A keeps going |
| R-06 | Both vendors down | Nothing published → HALT | — | **gap** |
| R-07 | Feed disagreement > 1.5 % and > 5 % seen by the relayer | Both published as-is (the chain decides) | — | **gap** (the chain side is E-O-01) |
| R-08 | A submission not mined; an RPC outage | Retried with the same seq (node re-signs the same seq, OFF-01); no seq gap | `off01_seq_window` (seq rule only) | **gap** (the retry path itself) |
| R-09 | Open print missing, then the TWAP fallback after 15 min | The relayer keeps LIVE; the chain falls back (E-C-09) | — | **gap** (relayer side) |
| R-10 | Holiday, early close and DST days | Status and session dates right on those days | `halt_merge_fails_closed`, `status_fails_closed`, `unknown_codes_fail_closed` (status mapping) | **partly** (no calendar-day test in the relayer; the keeper side is K-01) |
| R-11 | Stock split (`sharesPerToken`) | Price per token, not per share, after the ratio change | — | **gap** |
| R-12 | seq window, node token (OFF-01/02) | As fixed | `off01_seq_window`, `off02_node_token_required_off_dev_chains` | proven (reviewed) |

### 2.2 Keeper

| ID | Trigger | Expected | Test | Status |
| --- | --- | --- | --- | --- |
| K-01 | DST switch; holiday; early close | Every boundary moves; the Bell follows the early close | `keeper/src/schedule.rs: edge_dst_switch_moves_every_boundary_by_one_hour`, `edge_holiday_has_no_session_and_the_early_close_moves_the_bell` | proven (reviewed) |
| K-02 | Killed and restarted between **every pair of steps** of J3, J5, J9, J10, J11 | Resumes exactly; no duplicate tx | `keeper_e2e.rs: killed_mid_job_restart_resumes_without_duplicates` covers **J1 (poke) only** | **gap** (J3, J5, J9, J10, J11) |
| K-03 | Two instances, leader failover | No duplicates | `keeper_e2e.rs: leader_failover_no_duplicates` | proven (reviewed) |
| K-04 | Stuck tx; gas spike | Replaced at +20 % every 3 blocks; waits at the cap | `keeper_e2e.rs: stuck_tx_is_replaced_after_3_blocks_at_plus_20_percent`; `tx.rs: off09_replacement_fees_stop_at_the_cap` | proven (reviewed) |
| K-05 | RPC error mid-batch | The batch is retried; nothing done twice | — | **gap** |
| K-06 | A position repaid / closed between the pre-check and the tx | The tx is a no-op (the chain skips it, E-B-04 / E-L-01); the keeper does not retry forever | — | **gap** |
| K-07 | Bell with 0 positions; 35+ NEEDS_ACTION positions (4+ J3 txs in 15 min) | Nothing sent; every batch inside the deadline, and **no pre-close candidate in a batch after close − 5 min (QA-10)** | — | **gap** |
| K-08 | Lot over 128 positions (tranches) | Every tranche fixed and cleared | — | **gap** (chain side E-L-03) |
| K-09 | Auction: no bids, no reveals, partial fills | Cleared on schedule | — | **gap** (chain side E-A-05..07) |
| K-10 | Pool capacity exhausted; withdraw queue short of cash; GDA unsold at the next closure | Bell falls back to the sale; claims retried; `closeResale` / relist | — | **gap** |
| K-11 | NAV: solver fill, no bid, `RedemptionsGated`, solver voided, holiday T+1 | J10 finishes each path | `keeper/src/nav_jobs.rs: finalize_only_after_the_window`, `a_solver_fill_is_finished_an_advance_waits_for_the_redemption`, `open_takes_hf_below_one_not_in_a_lot_in_batches` | **partly** (gated retry, voided solver and the holiday are missing) |
| K-12 | Sequencer gap (R-20) | Deadlines move by the phase extension | `core.rs: edge_sequencer_gap_extends_the_reopen_window_before_the_stuck_alert` (alert gauge only) | **partly** (the jobs' own deadlines are not tested) |
| K-13 | HALTED mid-cycle | Jobs stop; nothing reverts in a loop | same test (gauge only) | **partly** |
| K-14 | Calendar coverage running out | Alert before it runs out; the keeper does not spin | `unpriced_markets_are_logged_once_per_change` (a different case) | **gap** |
| K-15 | Unpriced market (NoReferencePrice) | Logged once per change | `core_jobs.rs: unpriced_markets_are_logged_once_per_change` | proven (reviewed) |
| K-16 | Epoch unsettled at the next Bell (E-B-09) | `EpochNotSettled` alert fires before the next Bell window | alert rule test (`alerts.test.yml`) | partly (the rule exists; no end-to-end check) |

### 2.3 Indexer

| ID | Trigger | Expected | Test | Status |
| --- | --- | --- | --- | --- |
| I-01 | A restart, and a full reindex | Identical tables | — (`indexer/test/book.test.ts` only) | **gap** |
| I-02 | An anvil reorg | Rolled back and re-applied | — | **gap** |
| I-03 | Several contracts' events in one block (e.g. clear → onAuctionCleared → backstopBuy) | All projected, in log order | — | **gap** |
| I-04 | NAV and equity lot ids collide | Keyed by (contract, id, owner) | `da70569` fix; API `test/settlement.test.ts` | proven |

### 2.4 API and WebSocket

| ID | Trigger | Expected | Test | Status |
| --- | --- | --- | --- | --- |
| W-01 | Pagination: page size 1, an exact multiple, larger than the set; empty; cursor past the end | Every row exactly once; empty page, no cursor | `api/test/edge.edge.test.ts` | proven (reviewed) |
| W-02 | Invalid inputs; unknown ids | 400 / 404 with JSON | same | proven (reviewed) |
| W-03 | uint256-max values | Exact decimal strings | same | proven (reviewed) |
| W-04 | WS disconnect and reconnect; session expiry | Resubscribe; an expired session loses the owner channel | `test/stream-origin.test.ts` (Origin and size only) | **gap** |
| W-05 | Rate limits behind a proxy (OFF-03) | Right-most untrusted hop | `test/ratelimit.test.ts` | proven |

### 2.5 Notifier

| ID | Trigger | Expected | Test | Status |
| --- | --- | --- | --- | --- |
| N-01 | Telegram 429; 403; 5xx | Transient with retry_after; permanent; transient | `notifier/test/edge.edge.test.ts` | proven (reviewed) |
| N-02 | A user with no channel | Skipped, never retried | same | proven (reviewed) |
| N-03 | 1 base unit and the maximum amount | Exact rendering | same | proven (reviewed) |
| N-04 | A channel down → retry → dead-letter | Dead-lettered after N attempts | `pnpm --filter @credence/notifier e2e` (infra half) | partly (QA-sec did not find an explicit dead-letter assertion; to confirm) |
| N-05 | A duplicate event | One message | — | **gap** |

### 2.6 Infrastructure

| ID | Trigger | Expected | Test | Status |
| --- | --- | --- | --- | --- |
| D-01 | Postgres restart mid-cycle | Keeper, indexer, API and notifier reconnect; no job lost or duplicated | — | **gap** |

## 3. Findings from the matrix

| ID | Sev. | Finding | Owner | Status |
| --- | --- | --- | --- | --- |
| QA-10 | Medium | A Bell batch sent after the PRECLOSE fixing (close − 5 min) reverts entirely if one position needs a pre-close sale, so every auto-cover in it is lost; the J3 ops page and the RB-01 manual run land exactly then | BE-chain (+ PM ruling 22:00) | **FIXED** `1e07b99` (ADR-0115), verified |
| QA-11 | Low | The senior vault's market list is append-only and capped at 32, while the market lists 64; a market never leaves it | BE-chain / PM | REQUEST (this commit) |
| OFF-GAPS | — | Off-chain rows marked gap / partly above | BE-backend | REQUEST (this commit) |
