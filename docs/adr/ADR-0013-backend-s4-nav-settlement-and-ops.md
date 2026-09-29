# ADR-0013 · BE-backend · S4: NAV settlement off-chain stack, Bell times from the chain, §16.1 alert inputs

Status: accepted (BE-backend, 2026-09-29) · Sprint 4 · Related: ADR-0006 (keeper execution), ADR-0011, ADR-0108
(risk engine split), ADR-0111 (BE-chain, NAV stack interfaces v3, draft)

## Context
Sprint 4 asks for J10 NAV settlement, a test solver bot, the settlement indexer/API, the NAV notifier messages
and every §16.1 alert. BE-chain's v3 interfaces (A1) and timing contract (A2) were still uncommitted work in
progress when this was built. The PM's log review also found three keeper issues (S4 A).

## Decisions
1. **Draft v3 bound locally until the ABIs are frozen.** The keeper (`nav_jobs.rs`), the solver bot and the
   indexer (`indexer/src/abis/settlement.ts`) bind the v3 surface they use by hand, copied from BE-chain's
   working tree (`ISettlementAdapter`, `ISolverAuction`, `IUnderwriterPool.claimRedemption` /
   `redemptionClaim`, `INavFund.claimableRedeemRequest`, the `SettlementOpened` / `SolverBid` /
   `SettlementFinalized` / `SettlementPositionsSettled` / `RedemptionRequested` / `RedemptionClaimed`
   events). **Update, same day:** BE-chain posted READY A1 (v3 frozen, `6da23ce`). The keeper and the solver
   now use `credence-bindings` v3 (`da1763d`), and the SDK and indexer use `deployments/abis/v3` (`d63796b`).
   The draft matched: nothing but the imports changed. The `@credence/sdk` `dist` was not rebuilt during
   the S3 scenario run, because the running API, notifier and indexer load it.
2. **J10 keys and gates.** The key is `J10:<adapter>:<settlementId>:<step>`, with `step` ∈ {open, finalize,
   claim}. For `open`, the id is what the `eth_call` pre-check of `openSettlement` returns (the adapter's
   `nextSettlementId`), so a race with another opener makes a new key, never a duplicate tx. The adapter's own
   rules (clock state, HF, already-flagged borrowers, `RedemptionsGated`) are the gate. A reverting pre-check
   means "not now", and no tx is sent. `completeReopen` for NAV assets is keyed `J10:<asset>:<closureId>:completeReopen`.
   J4 skips the NAV market once `nav.settlement` is in the book, because a direct `flagForAuction` on a NAV
   market reverts in v3.
3. **Bell times come from the chain.** The keeper reads `AssetClock.BELL_WINDOW` / `BELL_DEADLINE` at startup.
   These are the constants from which the clock computes `closureInfo.bellWindowAt` / `bellAt`. The keeper
   uses them for J1's boundaries and J2/J3's `bellAt`. The §8.2.2 constants remain only as a startup
   self-check that warns when they differ, and as the fallback if the read fails. Gauge:
   `keeper_bell_lead_seconds{kind}`.
4. **J12 watches the Stylus programs behind the router.** `shared.riskEngine` is the Solidity
   RiskEngineRouter (ADR-0108). ArbWasm answers `ProgramNotActivated` for it, which is the false "programTimeLeft 0 days"
   RB-10 alert from the S3 run. A configured address that is not a program but answers `pricing()` / `auction()`
   is replaced by those two programs (labels `riskEngine.pricing`, `riskEngine.auctionMath`). On the S4 devnode
   both report about 365 days. A genuinely expired program still alerts.
5. **Unpriced markets are "not live".** A core market read that reverts `NoReferencePrice` (`0x2da33f4c`) is
   logged once per state change, counted in `keeper_markets_unpriced`, and skipped. Other read failures keep a
   warning, once per change, plus `keeper_market_read_errors_total{market}`.
6. **§16.1 alert inputs come from the keeper.** It already reads the chain every tick, so it publishes the gauges
   behind the pool and auction alerts: `keeper_bell_unenforced_positions`, `keeper_reopen_pending_seconds`,
   `keeper_epoch_unsettled_seconds`, `keeper_pool_utilisation_ratio`, `keeper_shortfall_escalations{layer}`.
   The shortfall figure is a gauge recounted from the start block and published only once the scan reaches
   the head, so a keeper restart never looks like a new escalation (`delta(...[1h]) > 0`).
7. **The solver bot is a second binary of `services/bidder`** (`credence-solver`). It shares the crate's
   config and dev-chain guard and needs no new workspace member.

## Consequences
- When BE-chain freezes v3, swapping the local bindings is mechanical. A signature change shows up in the
  build or the unit tests.
- The NAV lot ids of the market and the equity auction ids share the `lot_position` key space (both start at 1).
  The notifier's `auction_settled` scan now joins on the market too, and `nav_sold` joins `settlement` on the
  market. Making `lot_position` itself unambiguous is a schema change for S5 (see the S4 report).
