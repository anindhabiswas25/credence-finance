# ADR-0120 · BE-chain · An official Robinhood Stock Token as collateral, and tUSDG on Robinhood Chain testnet

Status: accepted (S5, Amendment 1 points 3 and 4) · Date: 2026-09-30

## Context
Amendment 1 moves the equity stack to Robinhood Chain testnet (46630). It asks for one official Robinhood test Stock
Token (TSLA or AMZN) listed as a small extra market, to prove the integration with the real token contract. It also
asks for a test USDG as the loan token, unless one already exists on 46630.

## What the chain has (read on 2026-09-30)
- **Stock Tokens.** The Robinhood asset API (`api.robinhood.com/rhj/assets`) lists mainnet deployments only (chain
  4663; TSLA `0x322F…3b2d` has no code on 46630). The docs warn that a matching ticker at another address is not a
  Robinhood Stock Token. On 46630 the explorer shows many look-alikes. The canonical pair is identified by the same
  creator `0x2DD5b0Ea7c29006bA9450B9a4f3ADc234409e5Da` and the same verified beacon implementation **`Stock`
  (`0xBd14156E05c6AF28ad39aA53a2AB8eB9CDf657DA`, solc 0.8.33)**:
  - **Tesla (TSLA): `0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E`**
  - Amazon (AMZN): `0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02`
  - Both have 6,239,835 supply and `uiMultiplier` = 1e18.
- **The `Stock` interface:**
  - ERC-20 with 18 decimals and permit;
  - ERC-8056: `uiMultiplier`, `newUIMultiplier`, `effectiveAt`, `balanceOfUI`, `totalSupplyUI`, events
    `UIMultiplierUpdated` and `TransferWithScaledUI`;
  - `updateMultiplier(m)` / `updateMultiplier(m, effectiveAt)`, restricted to `MULTIPLIER_UPDATER_ROLE`;
  - `paused()` (the token's own pause OR the registry's), `tokenPaused()`, `pause`/`unpause`;
  - `ACCESS_CONTROLLED_REGISTRY()` → `AccessControlsRegistry` (`isBlocked(address)`, `paused()`);
  - `mint`, `burn`, **`adminBurn(from, amount)`**, `uid()`.

  `transfer` / `transferFrom` / `approve` revert `IsPaused()` while paused, and `Blocked(a)` if the sender, `from` or
  `to` is blocked. It has **no** `frozen()`, `issuer()`, `canHold()` or `sharesPerToken()`.
- **USDG.** The docs list USDG on mainnet only (`0x5fc5…d168`, no code on 46630). The testnet explorer has several
  USDG-named tokens: a 6-decimal "Global Dollar" proxy (`0x7E95…802F`, undocumented creator), an 18-decimal "USD Gold
  (testnet)", "Mock USDG", and others. None is documented as the official test USDG, and none has a faucet we could
  seed vaults from.

## Decision
- **Loan token on 46630: our own `tUSDG`** (the 6-decimal test stablecoin, open mint on testnet, symbol `tUSDG`,
  labelled a test asset). The NAV stack on 421614 keeps test USDC. If Robinhood documents a test USDG, the deploy
  config swaps the address (the loan token is config, not code).
- **The extra market: official Robinhood TSLA** (`0xC9f9…Bd4E`) as asset `RHTSLA:XNAS`, capped low (supply cap $25k,
  borrow cap $15k, vault cap $25k), next to our six test tokens. The oracle binds one token per asset id, so the
  official token gets its own id. Its price is TSLA's share price published under that id (**Engineer B's relayer**:
  REQUEST). Its risk sets are TSLA's sets under the key `RHTSLA:XNAS`.
- **Code changes, so the real token works:**
  - **`TokenProbe` library**, used by `AuctionHouse` and `SolverAuction`: a holder is blocked if the token's
    `canHold` says so, else if the token's `ACCESS_CONTROLLED_REGISTRY().isBlocked(who)` says so; a token with neither
    is open. Before this, the auction house treated the Stock Token as open to anyone. A blocklisted bidder could win a
    lot, and its transfer would then revert the whole clear.
  - **The oracle's issuer probe** reads `frozen()` and, if the token has none, `paused()`. Before this, the missing
    `frozen()` failed closed, so the asset would have been HALTED forever. A paused Stock Token (its own pause or the
    registry's) is now `issuerFrozen`, so the asset is HALTED while every transfer reverts anyway.
  - The ERC-8056 multiplier path of ADR-0119 reads the Stock Token as is (E-R-03).

## Consequences and trust assumptions
- **`adminBurn`** lets the issuer burn any holder's balance, the market's custody included, which would leave the lent
  money uncollateralised. This is the issuer trust any RWA collateral carries, and the reason the market is capped low
  on testnet. For mainnet it needs a legal agreement, or a per-market cap sized to the issuer risk.
- **A blocklisted market, pool or auction house** freezes every position of that token. That can't be mitigated
  on-chain; the guardian pauses borrowing on the market.
- **A holder blocklisted after it bid** makes its lot's `clear` revert on the transfer. The bid-time check narrows
  this but doesn't close it. What the lot does then is **not verified yet**; it is an E-R row for Phase 2, fixed if
  the lot can get stuck.
- `AuctionHouse` is 24,454 bytes after this change, 122 below the EIP-170 limit.

## Tests
`contracts/test/security/edge/RobinhoodTokenEdges.t.sol`, against `test/mocks/MockRobinhoodStock.sol`, a behavioural
copy of the testnet `Stock`:
- E-R-01: listing, and the issuer pause (the token's and the registry's);
- E-R-02: the holder check across token kinds;
- E-R-03: `updateMultiplier` drives the ADR-0119 sync;
- E-R-04: the transfer rules, and `adminBurn`.
