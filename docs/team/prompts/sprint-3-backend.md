# Sprint 3 brief · Senior Backend Engineer (BE-backend)

From: PM · Repo: `/home/asus/Project/credence-finance` · Target: local only (nitro-devnode / anvil). **No testnet deploy.**

## Context

Sprint 2 is **accepted with one carry-over**. Read `docs/handoff/sprint-2-pm-review.md` for the PM's independent re-run and the rulings on your spec issues and on ADR-0009. The carry-over is your acceptance 4 at market level. The PM re-ran `make api-bell-e2e` on the devnode at 18:2x, and it fails with `reverted: poke`: the devnode book's real calendar starts 2026-10-01. BE-chain's S3 item A1 (`make local-deploy-core CALENDAR=synthetic`) fixes that. Re-run it as soon as they post the READY.

S3 is **risk transfer**. BE-chain builds the real UnderwriterPool and AuctionHouse. You make the keeper drive the whole closure cycle by itself, index and serve pools and auctions, and finish the notifier. Two engineers run this sprint: **you and BE-chain**.

## Read first
1. `docs/team/TEAM_CHARTER.md` (§2, §2a).
2. `docs/handoff/sprint-2-pm-review.md`.
3. `docs/team/prompts/sprint-3-blockchain.md`: what BE-chain delivers, in which order. **Start with the items that need no new ABI**, and switch to the pool/auction work when their READY A2 lands.
4. `docs/CREDENCE_BUILD_GUIDE.md`: §8.6, §8.7 (what you drive), §10.2 (J3, J5, J6, J8, J9, J11 and the operational rules), §10.3, §10.4, §10.5, §11.
5. `docs/handoff/BOARD.md` from `2026-09-28 14:47` on.

## Sprint goal
On the devnode, with no human in the loop, the keeper runs scenario A from the Friday Bell through the Monday REOPEN auction to epoch settlement. The indexer and the API show every step, and the notifier sends every message in §10.5 with exact amounts.

## Work items

### A. S2 carry-over and clean-ups (first; no new ABI needed)
1. **Acceptance 4, market level:** after BE-chain's READY A1, run `make api-bell-e2e` on the devnode (100 positions, `/bell` == `CredenceMarket.bellStatus` and `engine.quoteCover`), and post an ANSWER with the output.
2. The keeper uses `crates/credence-bindings` instead of its own `sol!` (`core.rs::abi`). J7 reads `IRiskEngine.sigmaAt` instead of the `SigmaUpdated` logs. `keeper-j7-e2e` uses the exported `ISigmaOracle` v1 ABI (drop the local declaration).
3. **Keeper operational rules from §10.2, if any are missing:** a single-sender nonce manager, `eth_estimateGas × 1.3`, stuck-tx replacement after 3 blocks at +20% priority fee, and a restart that resumes from `keeper_jobs` / `keeper_txs`. Prove it with a test that kills the keeper mid-job.
4. The ADR-0009 D1 ruling is accepted for testnet (see the review). Implement the RedStone print derivation in the relayer as a **mode**, `PRINT_SOURCE=redstone`: OPEN = the first package at or after `open + 5 s` that differs from the prior close, CLOSE = the last package before `close + 60 s`, flagged `OracleFirstRegular`. Run it against recorded RedStone packages, and add a replay fixture. When BE-chain posts `RedStonePriceSource`, submit the payloads on the devnode. Before then, off-chain only.

### B. Keeper: the closure cycle (after BE-chain's READY A2)
- **J3 live** (not dry-run) on the devnode. Size batches from BE-chain's posted 24M-gas maximum.
- **J4 live**: flags via `flagForAuction`.
- **J5 Reopen driver:** on the open print, flag every HF < 1 position within 2 min, then `fixLots` at +2:00, `clear` at +7:00, `settlePositions`, and `settleEpoch`. Idempotency key `(asset, closureId, step)`, and it must survive a restart between any two steps.
- **J6 Batch driver:** `fixLots` / `clear` on schedule for INTRADAY, EMERGENCY and PRECLOSE auctions.
- **J9 Epoch lifecycle:** `openEpoch` at the venue's Bell window, `snapshotEpoch` at the Bell deadline, and `settleEpoch` when `allReopenLotsSettled`.
- **J11 GDA:** start the resale when backstop inventory > 0.
- **J8** extended with the pool's `claimDeposit` / `claimWithdraw` helpers.
- Every job pre-checks with risk-core natively, so a failed tx counts as a bug. Count failed txs in a metric, and alert if it is non-zero.
- A **test bidder bot** (dev tool under `services/`) that commits, reveals and places bids from a config, so e2e auctions clear without a human.

### C. Indexer (pure projections again)
BE-chain adds the missing events (`AutoCoverApplied`, `PositionSettled` and the pool/auction events). Wherever an event now carries the data, replace the ADR-0011 state reads with projections, and update ADR-0011. New tables per §11.1: `pool`, `epoch`, `policy`, `auction`, `lot`, `bid`, `gda`, and backstop inventory.

### D. API and WS
- `GET /v1/pool/:stack`, `/v1/pool/:stack/epochs?cursor=`, `/v1/auctions?status=&kind=&asset=`, `/v1/auctions/:auctionId`, `/v1/risk` (the Architecture §3.9 transparency list).
- WS channels `auctions` and `bell:<owner>` (SIWE-authenticated).
- `/bell`'s premium now comes from the **real pool** `previewCover` with the real `epochId` (it replaces `epochId: 0`). The equality check covers the market's `bellStatus` premium again, not only `engine.quoteCover`.
- `/v1/vault/:stack` fills `cushion` = (pool + reserve) ÷ borrows.
- OpenAPI updated, and zod on every input.

### E. Notifier: every §10.5 event
Auto-cover applied or pre-close sale executed, queued at reopen (with the countdown), auction settled, epoch settled, and withdrawal claimable, each triggered from the new indexer rows. Telegram is the third channel next to email and push; check it exists, and add it if it is missing. Every message carries exact amounts, and `notification_log` has retries and dead-letters.

### F. End-to-end
`make scenario-a-e2e` on the devnode, on BE-chain's synthetic-calendar deploy with real pool and auction house. Borrowers and underwriters are seeded, then **only the keeper, the relayer (replay vendor) and the bidder bot act**. The run: Friday J2 heads-ups → J3 Bell with auto-cover → the weekend closure → the Monday open print → J5 REOPEN auction cleared by the bot → settlement → J9 `settleEpoch`. After it, check that the indexer and API figures match the chain, and that every expected notification is in `notification_log` with the Appendix A amounts.

## Out of scope
NAV settlement jobs J10 (S4), the full recorded-weekend run (S4), production deploy, KMS and RPC failover (S5), and the web app (the Frontend role, planned).

## Acceptance criteria
1. `make backend-install backend-build backend-test backend-lint` passes from a clean clone, and every e2e target passes with `make infra-up db-migrate`.
2. `make api-bell-e2e` passes on the devnode (S2 carry-over), with the ANSWER posted.
3. `make scenario-a-e2e` passes on the devnode with no manual transaction after seeding, and the keeper sends 0 failed txs.
4. Keeper restart test: kill the keeper between J5 `fixLots` and `clear`. The follower or the restart completes the cycle with no duplicate tx.
5. The indexer serves pools, epochs, policies, auctions, bids and GDA from events. The API endpoints in D answer with figures equal to the chain at the same block (checked in the e2e).
6. The notifier e2e covers every §10.5 event with exact amounts.
7. The report is at `docs/handoff/sprint-3-backend-report.md` (template), with ADRs for every deviation.

## Rules
The charter applies in full: your paths only, stage only your paths, the §2a rules, and `CARGO_TARGET_DIR=target/be`. You own the devnode, so post before any `infra-down` or `infra-reset`. BE-chain rewrites the devnode book in A1, so re-read it after their READY. Post BLOCKED for anything only the user can provide. When done, tell the user: "Sprint 3 backend done. Report: docs/handoff/sprint-3-backend-report.md".
