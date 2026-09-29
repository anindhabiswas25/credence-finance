# ADR-0115 · BE-chain · QA-10: a late Bell batch skips the pre-close sale instead of reverting

Status: accepted (S4, PM ruling 2026-09-29 22:00) · Date: 2026-09-29

## Context
§8.4.3 runs `enforceBell` in `[bellAt, closeAt)` and says the Bell skips rather than reverts. The PRECLOSE lot fixes at
`close − timings[PRECLOSE][0]` (5 min); after that `AuctionHouse.getOrCreate` reverts `TooLate`. So between
`close − 5 min` and the close, one borrower who needs a pre-close sale (auto-cover off or paused, above maxLtv + δ, or
an auto-cover that failed) reverted the whole batch, and every auto-cover in it was lost (QA-10, Medium). J3 pages ops
at `bellAt + 10 min` = `close − 5 min`, so the RB-01 manual `keeper enforce` hit it every time.

## Decision
- `CoverLogic._cure` first tries the auto-cover when the position is coverable (unchanged). Every remaining cure needs
  the PRECLOSE lot, so it then checks the auction house's own rule, `nextCloseAt == 0 || now + timings[PRECLOSE][0] ≥
  nextCloseAt`, through the public `timings` getter (no ABI change on the auction house). Past the fixing it returns the
  new outcome **`BellOutcome.SALE_TOO_LATE = 5`**.
- `enforceBell` emits `BellEnforced(…, SALE_TOO_LATE)` for that borrower, does **not** set `lastBellClosureId` and pays
  **no tip**, then goes on with the batch. The position is not marked, so it stays a Bell candidate (for the next
  closure) and a flag candidate at the open. No tip also means a keeper cannot farm tips by re-sending the skip.
- An above-coverable position with auto-cover on is not covered without its sale either (R-03 sells to maxLtv first),
  so it gets `SALE_TOO_LATE` too.
- The NAV stack has no auction house (`w.auctionHouse == 0`; its lots exist only inside `openSettlement`), so its
  Bell behaviour is unchanged.

## Consequences
- `BellEnforced.outcome` gains the value 5 (additive; the event's type is `uint8`). The indexer / notifier should map
  it (board ANSWER to QA-10).
- BE-backend's J3 guard (no pre-close candidates after `close − 5 min`) stays as defence in depth.
- Known limit: if governance changes `timings[PRECLOSE]` after a closure's lot was created, the recomputed fixing can
  differ from that lot's stored deadline, and a join could still revert `TooLate`. `setTimings` is timelocked; noted
  for the pre-mainnet audit.
- Tests: `BellBatchTest.test_lateBatchSkipsTheSaleAndKeepsTheCovers`, `test_batchJustBeforeFixingStillSells`; QA-sec's
  `test_E_M12_QA10_lateBellBatchStillAutoCovers` and `test_E_M12b_…` pass.
