# Sprint 3 brief · Senior Blockchain Engineer (BE-chain)

From: PM · Repo: `/home/asus/Project/credence-finance` · Target: local only (nitro-devnode / anvil). **No testnet deploy.**

## Context

Sprint 2 is **accepted with one carry-over**. Read `docs/handoff/sprint-2-pm-review.md` for the PM's independent re-run and a ruling on every spec issue (gas ceilings, Appendix A at projected debt, INV-COV-01 wording, ADR-0009 D1). The carry-over is the market-level half of BE-backend's acceptance 4: `make api-bell-e2e` reverts on `poke` on the devnode, because the book's calendar starts 2026-10-01 and the devnode clock is 2026-09-28. Your item A1 unblocks it.

S3 is **risk transfer**: the real UnderwriterPool and AuctionHouse replace the S2 mocks, and the market's Bell, cover and liquidation paths run end to end against them. Two engineers run this sprint, **you and BE-backend**, and BE-backend depends on your early items.

## Read first
1. `docs/team/TEAM_CHARTER.md` (§2, §2a).
2. `docs/handoff/sprint-2-pm-review.md`.
3. `docs/CREDENCE_BUILD_GUIDE.md`: §2 (R-01..R-26), §8.4 (the cover and liquidation rules), **§8.6 UnderwriterPool**, **§8.7 AuctionHouse**, §8.9.3 (gas), §9.4–9.6, §14.2 (INV-POOL, INV-AH), Appendix A.
4. `docs/handoff/BOARD.md` from `2026-09-28 13:10` on (the RedStone REQUEST, the missing-events note).
5. Your own ADR-0107 §7 (the auction house must treat an empty lot as settled) and ADR-0108 §5 (gas).

## Sprint goal
Build the real UnderwriterPool and AuctionHouse, wire them into both stacks in place of the mocks, and prove the whole closure cycle on-chain: Bell → cover → closure → reopen → REOPEN auction → settlement → epoch settlement. Test it to the S2 bar.

## Work items

### A. Early deliverables for BE-backend (first ~25% of the session, in this order; post a `READY` for each)
1. **A pokeable devnode core today (S2 carry-over).** Add `CALENDAR=synthetic` to `make local-deploy-core`. It writes an XNYS + USBANK calendar centred on the chain's current time: REGULAR now, then a WEEKEND closure, plus at least 10 sessions after it. Use the same generator as `devnode_integration.sh`. It deploys into the **main** book `deployments/412346.local.json` and loads QE's bundle through `make risk-load-set`. Post a DECISION before it rewrites the book, run it on the devnode, then post a READY, so BE-backend can re-run `make api-bell-e2e`. The default (real calendar) stays unchanged.
2. **Interfaces for S3, additive over v1.** `IUnderwriterPool`, `IAuctionHouse` and the events below. If any change is breaking, put it in `deployments/abis/v2/` with an ADR; otherwise re-export v1, and `make abis-check` must pass. **Add the missing events** (BE-backend S2 spec issue, PM ruling: accepted): `AutoCoverApplied(marketId, borrower, closureId, premium, debtAfter)`, `PositionSettled(marketId, borrower, auctionId, collateralSold, proceeds, penalty, shortfall, debtAfter)`, and pool/auction events for each state change the indexer needs (`EpochOpened`, `EpochSnapshotted`, `EpochSettled`, `CoverWritten`, `DepositQueued`, `WithdrawRequested`, `BackstopBought`, `LotsFixed`, `BidCommitted`, `BidRevealed`, `BidPlaced`, `AuctionCleared`, `Claimed`, `GdaStarted`, `GdaBought`). The goal: indexer handlers become pure projections again (Guide §10.3).
3. **`credence-bindings`** regenerated with the pool and the auction house. The address book still carries `pool` / `auctionHouse`; drop the S1 flat keys now (BE-backend no longer reads them).

### B. UnderwriterPool (§8.6), both stacks (`cfUP-EQ`, `cfUP-NAV`)
- Epochs per venue closure (R-10, R-11): `openEpoch`, `snapshotEpoch`, `settleEpoch` with every precondition in §8.6.3, `pendingLossReserve` for still-HALTED assets.
- NAV exactly as in §8.6.1: unearned premiums, risk-fee receivable, backstop inventory at `min(cost, V × (1 − κ))`, queued deposits, reserved withdrawals.
- Deposits queued during an open epoch (`claimDeposit`); withdrawals requested before the Bell window, burned at `sharePriceAfter`, paid FIFO (`claimWithdraw`).
- `previewCover` / `writeCover` through the engine: the premium comes from `quoteCover`, and capacity comes from `poolCapacity`.
- **Gas ruling (see the review):** store the epoch's **aggregate** K-loss vector and add each new policy's `coverLossVector` to it, so `writeCover` costs one `coverLossVector` plus one capacity check. It must not recompute every market. Measure it.
- `payShortfall`, `creditRiskFee`, `creditPenalty`, `creditBond`, `backstopBuy`, and GDA hand-off to the auction house. `fallbackAdvance` is **S4** (NAV settlement); in S3 it reverts with a named error.
- Tipped, permissionless lifecycle calls (KeeperTips).

### C. AuctionHouse (§8.7)
- All four kinds, with the §8.7.1 timings, all timelock-configurable: REOPEN (sealed commit–reveal, 10% bond, R-04), INTRADAY, EMERGENCY and PRECLOSE (open, firm bids).
- Lots up to 256 positions, and **tranches** beyond that. At most 64 bids per auction, with a $100 minimum notional on testnet.
- Clearing through `engine.clear` (uniform price p*, pro rata at p*, R-05). `qPool` goes to `pool.backstopBuy` at R. Unrevealed bonds go to `pool.creditBond`. Then `market.onAuctionCleared`, and `clock.markReopenComplete` after the last REOPEN tranche.
- `ICompliance.canHold` checked before any bid is accepted (R-02).
- An empty lot (it released 0) counts as settled (ADR-0107 §7). `allReopenLotsSettled(venue, epoch)`.
- GDA resale of backstop inventory: `startGda` (onlyPool), `gdaBuy`, `gdaPrice`.

### D. Wiring and deploy
- `DeployCoreLocal` deploys the real pool and auction house for the equity stack, and the real pool for the NAV stack (its settlement adapter stays the mock until S4). The mocks remain for unit tests only.
- **Gas-bounded Bell batches:** measure `enforceBell` with the real pool when every borrower in the batch gets auto-cover. Publish the largest batch that fits in 24M gas on the board, because the keeper's J3 batch size is set from it. Also measure `flagForAuction`, `fixLots`, `clear` and `settlePositions` at their maximum sizes.
- `RedStonePriceSource : IPriceSource` (BE-backend REQUEST 13:10). Build it **clean-room** from the documented payload format: do not copy the BUSL connector code. The rules: 3-of-5 signers, a 180 s delay window, a 60 s ahead window, the median, 8-decimal → WAD. Use `packages/feeds/src/redstone.ts` and its fixture as the byte-layout reference. It is deployable locally only; public use is still gated on the user's ADR-0009 D3. Lower priority than B–D and E.

### E. Tests
- Unit and fuzz tests for the pool and the auction house.
- Invariant suites at 256 × 128: **INV-POOL-01, INV-POOL-02, INV-AH-01..04**, plus the S2 suites still passing with the real pool (not the mock). Handler actors add underwriters and bidders (honest, low-ball, non-revealing).
- Scenario test: **scenario A through the following Monday.** Friday Bell (auto-cover through the real pool), the weekend closure, the Monday open print, the REOPEN auction (commit, reveal, clear at p*), `settlePositions`, and `settleEpoch`. Every Appendix A figure must match to the cent, at projected debt per the R-08 ruling. Add one gap-loss variant in which the pool pays a shortfall and the backstop buys `qPool`.
- The devnode integration (`make devnode-integration`) extended to a real `writeCover` and a real auction `clear` through the Stylus engine.
- Coverage ≥ 95% of lines on the new pool and auction directories, and the four S2 directories still ≥ 95%.

## Out of scope
SettlementAdapter, SolverAuction and `fallbackAdvance` (S4); NAV scenario B (S4); testnet deploy scripts (S5).

## Acceptance criteria
1. `make contracts-build contracts-test risk-test contracts-coverage abis-check` passes from a clean clone (≥ 95% on the S2 directories plus pool and auction).
2. A1–A3 are delivered, each with a READY before the main build work. After A1, BE-backend's `make api-bell-e2e` passes on the devnode (their ANSWER on the board).
3. INV-POOL-01/02 and INV-AH-01..04 pass at 256 × 128, and the S2 invariants pass against the real pool.
4. Scenario A through Monday's REOPEN settlement and epoch settlement passes to the cent, and so does the gap-loss variant.
5. `DeployCoreLocal` deploys the real pool and auction house on the devnode against the Stylus router. `make devnode-integration` shows a real `writeCover` and a real `clear`.
6. Gas: `writeCover`, `enforceBell` (full batch), `clear` (64 bids) and `settlePositions` are measured and in the report. The maximum J3 batch within 24M gas is posted on the board.
7. The report is at `docs/handoff/sprint-3-blockchain-report.md` (template), with ADRs for every deviation.

## Rules
The charter applies in full: your paths only, stage only your paths, and the shared-machine rules in §2a. BE-backend runs at the same time, so post before touching the devnode book, and answer their REQUESTs promptly. When done, tell the user: "Sprint 3 blockchain done. Report: docs/handoff/sprint-3-blockchain-report.md".
