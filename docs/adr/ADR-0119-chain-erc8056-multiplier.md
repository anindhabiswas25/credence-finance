# ADR-0119 · BE-chain · The ERC-8056 multiplier in the collateral path

Status: accepted (S5, Amendment 1 point 5) · Date: 2026-09-30

## Context
Robinhood Stock Tokens implement ERC-8056 (Scaled UI Amount): underlying shares = raw amount × `uiMultiplier()` / 1e18.
Dividends, splits and other corporate actions change the multiplier, never the raw balances. A scheduled update is
readable before it takes effect: `newUIMultiplier()` and `effectiveAt()` (it applies once `block.timestamp >=
effectiveAt`). Chainlink prices these tokens as underlying price × multiplier (the Robinhood docs and the Chainlink
Robinhood tokenized-equity feed page).

The contracts already valued collateral per token (`OracleAdapter._tok`: share price × `sharesPerToken`), but the ratio
was read from the token once, at listing. After that it changed only through a timelocked corporate action
(`AssetClock.beginCorporateAction` / `confirmCorporateAction`). A quarterly dividend would have needed a timelock
operation, and a split would have needed a person to notice it.

## Decision
- **Test tokens.** `CredenceStockToken` implements ERC-8056 (`IScaledUIAmount`): `uiMultiplier`, `newUIMultiplier`,
  `effectiveAt`, `scheduleUIMultiplier(m, at)` and `cancelUIMultiplierUpdate()` (both issuer only), and the events
  `UIMultiplierUpdated` / `UIMultiplierUpdateCancelled`. The v0 `sharesPerToken()` / `setSharesPerToken(r)` stay as
  aliases (`r` takes effect at once), so the ABI change is additive.
- **Oracle.** `OracleAdapter.syncMultiplier(asset)` is permissionless and never reverts for a step it can't take yet.
  It caches the token's live multiplier:
  - at once, when the step is ≤ `MULTIPLIER_AUTO_STEP` (2 %, a dividend);
  - for a larger step, only when all of these hold:
    - it was scheduled and took effect (`effectiveAt ≤ now`);
    - both feeds have a live print observed at or after `effectiveAt`;
    - those prints × the new multiplier are within min(½ |step|, `MULTIPLIER_MAX_GAP` 25 %) of the reference price of
      the closure that the corporate action holds (per token, old multiplier);
    - the step is within ×10 / ÷10.

  The continuity check stops a relayer that still prints the old share price after `effectiveAt` from being taken as
  the new one (a 2:1 split would double the token's value). A large jump that nobody scheduled (no `effectiveAt`), or
  one whose prices never become continuous, stays in CORP_ACTION until the timelock's `confirmCorporateAction`.
  `multiplierState(asset)` is the view: cached, live, next, at, and whether a corporate action is due. A step is due
  when the live multiplier is > 2 % off the cached one, or when an update of > 2 % takes effect within
  `MULTIPLIER_LEAD` (1 day). A NAV asset is never due.
- **Clock.** Every `AssetClock.poke` of an equity asset first calls `syncMultiplier`, which is gas-guarded. A due
  action sets the existing `corporateAction` flag and the new `multiplierAction[asset]`: CORP_ACTION means no borrow
  and no liquidation, and the token is valued at the closure reference. The action ends by itself once the sync has
  cached the new multiplier and nothing more is due. The first fresh cross-checked price then reopens the asset
  through the existing HALT / CORP_ACTION open-print rule; a scheduled closure's official open does the same. A
  timelock or guardian corporate action is not ended by the sync. `confirmCorporateAction` also clears
  `multiplierAction`. `previewState` shows a due action as CORP_ACTION until a poke has cached the step (conservative).
- Valuation keeps using the **cached** multiplier, so no price is ever computed with a multiplier from the other side
  of an action. A small step reaches valuation at the next poke, and every market action pokes first.

## Consequences
- Robinhood Stock Tokens (and our test tokens) are valued per token, with dividends applied automatically. A split or
  reverse split pauses the market from a day before it takes effect until post-action prices arrive.
- Residual risk:
  - A small step (≤ 2 %) is cached before the share price moves ex-dividend, so the token can be overvalued by up to
    2 % until the price adjusts. That is inside the 5-point LTV-to-LT buffer.
  - A large step whose new per-token price legitimately gaps by more than half the step keeps the asset in
    CORP_ACTION until the timelock confirms.
- Gas: `poke` pays three token views plus a compare, about 10–15k gas per equity poke.
- Off-chain (Engineer B): values shown to users should use `sharesPerToken` (the cached multiplier). A corporate-action
  alert can listen for `CorporateActionBegun` / `CorporateActionConfirmed` and read `multiplierAction`.

## Tests
`contracts/test/security/edge/MultiplierEdges.t.sol` (real XNYS calendar, real clock, oracle and feeds):
- E-K-01: a small dividend is applied at once.
- E-K-02: a 2:1 split across a weekend.
- E-K-03: a 1:3 reverse split, where a stale-price print does not end the action.
- E-K-04: a large update during open positions (intraday).
- E-K-05: a small step inside a closure, then a ×2 jump held until the timelock confirms.
- E-K-06: a cancelled update.
