# ADR-0012 (BE-backend): scenario A end to end on the devnode

Status: accepted by BE-backend, flagged to the PM (S3 report, spec issues) · Date: 2026-09-29

## Context
S3 brief F asks for `make scenario-a-e2e` on the devnode (Stylus engine, real pool and auction house, synthetic
calendar), with only the keeper, the relayer (replay vendor) and the bidder bot acting after seeding, and every
notification checked "with the Appendix A amounts". Two facts make the Appendix A figures unreachable there:

1. **Time.** A nitro devnode cannot warp its clock, and `AssetClock.closureDays = ⌈(reopenAt − closeAt) / 1 day⌉`.
   A WEEKEND closure that fits in an e2e (minutes) is 1 day long for R-07/R-08, not 3, so projected debt and the
   premium's τ differ from Appendix A. The clock's Bell constants are fixed (window = close − 2 h, deadline =
   close − 15 min), so the Friday leg alone takes 2 h + seeding.
2. **Engine.** Appendix A's scenario rows are checked in BE-chain's forge scenario with premiums injected through
   `MockRiskEngine` at the doc's values (Appendix A note). On the devnode the Stylus engine prices with QE's
   calibrated sets, which the PM ruled binding (S2 review, QE #2/#3); safe LTVs and premiums therefore differ.

## Decision
- `scenario-a-e2e` reproduces scenario A's **shape** on the devnode: Priya-type auto-cover at the Bell, a Maya-type
  pre-close sale, a gap-down Monday open that puts positions under HF 1, the REOPEN auction cleared by the bidder
  bot (including a non-revealing bidder whose bond goes to the pool), settlement with a shortfall paid by the pool,
  and `settleEpoch`, all driven by the keeper alone.
- It uses a compressed synthetic calendar (BE-chain REQUEST 2026-09-29): today's close ≈ deploy + 2 h 20 min, a
  WEEKEND closure of ~15 min, then short sessions.
- **Amounts:** every notification in `notification_log` is checked against the chain's own values at the event
  (the `AutoCoverApplied` premium and debt, `PositionSettled`, `AuctionCleared` p*, `EpochSettled`), and the
  indexer/API figures against the chain at the same block. Cent-level Appendix A remains proven where its inputs
  are exact: BE-chain's forge scenario (S-A, S-B), and the notifier template tests on the Appendix A numbers
  (G-10, G-11, S-B's 156.02 / 4,578.38 / 9,998.82).
- Friday's T−26 h heads-up is outside a 2 h 20 min run; J2's T−26 h stage is covered by `keeper-core-e2e` on anvil.

## Consequences
- The PM should restate brief F's acceptance as "amounts equal to the chain and to the independent recomputation",
  with Appendix A covered by the forge scenario, or provide a warpable chain for the Stylus engine.
