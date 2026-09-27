# Credence Finance Architecture

Sep 26, 2026 · @Akash Biswas

> **Rev 2 · Sep 27, 2026.** Renamed from Kairos to Credence Finance. A product and engineering review of this document found 22 points to settle before build. They are listed, with the binding decision for each, in `CREDENCE_BUILD_GUIDE.md` §2. Where this document and the Build Guide disagree, the Build Guide wins for implementation.

Credence Finance is a lending protocol for assets whose real price stops when their market closes: tokenized stocks, and tokenized Treasury funds that price once a day. Every rule in it follows the asset's market clock, so nobody is liquidated on a fake weekend price, and the weekend-gap risk that lenders carry today is priced and sold to a pool of underwriters who are paid to hold it.

To see every user and every dollar move through one real week, read One week of money flow.

## Summary

Credence Finance is five mechanisms wrapped around a simple over-collateralised lending market. Each one exists because stock and fund collateral breaks an assumption that ETH collateral never breaks.

| # | Mechanism | What it does | Assumption it fixes |
| --- | --- | --- | --- |
| 1 | **Asset Clock** | Tracks each asset's market state: open, extended hours, closed, halted, reopening | "A live price always exists" |
| 2 | **Bell Check** | Before every closure, each loan must be at a weekend-safe LTV, or be insured | "Liquidation can happen at any moment" |
| 3 | **Gap Cover + Underwriter pool** | A first-loss pool sells insurance on the reopen gap and absorbs bad debt first | "Lenders silently share tail risk" |
| 4 | **Reopen Batch Auction** | Liquidations at the open clear in one uniform-price auction, not a bot race | "Fastest bot wins the liquidation" |
| 5 | **Settlement adapter** | Treasury-fund collateral is liquidated through solvers who pay cash now and wait out redemption | "Collateral can be sold in one block" |

Design decisions this document commits to:

- **Credence Finance runs its own isolated markets.** Controlling *when* and *how* liquidation happens is the product, and a third-party market such as Morpho or Aave cannot pause or batch its liquidations. The Gap Cover module is built so that it can later be offered to other venues.
- **Two deployments, no bridge in phase 1.** Stock-token markets go on Robinhood Chain, where the Stock Tokens live. Treasury-fund markets go on Arbitrum One, where BENJI, WTGXX and USTBL live. Both run the same code.
- **Solidity for storage and money movement, Stylus (Rust) for math.** Scenario pricing, capacity checks and auction clearing run in Stylus. Everything that holds funds stays in audited Solidity.
- **Every parameter is on-chain and public.** That includes the gap tables, premiums, pool size and every liquidation's realised price.

All numbers in this document are illustrative, chosen to show how the math behaves. None are calibrated. Calibration comes from the historical backtest in section 9.

## 1. System architecture

Credence has four layers: the people who use it, the Solidity contracts that hold money, one Stylus risk engine that does the math, and the outside services that feed it prices and cash.

&#91;embedded content: system architecture · users, contracts, risk engine, external services\]

Read it top down. Each user touches exactly one contract. The four money contracts ask the Risk Engine for every number they need. The Risk Engine reads the asset's market state and price from the bottom row, which in turn is fed by keepers, price feeds and settlement solvers.

| Layer | Component | Holds funds? | Section |
| --- | --- | --- | --- |
| Money | Lending Market (one isolated market per collateral asset) | Collateral + debt records | 3.3 |
| Money | Senior Vault (stablecoin lenders) | Stablecoins | 3.3 |
| Money | Underwriter Pool (junior, first-loss) | Stablecoins | 3.6 |
| Money | Auction House (reopen and backstop auctions) | Collateral in transit, bid bonds | 3.7 |
| Brain | Risk Engine (Stylus) | No | 3.4 |
| Inputs | Asset Clock Registry | No | 3.1 |
| Inputs | Oracle Adapter | No | 3.2 |
| Inputs | Settlement Adapter (Treasury-fund liquidation) | Collateral in transit | 3.8 |
| Off-chain | Keepers, price feeds, settlement solvers | Their own capital only | 3.9 |

Three rules hold everywhere:

1. **Only money contracts move funds.** The Risk Engine is a pure function: state in, numbers out. A bug there can misprice, but it cannot move a token.
2. **Inputs fail closed.** If the clock, the oracle or the calendar disagree, the asset is treated as CLOSED. New borrowing stops and liquidations wait for a verified price.
3. **Keepers are untrusted.** Every keeper action is checked on-chain, and anyone can perform it. A dead keeper delays things but cannot cause a wrong outcome.

## 2. A week in Credence

The risk Credence prices is the gap between Friday's regular-session close and Monday's regular-session open. That gap has decades of history behind it and can be measured. Everything else in the week is built around that window.

&#91;embedded content: one weekend · 6 phases, 4 gates\]

The Bell deadline is set 15 minutes before the Friday close on purpose. Any forced sale then happens in the deepest liquidity of the week, not in thin post-market or overnight trading.

How the rest of the week works:

- **Monday to Thursday.** Each weeknight is a small closure: the regular close to the next regular open. The same Bell Check runs, but a weeknight gap is much smaller than a weekend's, so the overnight safe LTV is usually above the market's normal max LTV. In practice, nobody has to act on a normal weeknight.
- **Holiday weekends** (Good Friday, Memorial Day and so on) are longer closures with their own, wider gap tables. The Bell Check usually *does* bind before them.
- **Extended hours** (pre-market, post-market, and the Sunday-to-Thursday overnight session) have a live 24/5 price, but it is thin. Credence uses it for monitoring, for voluntary borrower actions, and for emergency liquidations of uncovered positions only (health factor below 0.92; a covered position waits for the regular open, because the pool has already underwritten the gap). Those emergency liquidations also go through a batch auction, never first-come-first-served.
- **Unscheduled events** (a single-stock trading halt, an exchange outage) move that asset to HALTED. It is treated like CLOSED and reopens through the same auction.

This is why Credence can promise borrowers that nobody is liquidated on a fake weekend price, while still protecting lenders from a real Monday crash.

## 3. Components

### 3.1 Asset Clock Registry

The Asset Clock is a small contract that answers one question for every other contract: what state is this asset's home market in right now? Every rule in Credence is keyed on its answer.

&#91;embedded content: Asset Clock · 6 states, 9 transitions\]

Every closure, whether overnight, weekend, holiday or halt, ends in REOPEN. That is how the Monday batch auction and the weekday morning auctions become one code path.

**What each state allows**

| State | Price used | New borrow | Withdraw collateral | Repay / add collateral | Liquidation | Buy Gap Cover | Underwriter withdrawal |
| --- | --- | --- | --- | --- | --- | --- | --- |
| REGULAR | Live feed | Up to max LTV | If health factor stays at or above 1.05 | Yes | 60-second batch auctions | Yes (until the Bell deadline) | Yes, from the queue |
| EXTENDED | min(last regular close, live TWAP) | Up to the next closure's safe LTV | Only down to safe LTV | Yes | Emergency only for uncovered positions (health factor below 0.92), batched | No | No |
| CLOSED | min(frozen close, DEX TWAP) | Up to safe LTV at the min price | Only down to safe LTV | Yes | None | No | Locked |
| REOPEN | Official opening print | Paused until the auction settles | Paused | Yes | One reopen batch auction | No | Locked |
| HALTED | Same as CLOSED | Same as CLOSED | Same as CLOSED | Yes | None | No | Locked |
| CORP. ACTION | Frozen until the adjusted feed is confirmed | No | No | Yes | None | No | Locked |

Repaying debt and adding collateral are **always** allowed. A borrower can make their own position safer at any hour.

**How the state is decided**

The state is the most restrictive of three independent inputs:

1. **Calendar.** An on-chain table of exchange sessions: regular hours, holidays, and early-close days (such as the day after Thanksgiving). It is loaded a year ahead through the timelock, so any change is visible 48 hours before it takes effect.
2. **Oracle.** The feed's market-status field and its update timestamps. A feed that stops updating during expected REGULAR hours pushes the asset to HALTED.
3. **Guardian override.** A multisig that can only move an asset *toward* a more restrictive state (for example, extend CLOSED during an exchange outage). It can never shorten a closure or lift a halt early.

Transitions are lazy. Anyone can call `poke(asset)`, and every money contract calls it first, so the stored state is always current when it matters. The keeper only calls it to emit events on time.

**What the clock stores per asset**

| Field | Meaning |
| --- | --- |
| `state` | One of the six states |
| `closureId` | Increments at every close; loans, cover policies and auctions are tagged with it |
| `closureType` | OVERNIGHT, WEEKEND, HOLIDAY\_WEEKEND, HALT, CORP\_ACTION; selects the gap table the Risk Engine uses |
| `refPrice`, `refTime` | The last regular-session close, frozen at the close |
| `bellAt`, `closeAt`, `reopenAt` | Timestamps of the next Bell deadline, close and scheduled open |
| `openPrint` | The official opening price, written once at REOPEN from the oracle |

### 3.2 Oracle Adapter and price layer

The Oracle Adapter turns several raw feeds into one **valuation price** per asset, and the rule it follows depends on the clock state. Its core rule: when the home market is shut, an off-hours price can lower a collateral's value but never raise it.

**Inputs**

| Source | Used for | Notes |
| --- | --- | --- |
| Chainlink tokenized-equity feed (primary) | Live price in REGULAR and EXTENDED, opening print | 24/5 session coverage; its market-status field feeds the clock |
| RedStone equity feed (secondary) | Cross-check against the primary | A second, independent operator |
| DEX time-weighted average price (TWAP) of the Stock Token | Weekend and overnight *signal* | Only enters through `min()`, and is ignored if the pool is too shallow |
| Issuer ratio (tokens per share) | Splits and similar share-count changes | Changed only through the CORP. ACTION path |

**The valuation price by state**

```latex
V_t = \begin{cases} P^{\text{live}}_t & \text{REGULAR} \\ \min\left(P^{\text{close}},\ \text{TWAP}^{30\text{m}}_{\text{ext}}\right) & \text{EXTENDED} \\ \min\left(P^{\text{ref}},\ \text{TWAP}^{1\text{h}}_{\text{dex}}\right) & \text{CLOSED, HALTED} \\ P^{\text{open}} & \text{REOPEN} \end{cases}
```

Why `min()` and not the DEX price itself:

- **No fake liquidations.** In CLOSED the valuation price only limits *new* borrowing. Liquidations are switched off, so pushing the weekend DEX price down gains an attacker nothing except annoying borrowers.
- **No free option.** Without the `min()`, a borrower who hears bad news on Saturday could borrow the maximum against Friday's stale price and walk away. With it, any weekend price fall immediately shrinks what anyone can borrow.
- **No pump-and-borrow.** A pumped weekend price can never raise collateral value, because the frozen close caps it.

**Safety checks**

| Check | Rule (illustrative) | Action |
| --- | --- | --- |
| Staleness | Primary older than 60 s in REGULAR, 5 min in EXTENDED | Asset treated as HALTED |
| Disagreement | Primary vs secondary differ by more than 1.5% | Use the lower price and pause new borrowing |
| Severe disagreement | Differ by more than 5% | Asset treated as HALTED |
| Weekend stress flag | DEX TWAP below 90% of the frozen close | New borrowing paused, UI banner, keepers alerted (no liquidation) |
| Shallow pool | DEX depth within 2% of mid below a floor (for example $250k) | TWAP ignored, frozen close used alone |
| Opening print | Must come from the regular session's first valid print, and must agree with the secondary within 1.5% | Otherwise REOPEN waits (up to 15 min), then falls back to a 5-minute TWAP |

**Price the exact token, never a wrapper's exchange rate.** The Edel exploit came from a lending market that read a manipulable wrapper exchange rate. Credence prices the Stock Token directly: underlying share price × the issuer's tokens-per-share ratio. That ratio changes only through the CORP. ACTION state, and each change is capped.

**Known price drops are priced in.** When a closure spans an ex-dividend date, the Risk Engine subtracts the known dividend from the expected Monday price before computing the safe LTV (section 4.2).

### 3.3 Lending core: markets and the Senior Vault

The lending core is deliberately boring: isolated markets in the style of Morpho Blue, plus one ERC-4626 Senior Vault that supplies stablecoins to them. All the novelty sits in the checks it calls before any action.

**Market.** One immutable market per collateral asset, defined by a tuple:

| Field | Example |
| --- | --- |
| Collateral token | Tokenized NVDA Stock Token |
| Loan token | USDG on Robinhood Chain; USDC on Arbitrum One |
| Clock asset id | NVDA, XNAS calendar |
| Max LTV / liquidation threshold (LT) | 75% / 80% |
| Liquidation penalty | 3% |
| Supply cap / borrow cap | $2M / $1.4M at launch |
| Gap table id | Points to the scenario set in the Risk Engine |

Isolation means a bad Monday in one stock cannot drain another stock's market. Correlation across stocks is still handled, but by the Underwriter Pool's capacity check (section 3.6), not by shared collateral.

**Position.** Each borrower position stores: collateral amount, debt shares (debt grows with interest through a global index), the `closureId` of its last Bell Check result, and the id of an active Gap Cover policy, if any.

**Senior Vault.** Lenders deposit the loan token and receive vault shares. The vault allocates to markets up to per-market caps set by governance. Share value grows with the senior share of borrow interest. Withdrawals are instant up to the vault's idle liquidity; beyond that, they queue and are paid as borrowers repay or as utilisation falls. Senior lenders are **never** locked by the clock. Their protection is the Underwriter Pool, not a lock.

**Where borrow interest goes.** Every borrow pays one rate, and it is split three ways (formula in 4.6):

1. **Senior Vault**: the large majority.
2. **Underwriter Pool**: a base risk fee, because every loan carries some tail risk even at a safe LTV.
3. **Protocol treasury**: a small fee.

**Action checks.** Every state-changing action calls `clock.poke()`, then the Oracle Adapter, then one or more Risk Engine functions:

| Action | Check (after the action) |
| --- | --- |
| `borrow` | LTV ≤ max LTV in REGULAR before the Bell window. From the Bell window onward and in EXTENDED / CLOSED: LTV ≤ the next closure's safe LTV, or the loan must hold enough Gap Cover |
| `borrowWithCover` | Borrow and buy Gap Cover atomically; allowed up to max LTV until the Bell deadline |
| `withdrawCollateral` | Same limits as `borrow`, plus health factor ≥ 1.05 |
| `repay`, `addCollateral` | None. Always allowed, in every state |
| `flagForAuction` | Health factor < 1 at the state's valuation price (REGULAR), < 0.92 (EXTENDED, uncovered positions only), or < 1 at the opening print (REOPEN). Anyone can call it |

In REGULAR hours, flagged positions go into a 60-second rolling batch auction run by the same Auction House as the reopen auction. There is no separate first-come liquidation path anywhere in Credence.

### 3.4 Risk Engine (Stylus, Rust)

The Risk Engine is one Rust crate that runs in two places. It is compiled to Stylus for on-chain use, and compiled natively for keepers, the web app and the backtest. Both builds produce identical numbers from identical inputs. It holds no funds and has no admin functions; it reads parameters and returns numbers.

**What it stores**

| Data | Shape | Updated by |
| --- | --- | --- |
| Scenario sets | Per asset and closure type: standardised historical close-to-open returns z₁…zₙ, stored as int16 in thousandths of a standard deviation | Governance, through the timelock, after each quarterly recalibration |
| Joint scenario matrix | Per historical weekend k: the vector of z across every listed asset (missing early history filled from the index, scaled by beta) | Same |
| Volatility state σₜ | Per asset and closure type: the current scale for the gap distribution | Keeper, once a day, rate-limited (below) |
| Parameters | α (target tail probability), κ (liquidation cost), loading θ, cost of capital, utilisation cap | Governance, through the timelock |

This is **filtered historical simulation**. Past gaps are standardised by the volatility at the time, then rescaled by today's volatility. The shape of the tails (how often 5-sigma weekends happen) comes from real history, and the size comes from the current market.

**Volatility update rule.** σₜ is an exponentially weighted estimate from recent close-to-open returns, blended with option-implied volatility where a reliable feed exists. It can rise by any amount in one update but fall by at most 10% per day, and never below a floor (the long-run 25th percentile). Risk goes up instantly and comes down slowly.

**Functions**

| Function | Returns | Called by |
| --- | --- | --- |
| `safeLtv(asset, closureType)` | The highest LTV that stays solvent in all but a fraction α of historical gaps (4.2) | Market, Bell keeper, UI |
| `bellStatus(position)` | SAFE, NEEDS\_ACTION (with the cure amount), or COVERED | Market, Bell keeper |
| `quoteCover(position, closureId)` | Premium, covered amount, capital the pool must reserve (4.3) | Market, UI |
| `poolCapacity(pool, newPolicy)` | Pass or fail against the joint stress scenarios (4.4) | Underwriter Pool |
| `liquidationLot(position, pOpen)` | Collateral to sell to restore the target health factor (4.5) | Auction House |
| `clear(bids, lot, reserve)` | Uniform clearing price and fills (4.5) | Auction House |

**Why Stylus, specifically.** A premium quote loops over 1,000 to 3,000 scenarios per position. A capacity check loops over every scenario for every covered policy. Auction clearing sorts bids. That is exactly the compute-heavy, storage-light work that Arbitrum's docs say gains most from Stylus (their benchmarks cite 10–100x cheaper compute), while storage costs about the same as in the EVM. Each scenario set is read from storage once per call into WASM memory. Stylus has no floating point, so all math is fixed-point integer arithmetic with 18 decimals, and the native build uses the same integer code, so results match bit for bit.

**Failure behaviour.** If any Risk Engine call reverts or runs out of gas, the calling action fails closed. Borrowing, collateral withdrawal and cover sales stop, while repay and add-collateral still work because they call nothing.

### 3.5 Bell Check and Gap Cover

The Bell Check makes sure no loan enters a closure carrying more gap risk than the protocol has been paid for. Every position ends the Bell window in one of two states: at or below the closure's **safe LTV**, or **covered** by a Gap Cover policy.

&#91;embedded content: Bell Check · 5 outcomes, all safe or covered\]

**The Bell window.** It opens 2 hours before every scheduled close and ends at the Bell deadline, 15 minutes before the close. In practice it only binds before weekends, holidays and high-volatility nights, because a normal weeknight's safe LTV sits above the market's max LTV.

**Enforcement.** After the deadline, anyone can call `enforceBell(positionIds)`. It checks each position against the safe LTV at the live price and, for each one still out of line:

1. **Auto-cover (default).** If the Underwriter Pool has capacity, the protocol buys cover for the position and adds the premium to its debt. No collateral is sold.
2. **Pre-close sale.** If the pool is full, or the borrower opted out of auto-cover, just enough collateral is sold in the 15:45–16:00 batch auction to reach the safe LTV. The penalty on this sale is 1%, not the full 3%, because it is precautionary.

The caller earns a small fixed tip per position, paid from the protocol fee.

**Gap Cover policy terms**

| Term | Rule |
| --- | --- |
| What it covers | Any shortfall (debt left unpaid after the position's collateral is auctioned) arising at the reopen that ends this closure |
| Lifetime | Exactly one closure (tagged with its `closureId`); expires when the REOPEN auction settles |
| Maximum covered LTV | The market's max LTV (75%). Cover never lets a loan go beyond normal limits |
| Premium | Quoted by the Risk Engine (formula in 4.3), paid upfront in the loan token or added to debt |
| Deadline | Must be bought before the Bell deadline. No sales in EXTENDED or CLOSED, so nobody can buy insurance after hearing Saturday's news |
| Refunds | None, even if the borrower later repays. Otherwise a borrower could buy cover, watch the weekend and cancel |
| Transferability | Tied to the position, not transferable |
| Who pays out | The Underwriter Pool, first; then the waterfall in 3.6 |

**Why a weekend-safe LTV instead of a permanently low LTV.** Aave's equity markets on Base set collateral factors of 65–79% and accept the weekend gap as a structural risk. With a static LTV, you must pick the level for the worst closure of the year and apply it every day. Credence applies the tight limit only when the risk actually exists, and lets borrowers pay to keep their leverage through it.

### 3.6 Underwriter Pool and the loss waterfall

The Underwriter Pool is the junior tranche: stablecoin capital that takes every closure loss first, and in exchange collects every Gap Cover premium, a base risk fee on all borrow interest, and a share of liquidation penalties. Senior lenders lose money only after the pool and the protocol reserve are both gone.

&#91;embedded content: loss waterfall · 3 layers, each paid for its position\]

This is the same senior/junior structure as Centrifuge's DROP and TIN tokens and traditional loan securitisations. Credence differs in what the junior tranche is paid to hold: a specific, measurable risk (the reopen gap), priced per loan, per closure.

**Epochs.** Each closure is an epoch, tagged with its `closureId`. Pool accounting is done per epoch so that the people who carried a weekend's risk are exactly the people paid for it.

| Rule | Why |
| --- | --- |
| Capital deposited after a Bell window opens counts only from the *next* epoch | Stops just-in-time capital from collecting a weekend's premiums without carrying earlier risk |
| Premiums for epoch c are credited when epoch c's REOPEN auction settles | Premiums are earned only by capital that stayed through the gap |
| A withdrawal must be requested before a Bell window opens, and is paid after that epoch settles | Capital cannot leave right before a risky weekend; exits happen at the post-loss share price |
| Pool shares are transferable ERC-20 tokens | Underwriters who need to leave mid-epoch can sell their shares on a DEX instead of waiting |

**Capacity.** The pool may only sell cover it can survive. Before any policy is written, `poolCapacity()` replays every historical joint weekend against all covered and uncovered positions at once, since stocks crash together. The policy is refused if the worst replayed loss would use more than 50% of the pool (section 4.4 has the formula). When the pool is full, borrowers fall back to curing or the pre-close sale, and the premium quote rises as the pool fills (utilisation loading, 4.3).

**Backstop buyer.** If a reopen auction fails to sell the whole lot at or above its reserve price, the pool buys the remainder at the floor price, repays the debt, and resells the tokens over the next days through a Gradual Dutch Auction (section 3.7). Any profit or loss on that resale belongs to the pool.

**Protocol reserve.** Funded by a fixed share of the protocol fee and of liquidation penalties, with a target size set by governance (for example 5% of total borrows). It only pays out after the pool is exhausted.

**Idle pool capital** stays in the loan token in phase 1. It is never lent to the Senior Vault, because then the pool would be protecting a vault it is invested in. Later, a capped share can move into Treasury-fund tokens with same-day redemption.

**Where underwriters' returns come from, and what can go wrong**

| Income | Risk |
| --- | --- |
| Gap Cover premiums | A gap larger than the tables expected (the model is wrong) |
| Base risk fee (a share of all borrow interest) | Several stocks gapping together beyond the stress set |
| Share of liquidation penalties | Backstop purchases resold at a loss |
| Backstop resale profits | Capital locked through each epoch |

### 3.7 Auction House: the reopen batch auction

Every position that is under water at the opening print is sold in a single uniform-price auction per asset. Everyone bids during the same window, and every winner pays the same price, so speed, ordering and Timeboost priority are worth nothing.

&#91;embedded content: reopen auction · 9 steps, 1 decision\]

**Step by step (times are illustrative)**

| Step | Time after open | What happens |
| --- | --- | --- |
| Open print | 0:00 | The clock writes the official opening price Pᵒ (cross-checked, section 3.2) and enters REOPEN |
| Queue | 0:00–2:00 | Anyone calls `flagForAuction(position)`; the contract verifies health factor < 1 at Pᵒ. A queued borrower can still repay or add collateral and leave the queue until the commit phase starts |
| Size the lots | 2:00 | The Risk Engine computes, for each position, the smallest sale that restores the target health factor (formula 4.5). The asset's lot Q is the sum |
| Commit | 2:00–5:00 | Bidders submit `hash(quantity, price, salt)` plus a bond of 10% of a declared maximum notional (the bid's own value is hidden at commit, so the bond is sized on a cap the reveal must stay under). Nobody can see anyone's bid |
| Reveal | 5:00–7:00 | Bidders reveal and escrow full payment. An unrevealed commit forfeits its bond to the Underwriter Pool |
| Clear | 7:00 | Bids are sorted by price. Fill down the list until Q is sold; p\* is the lowest accepted price and **every winner pays p**\*. Bids below the reserve R = 97% of Pᵒ are ignored |
| Backstop | 7:00 | Any unsold part of Q is bought by the Underwriter Pool at R |
| Settle | 7:00 | Proceeds go to each position pro rata to its share of Q. Debt is repaid, the penalty is taken, and the surplus is refunded to the borrower. Any shortfall enters the waterfall (3.6) |

**Design choices and their reasons**

- **Uniform price.** A uniform-price sealed-bid batch removes the reward for being fastest. This is the frequent-batch-auction argument of Budish, Cramton and Shim (2015), applied to liquidation. The alternative, fixed-bonus first-come liquidation, is shown by Qin et al. (2021) to sell too much collateral at the borrower's expense.
- **Commit–reveal.** Because bids are hidden until the commit phase closes, the 200 ms express-lane head start that Timeboost sells is irrelevant.
- **Sell only what is needed.** Positions are partially liquidated back to a target health factor of 1.10, not closed in full, unless a full close is required.
- **Penalty only when solvent.** The 3% penalty is split one-third to the Underwriter Pool, one-third to the protocol reserve, and one-third to the protocol treasury. It is charged only out of surplus. If a position is short, the full auction proceeds go to repaying debt.
- **Permissioned collateral.** For tokens with transfer allowlists, the Auction House checks each bidder with the token's own compliance check before accepting a commit.

**The same engine runs all week.** In REGULAR hours the Auction House runs open 60-second batches (no commit–reveal, because the live price is deep and public). In EXTENDED hours it runs emergency batches for positions below a health factor of 0.92.

**Backstop resale by Gradual Dutch Auction.** Tokens the pool bought at the floor are resold over the next trading days with a continuous Gradual Dutch Auction (Paradigm, 2022): the asking price starts above the market and decays until buyers take it (formula in 4.5). This avoids dumping the backstop inventory into a thin market all at once.

### 3.8 Treasury-fund path (NAV collateral) and the Settlement Adapter

Tokenized Treasury funds such as BENJI, WTGXX and USTBL on Arbitrum One use the same Credence contracts, but their risk is the opposite of a stock's. The price barely moves; the danger is that the collateral cannot be turned into cash quickly. So for these markets the Bell Check almost never binds, and the Settlement Adapter does the real work.

**How the clock maps to a fund**

| Credence state | Meaning for a NAV fund |
| --- | --- |
| REGULAR | NAV is fresh (published within the last 26 hours) and the issuer's redemption window is open |
| CLOSED | Weekends and US bank holidays: no NAV update, no redemptions |
| HALTED | NAV older than 50 hours, NAV fell more than 0.5% in one update, or the issuer has suspended redemptions |
| REOPEN | The first fresh NAV after a CLOSED or HALTED period |

**Pricing.** The valuation price is the published NAV per token, from the issuer's feed or Chainlink's NAV feed. It is sanity-checked against the fund's accrual rate: a Treasury money fund's NAV should drift up slowly, so any drop above 0.5% sends the asset to HALTED instead of being trusted.

**Parameters (illustrative).** Max LTV 90%, liquidation threshold 93%, penalty 1%. Tokenized Treasuries typically support LTVs near 90–95% because their price barely moves. The real limit is how fast a liquidation can be turned into cash.

**Liquidation path**

1. **Solver auction.** A position below a health factor of 1 goes to the Settlement Adapter, which runs a RedStone Settle auction (or Upshift Clear as a second venue). KYC-verified solvers bid; the winner pays stablecoins to Credence in the same transaction and takes the fund tokens plus their redemption wait. Credence is made whole at T+0.
2. **Pool advance (fallback).** If no solver bids at or above the floor (NAV × 99.5%) within the window, the Underwriter Pool pays off the debt at the floor, takes the tokens, and submits a normal issuer redemption (an ERC-7540-style request where the fund supports it). The pool earns the 0.5% discount for waiting T+1.
3. **Issuer gate.** If the issuer suspends redemptions, the asset goes to HALTED. New borrowing stops, governance can raise haircuts through the guardian path, and positions stay open with repay always allowed. No forced sale into a market that does not exist.

**Compliance.** These tokens are permissioned. The Credence market contract must be allowlisted as a holder by each issuer, and only issuer-allowlisted borrowers can deposit. The stablecoin side stays permissionless, which is the same split that Aave Horizon uses.

**Why this matters on Arbitrum.** The ArbitrumDAO holds tokenized Treasuries through STEP. A Credence NAV market lets any holder, including a DAO treasury, borrow stablecoins against those positions instead of selling them. That is a concrete, low-risk first market to launch with.

### 3.9 Keepers, governance and guardian

Keepers make Credence run on time, governance sets its parameters slowly, and the guardian can only make it safer. None of the three can take user funds or change a result the contracts compute.

**Keeper jobs.** Every job is a public function that anyone can call; Credence runs its own keeper, and others can compete for the tips.

| Job | When | Function | Tip |
| --- | --- | --- | --- |
| Clock tick | Every transition | `poke(asset)` | None (cheap) |
| Bell scan | Bell window opens | Off-chain `bellStatus()` for every position, then user notifications | None (off-chain) |
| Bell enforcement | After the Bell deadline | `enforceBell(ids)` | Fixed tip per position |
| Queue at reopen | First 2 minutes of REOPEN | `flagForAuction(id)` | Fixed tip per position |
| Clear auction | End of reveal | `clear(asset, closureId)` | Fixed tip |
| Volatility update | Once a day after the close | `updateSigma(asset, σ)` | None; signed by the oracle committee |
| NAV liquidation | Any time a fund position is under water | `settle(id)` via the Settlement Adapter | Fixed tip |

**Governance** (token or multisig in phase 1, moving to token voting) controls, always through a 48-hour timelock: listing assets and markets, max LTV and liquidation threshold, caps, α, κ, loading θ, cost of capital, pool utilisation cap, fee splits, scenario-set updates, and calendar tables.

**Guardian** (a multisig) can act instantly, but only in the risk-reducing direction:

- pause new borrowing on one market or all;
- move an asset to HALTED or extend a CLOSED period;
- raise haircuts (lower max LTV) by up to 10 percentage points, reverting after 7 days unless governance confirms;
- pause cover sales.

It can **never**: move funds, shorten a closure, lower a haircut, change the scenario sets, or block repay and add-collateral.

**Transparency commitments.** A public risk page shows, per market: safe LTV for the next closure, pool size and utilisation, premiums collected, every auction's clearing price against the open print, backstop inventory, and any losses by layer. This is the same kind of public record Ethosis publishes, and it is how trust is earned before there is a track record.

## 4. The math

Every number Credence uses comes from six formulas: health, safe LTV, premium, pool capacity, liquidation sizing and clearing, and yields. Each is written below with what it means in plain words.

### 4.1 Notation

| Symbol | Meaning | Illustrative value |
| --- | --- | --- |
| q | Collateral tokens in a position | 100 |
| V | Valuation price from the Oracle Adapter (3.2) | $180 |
| D | Debt, including accrued interest | $13,500 |
| LT | Liquidation threshold | 80% |
| LTV\_max | Max LTV for new borrowing | 75% |
| r | Gap return: Monday open ÷ Friday close − 1 | — |
| z\_k | Historical gap k, standardised by the volatility at that time | from history |
| σ\_t | Today's volatility scale for this closure type | 3% weekend, 4% holiday |
| d | Known dividend inside the closure, as a fraction of price | 0 |
| α | Tail probability the safe LTV is built for, per closure | 0.1% |
| κ | Liquidation cost: discount at which the reopen auction can sell | 3% |
| λ | Liquidation penalty | 3% |
| H\* | Target health factor after a partial liquidation | 1.10 |
| J | Underwriter Pool equity | — |

### 4.2 Health, LTV and the safe LTV

Health factor and LTV are the standard ones, computed at the state's valuation price V:

```latex
\text{LTV} = \frac{D}{qV} \qquad\qquad \text{HF} = \frac{qV \cdot LT}{D}
```

Today's gap scenarios reuse the *shape* of history at today's *size* (filtered historical simulation):

```latex
z_k = \frac{r_k}{\hat\sigma_k} \qquad\qquad r^{(t)}_k = \sigma_t\, z_k - d \qquad\qquad G_\alpha = \text{Quantile}_\alpha\left(r^{(t)}_1,\dots,r^{(t)}_N\right)
```

G\_α is the Monday gap that is exceeded in only a fraction α of weekends (a negative number). Lenders lose money when the auction proceeds after the gap fall short of debt:

```latex
\text{bad debt} \iff D > qV(1+r)(1-\kappa) \iff \text{LTV} > (1+r)(1-\kappa)
```

So the highest LTV that stays solvent for every gap at least as good as G\_α is:

```latex
\text{LTV}_{\text{safe}} = \min\Big(\text{LTV}_{\max},\ (1+G_\alpha)(1-\kappa)\Big)
```

A position above it before the Bell deadline needs one of two cures, whichever the borrower prefers:

```latex
\Delta D = D - \text{LTV}_{\text{safe}}\cdot qV \qquad\text{or}\qquad \Delta q = \frac{D}{\text{LTV}_{\text{safe}}\cdot V} - q
```

Why separate tables per closure type, instead of scaling one table by the square root of calendar time: French and Roll (1986) found that the variance of a weekend return is only slightly higher than a normal weekday's (a three-day weekend's was about 10.7% higher), because most price-moving information arrives while markets trade. Scaling by √3 would overstate weekend risk. So Credence measures the overnight, weekend and holiday gaps directly.

### 4.3 Gap Cover premium

For a position and each of the N scenarios, the loss to lenders is:

```latex
L_k = \max\Big(0,\ D - qV\,(1+r^{(t)}_k)(1-\kappa)\Big)
```

From these the Risk Engine takes the expected loss and the expected shortfall (the average of the worst (1−β) share of scenarios, β = 97.5%):

```latex
\mathbb{E}[L] = \frac{1}{N}\sum_{k=1}^{N} L_k \qquad\qquad \text{ES}_{\beta} = \text{mean of the worst } (1-\beta)N \text{ values of } L_k
```

The premium is expected loss plus a safety loading, plus the cost of the capital the pool must hold for this policy during the closure, scaled up as the pool fills:

```latex
\pi = m(u)\Big[(1+\theta)\,\mathbb{E}[L] + c\,\tau\,\text{ES}_{\beta}\Big] \qquad m(u) = 1 + \eta\,u^2
```

Illustrative settings: loading θ = 100% (premium = twice expected loss) at launch while history is short; cost of capital c = 15% a year; τ = closure length in years (3/365 for a holiday weekend); η = 4, so a half-full pool (u = 0.5) doubles the price. A minimum premium covers keeper gas.

### 4.4 Pool capacity

The pool must survive the worst weekend in history for **all** its positions at once. For each historical joint weekend k (the gaps of every listed stock on that same weekend), the pool's total loss is:

```latex
\Lambda_k = \sum_{i \in \text{positions}} L_{i,k} \qquad\qquad u = \frac{\max_k \Lambda_k}{J} \qquad\qquad \text{accept new cover only if } u_{\text{after}} \le u_{\max}
```

With u\_max = 50%, the worst replayed weekend could wipe out at most half the pool, leaving the other half for an event worse than history. Because it uses joint scenarios, correlation is built in: a portfolio of five tech stocks uses up capacity much faster than five unrelated ones.

### 4.5 Liquidation sizing, clearing and settlement

**Lot size.** With reserve price R = (1−κ)Pᵒ, the tokens to sell so that health returns to H\* are:

```latex
x = \frac{H^{*} D - q P^{o} LT}{H^{*} R\,(1-\lambda) - P^{o} LT}, \qquad x \leftarrow \min(\max(x,0),\ q)
```

The denominator is positive whenever H\*(1−κ)(1−λ) > LT. With the values above, that is 1.10 × 0.97 × 0.97 = 1.035 > 0.80, so the formula is well defined. It is sized at the reserve price, so any better clearing price leaves the borrower *healthier* than the target.

**Clearing.** Sort revealed bids (q\_j, p\_j) with p\_j ≥ R from highest to lowest price. The asset's lot is Q = Σ x\_i.

```latex
j^{*} = \min\Big\{ j : \sum_{i \le j} q_i \ge Q \Big\} \qquad p^{*} = p_{j^{*}} \qquad Q_{\text{pool}} = \max\Big(0,\ Q - \sum_{j} q_j\Big)
```

If bids run out before Q is filled, every bid is accepted, p\* is the lowest accepted price, and the Underwriter Pool buys Q\_pool at R. The blended price paid for the lot is p̄ = ((Q − Q\_pool)p\* + Q\_pool R) / Q.

**Settlement per position** (proceeds Pᵢ = xᵢ p̄):

| Case | Penalty | Debt after | Result |
| --- | --- | --- | --- |
| Partial sale (xᵢ < qᵢ) | λPᵢ | Dᵢ − (1−λ)Pᵢ | Position stays open, HF ≥ H\* |
| Full close, Pᵢ ≥ Dᵢ | min(λPᵢ, Pᵢ − Dᵢ) | 0 | Borrower refunded what is left |
| Full close, Pᵢ < Dᵢ | 0 | 0 | Shortfall Sᵢ = Dᵢ − Pᵢ goes to the waterfall |

**Waterfall.** For a total shortfall S, with protocol reserve F:

```latex
\text{pool pays } \min(S, J) \qquad \text{reserve pays } \min\big(S - \min(S,J),\ F\big) \qquad \text{senior share price} \times \Big(1 - \frac{S - J - F}{A_{\text{senior}}}\Big) \text{ if } S > J + F
```

**Backstop resale by continuous Gradual Dutch Auction.** Tokens the pool bought are released at rate r\_e per hour, and anyone can buy q of them at a price that decays over time T since the oldest unsold tokens were released (Paradigm's continuous GDA):

```latex
P(q) = \frac{k}{\lambda_d} \cdot \frac{e^{\lambda_d q / r_e} - 1}{e^{\lambda_d T}}
```

k is the starting price (set a little above the live price), and λ\_d is the decay speed. If nobody buys, the price keeps falling until someone does, without a single large sale.

### 4.6 Interest and yields

The borrow rate follows a standard kinked curve on utilisation U (borrowed ÷ supplied):

```latex
r_b(U) = \begin{cases} r_0 + s_1 \dfrac{U}{U^{*}} & U \le U^{*} \\[6pt] r_0 + s_1 + s_2\dfrac{U - U^{*}}{1 - U^{*}} & U > U^{*} \end{cases}
```

The interest is split, with ρ\_J to the Underwriter Pool and ρ\_p to the protocol:

```latex
r_{\text{senior}} = r_b\, U\,(1 - \rho_J - \rho_p) \qquad\qquad \text{APY}_{\text{pool}} = \frac{\rho_J r_b B + \sum \pi + \tfrac{1}{3}\sum \text{penalties} + \text{backstop P\&L} - \text{losses}}{J}
```

B is total borrowed. Example: r₀ = 2%, s₁ = 6%, s₂ = 80%, U\* = 90%, U = 85% gives r\_b = 7.67%. With ρ\_J = ρ\_p = 10%, senior lenders earn 7.67% × 0.85 × 0.80 = 5.21%.

### 4.7 What α means over a year

α is a per-closure probability. Over a year of n weekend-type closures (about 52 weekends plus the holiday weekends), the chance that a loan held at exactly the safe LTV sees any bad debt is:

```latex
p_{\text{year}} = 1 - \prod_{c=1}^{n}(1-\alpha_c) \approx \sum_c \alpha_c
```

With α = 0.1% on about 61 closures that is roughly 6% a year for a loan pinned at the limit. Most loans sit below it, and the pool, not the lender, absorbs the loss in that case. α is a governance parameter, and the backtest (section 9) is what should set it.

## 5. Worked example: Priya's holiday weekend

Priya holds 100 tokenized NVDA at $180 ($18,000) and has borrowed $13,500 (75% LTV) going into a three-day holiday weekend. Weekend Gap Cover costs her about $4.52. The three Monday outcomes below show what the auction and the pool do in each case.

**Assumptions (illustrative, not calibrated).** In place of the historical scenario set, standardised gaps are drawn from a Student-t distribution with 3 degrees of freedom, scaled to unit variance. That gives fat tails similar to real stock gaps. σ = 3% for a normal weekend and 4% for a holiday weekend; α = 0.1%, κ = 3%, LT = 80%, max LTV = 75%, λ = 3%, H\* = 1.10, θ = 100%, c = 15% a year, and the pool is empty (m(u) = 1). All figures were computed exactly under these assumptions.

**Step 1: safe LTV for each closure type**

| Closure | σ | 1-in-1,000 gap G\_α | (1+G\_α)(1−κ) | Safe LTV | Binds at 75%? |
| --- | --- | --- | --- | --- | --- |
| Normal weekend | 3.0% | −17.7% | 79.8% | 75.0% (capped) | No |
| Holiday weekend | 4.0% | −23.6% | 74.1% | 74.1% | Yes |
| Normal weekend, stressed volatility (σ × 1.5) | 4.5% | −26.5% | 71.3% | 71.3% | Yes |

This is the key behaviour: on an ordinary weekend Priya does nothing, but before a holiday weekend, or when markets are nervous, the Bell Check asks her to act.

**Step 2: her three choices at the Bell (holiday weekend)**

| Choice | Cost | Effect |
| --- | --- | --- |
| Repay | $158.72 | LTV 75.0% → 74.1% |
| Add collateral | 1.19 tokens ($214.14) | LTV 75.0% → 74.1% |
| Buy Gap Cover | **$4.52** premium | Keeps 75% LTV; the pool absorbs any shortfall at reopen |

How the $4.52 is built (formula 4.3):

- Lenders only lose if Monday opens below −22.7%. Under the model that happens with probability 0.11%.
- Expected loss E\[L\] = $2.21. With a 100% loading: $4.41.
- Expected shortfall ES₉₇.₅ = $88.20. Capital charge: 15% × 3/365 × $88.20 = $0.11.
- Premium = $4.52, which is 0.033% of her debt for the weekend. Paying that every weekend at holiday-level risk would add about 1.7% a year to her borrowing cost.

She buys the cover.

**Step 3: what Monday's open does**

| Monday open | Price | HF at open | What Credence does | Priya after | Lenders after |
| --- | --- | --- | --- | --- | --- |
| −4% | $172.80 | 1.02 | Nothing. The position is healthy | Keeps all 100 tokens | Untouched |
| −12% | $158.40 | 0.94 | Partial sale of 58.51 tokens in the reopen auction. Assumed clearing price p\* = $156.02 (98.5% of the open, above the $153.65 reserve) | Proceeds $9,129.45, penalty $273.88; debt falls to $4,644.43; keeps 41.49 tokens; HF 1.13 | Fully repaid on the sold part |
| −30% | $126.00 | 0.75 | Full close of all 100 tokens at $124.11. Penalty waived because the position is short | Loses the collateral, owes nothing more (non-recourse) | Proceeds $12,411 plus **$1,089 paid by the Underwriter Pool**; the senior vault loses nothing |

The −12% case shows why the reserve-price sizing matters. The lot was sized as if the auction would clear at the $153.65 floor. It cleared higher, so Priya ended at HF 1.13, above the 1.10 target. The −30% case is the one the pool is paid to carry: $4.52 of premium against a $1,089 payout, in an event this model expects about once in 900 holiday weekends.

## 6. User flows

Six kinds of user touch Credence. Each flow below lists what the user does, which contract call it becomes, and what they see.

The same users over one full week, with every dollar traced end to end: One week of money

### 6.1 Stock-token borrower

1. **Connect and check eligibility.** Robinhood Wallet or any EVM wallet on Robinhood Chain. The app shows which Stock Tokens have a market, each market's max LTV, and the safe LTV for the next closure.
2. **Deposit and borrow** (`addCollateral`, then `borrow` or `borrowWithCover`). The app shows health factor, LTV, the next Bell deadline, and whether this loan will need action before it.
3. **Weekdays.** Nothing is required. Interest accrues every second, and the loan is protected by 60-second batch auctions if the price falls during trading hours.
4. **Bell window opens** (2 hours before a binding close). If the loan is above the safe LTV, the app, email and a push alert show three buttons with exact amounts: Repay $X, Add Y tokens, Buy cover for $Z. The default, if they do nothing, is auto-cover with the premium added to debt.
5. **During the closure.** The app shows the frozen price, the weekend DEX price as information only, and a banner if the stress flag is on. The borrower can always repay or add collateral, can borrow more only up to the safe LTV at the lower price, and cannot be liquidated.
6. **Reopen.** If the open print leaves HF ≥ 1, nothing happens. Otherwise the app shows a countdown: the position can still leave the queue by repaying or adding collateral in the first 2 minutes. After the auction it shows the tokens sold, the clearing price against the open, the penalty and any refund.
7. **Close** (`repay`, then `withdrawCollateral`). Always possible when the debt is zero.

### 6.2 Senior lender

1. **Deposit** USDG or USDC into the Senior Vault (`deposit`), receive vault shares.
2. **Earn** the senior share of borrow interest; the app shows the current rate, utilisation, the pool's size relative to borrows (the lender's cushion), and the protocol reserve.
3. **Withdraw** any time up to idle liquidity (`withdraw`). Larger withdrawals queue and are paid as borrowers repay. Senior lenders are never locked by the clock.
4. **In a loss event** their share price only falls if the pool and reserve are both used up; the risk page shows how far that is.

### 6.3 Gap underwriter

1. **Deposit** into the Underwriter Pool (`deposit`) during REGULAR hours; receive pool shares (ERC-20). Capital joins the next epoch.
2. **Each closure is an epoch.** At the Bell deadline, the app shows exposure for the coming closure: covered positions, the worst replayed weekend loss, utilisation, and premiums already written.
3. **At reopen settlement**, the epoch's premiums, risk fees and penalty share are credited and any losses are debited. The share price moves once, visibly.
4. **Withdraw** by requesting before a Bell window opens (`requestWithdraw`); paid after that epoch settles (`claimWithdraw`). Or sell the pool shares on a DEX for an instant exit.
5. **Backstop inventory.** If the pool bought tokens at a reopen, the app shows the GDA resale in progress and its running profit or loss.

### 6.4 Auction bidder (market maker)

1. **Register.** For permissioned collateral, pass the token issuer's allowlist; for open Stock Tokens, just connect.
2. **Watch.** A public feed (events plus an API) announces each REOPEN lot: asset, quantity Q, open print and reserve.
3. **Commit** in the commit window (`commitBid(hash, maxNotional)` plus a bond of 10% of `maxNotional`), **reveal** in the reveal window (`revealBid(q, p, salt)` plus full payment).
4. **Settle.** Winners receive tokens at p\*; unfilled bids and bonds are returned. Unrevealed commits lose the bond to the pool.
5. **Intraday.** 60-second open batches run during REGULAR hours on the same interface without the commit step.

### 6.5 Keeper

Runs the jobs in 3.9: clock ticks, Bell scan and enforcement, reopen queueing, clearing and NAV settlements. Each call is permissionless and earns a fixed tip. The Credence team runs one keeper from day one, so the protocol never depends on third parties showing up.

### 6.6 Treasury-fund borrower (for example a DAO treasury)

1. **Get allowlisted** by the fund issuer, and make sure the Credence market is an allowlisted holder.
2. **Deposit** BENJI, WTGXX or USTBL; **borrow** up to 90% of NAV in USDC on Arbitrum One. The fund keeps earning its yield while pledged.
3. **Weekends and holidays** need no action for normal positions; the NAV barely moves.
4. **If under water**, the position goes to a settlement-solver auction and is closed at T+0. If no solver bids, the pool advances the cash and waits for redemption itself.
5. **If the issuer gates redemptions**, the market goes to HALTED: no new borrowing, repay always allowed, no forced sale.

## 7. Contracts, storage and tech stack

Phase 1 is nine on-chain components plus three off-chain services. The Solidity side is small and conventional so that audits concentrate on the new logic.

**On-chain components**

| Contract | Language | Key functions | Key storage |
| --- | --- | --- | --- |
| `AssetClock` | Solidity | `poke`, `state`, `closureInfo`, `setCalendar` (timelock), `guardianRestrict` | Per asset: state, closureId, closureType, refPrice, bell/close/reopen times, openPrint; calendar tables |
| `OracleAdapter` | Solidity | `valuationPrice(asset)`, `openPrint(asset)`, `stressFlag(asset)` | Feed addresses, deviation and staleness limits, TWAP pool config, issuer ratio |
| `CredenceMarket` | Solidity | `addCollateral`, `borrow`, `borrowWithCover`, `buyCover`, `repay`, `withdrawCollateral`, `enforceBell`, `flagForAuction` | Market params; per position: collateral, debt shares, lastBellClosure, coverPolicyId; global borrow index |
| `SeniorVault` | Solidity (ERC-4626) | `deposit`, `withdraw`, `allocate` (caps), `absorbLoss` | Total assets, per-market allocations and caps, withdrawal queue |
| `UnderwriterPool` | Solidity (ERC-20 shares) | `deposit`, `requestWithdraw`, `claimWithdraw`, `writeCover`, `payShortfall`, `backstopBuy`, `settleEpoch` | Per epoch: premiums, exposure, losses; share price history; backstop inventory |
| `AuctionHouse` | Solidity | `commitBid`, `revealBid`, `clear`, `settle`, `gdaBuy` | Per auction: lot, reserve, commits, reveals, bonds; GDA state |
| `SettlementAdapter` | Solidity | `settle(position)`, `fallbackAdvance` | Solver venue addresses, floors |
| `RiskEngine` | Rust (Stylus) | `safeLtv`, `bellStatus`, `quoteCover`, `poolCapacity`, `liquidationLot`, `clear`, `updateSigma` | Scenario sets (int16), joint matrix, σ state, risk parameters |
| `Governance` + `Guardian` | Solidity | Timelock, guardian restrictions | Roles, delays, restriction expiry |

**Off-chain services**

| Service | Stack | Job |
| --- | --- | --- |
| Keeper | Rust, sharing the Risk Engine crate natively | All jobs in 3.9; alerts to borrowers before Bell deadlines |
| Indexer + API | Rust or TypeScript indexer, Postgres | Positions, auctions, epochs, the public risk page, the bidder feed |
| Web app | Next.js, viem, wagmi | Borrow, lend, underwrite, bid; clear Bell prompts with exact amounts |
| Calibration pipeline | Python notebooks + the Rust crate | Builds scenario sets from 20+ years of close-to-open data, runs the backtest, produces governance proposals |

**Testing plan**

- Foundry unit, fuzz and invariant tests. Core invariants: total debt ≤ total supplied; a position is never liquidated in CLOSED; repay never reverts for a valid amount; the pool never writes cover past u\_max; epoch accounting sums to zero across premiums, payouts and share price.
- Differential tests: the Stylus build and the native build of the Risk Engine must return identical outputs on millions of random inputs.
- A historical replay: every real weekend since 2000 run through the full contract stack on a fork, using a synthetic book of positions.
- Two independent audits, one focused on the Stylus code, before mainnet. Arbitrum's audit subsidy program can fund part of this.

**Deployment layout (phase 1)**

| Chain | Markets | Loan token |
| --- | --- | --- |
| Arbitrum One | Treasury funds (BENJI, WTGXX, USTBL) | USDC |
| Robinhood Chain | 3–5 large Stock Tokens plus an S&P 500 ETF token | USDG |

Each chain has its own Senior Vault and Underwriter Pool; there is no cross-chain messaging in phase 1. Whether Stylus is enabled on Robinhood Chain must be confirmed (section 9). If it is not, the Risk Engine there runs as the same Rust logic ported to Solidity with smaller scenario sets.

## 8. Failure modes and safeguards

The biggest residual risk is a gap worse than anything in the scenario set, and the only full defence against it is size limits. Every other failure mode below has a specific mechanism that contains it.

| Failure | What would happen | Safeguard |
| --- | --- | --- |
| Gap worse than history (a 1987-style crash on a Monday, or fraud news on one stock) | Pool loses heavily; possibly reserve and senior too | Pool utilisation cap of 50% on the worst replayed weekend; per-asset and per-market caps; 100% premium loading at launch; single-name concentration limits |
| Several stocks gap together | Losses correlate across markets | Capacity uses *joint* historical weekends, so correlation is priced in |
| Wrong or stale opening print | Wrong liquidations at reopen | Two-feed cross-check; REOPEN waits up to 15 min; then a 5-minute TWAP fallback |
| Weekend DEX price manipulated | Borrowers griefed | The `min()` rule lets it only reduce new borrowing; no liquidations in CLOSED |
| Borrower acts on Saturday news | Borrows against a stale Friday price | `min(frozen, DEX TWAP)` valuation and the safe-LTV limit in CLOSED; no cover sales after the Bell deadline |
| Underwriters flee before a risky weekend | Pool too thin when needed | Withdrawals must be requested before the Bell window and are paid after settlement; epoch accounting |
| No bidders at reopen | Collateral cannot be sold | Pool buys the remainder at the reserve and resells by GDA |
| Bidders collude to bid low | Borrowers lose value | Reserve price at 97% of the open; the pool backstop makes low bids pointless; every clearing price vs the open is published |
| Timeboost or ordering advantage | Fast players win liquidations | Commit–reveal at reopen; uniform price; minute-long windows |
| Sequencer outage around the open | Nobody can act on time | REOPEN phases extend by the outage length, plus a grace period before any auction step |
| Keeper offline | Enforcement or auctions late | All jobs permissionless with tips; the team runs a keeper; lazy `poke()` on every call |
| Issuer freezes a token, or removes a borrower from its allowlist | Collateral cannot move | Asset goes to HALTED; liquidation routes through the issuer's own process or settlement solvers |
| Split or other corporate action mishandled | Price and balances misaligned | CORP. ACTION state freezes the market until the adjusted feed is confirmed; issuer-ratio changes capped |
| Stylus Risk Engine bug | Mispriced cover or wrong limits | Holds no funds; every call fails closed; differential tests against the native build; a dedicated audit |
| Unexpected market closure (a national day of mourning, an exchange outage) | Calendar says open, market is shut | Oracle staleness moves the asset to HALTED automatically; the guardian can extend CLOSED |
| Volatility estimate too low after a calm spell | Safe LTV too loose | σ floor at the long-run 25th percentile; σ falls at most 10% a day; loading θ |
| Jurisdiction limits on Stock Tokens | Legal exposure | Follow each issuer's eligibility rules in the app; legal review before listing |

## 9. Open questions to resolve before build

The architecture is complete enough to start the contracts, but six facts decide whether phase 1 launches with stocks, funds or both.

- [ ] **Backtest.** Build the scenario sets from 20+ years of close-to-open data for the first 5 assets; replay every weekend since 2000 against a synthetic book; set α, κ and θ from the results.
- [ ] **Stylus on Robinhood Chain.** Confirm that Stylus contracts can be deployed there. If not, choose between a Solidity port of the Risk Engine and launching stocks on Arbitrum One instead.
- [ ] **Stock Token transfer rules.** Do Robinhood's Stock Tokens enforce holder eligibility in the token contract? This decides whether the Auction House needs allowlist checks for them.
- [ ] **Opening-print source.** Confirm the feed can deliver the regular-session opening price with a timestamp that the clock can verify.
- [ ] **Issuer allowlisting.** Start conversations with Franklin Templeton (BENJI), WisdomTree (WTGXX) and Spiko (USTBL) about allowlisting the Credence market contract as a holder.
- [ ] **Settlement solver integration.** Confirm RedStone Settle's and Upshift Clear's supported assets and chains, and the integration interface for a new lending protocol.
- [ ] **Legal review** of lending against Stock Tokens (tokenized debt securities issued from Jersey), including which user jurisdictions the app must exclude.
- [ ] **Prior-art check** on reversible call options for liquidation protection (Qin et al., 2023) and on Ethosis's closed-market rules, to position Gap Cover clearly against both.

## Sources

- [French & Roll (1986), Stock return variances, Journal of Financial Economics](https://www.sciencedirect.com/science/article/abs/pii/0304405X86900048)
- [Budish, Cramton & Shim (2015), Frequent Batch Auctions, QJE](https://academic.oup.com/qje/article/130/4/1547/1916146)
- [Qin et al. (2021), An Empirical Study of DeFi Liquidations](https://arxiv.org/abs/2106.06389)
- [Paradigm, Gradual Dutch Auctions (2022)](https://www.paradigm.xyz/2022/04/gda)
- [Paradigm, Blend (2023)](https://www.paradigm.xyz/writing/blend)
- [Messias & Torres, Empirical analysis of Arbitrum's Timeboost](https://arxiv.org/abs/2509.22143)
- [Arbitrum Docs, A gentle introduction to Stylus](https://docs.arbitrum.io/stylus/gentle-introduction)
- [Chainlink Docs, Tokenized Equity Feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds)
- [RedStone Settle](https://www.redstone.finance/settle/)
- [Upshift Clear launch (Modern Consensus)](https://modernconsensus.com/cryptocurrencies/upshifts-new-vault-platform-allows-instant-rwa-redemption/)
- [ERC-7540, ethereum.org](https://ethereum.org/developers/docs/standards/tokens/erc-7540)
- [Aave Horizon documentation](https://aave.com/docs/aave-v3/horizon)
- [Coinpaprika, RWA credit risk and tranching (Centrifuge DROP/TIN)](https://coinpaprika.com/education/rwa-credit-risk-defi/)
- [Coinpaprika, RWA as DeFi collateral](https://coinpaprika.com/education/rwa-as-defi-collateral/)
- [Aave V4 Equities Hub analysis (collateral factors, 24/5 feeds)](https://github.com/Ricosworks1/blockchain-payment-flow-analysis/releases/tag/market-update-aave-v4-equities-hub-tokenized-stocks-sept-2026)
- [CryptoSlate, how tokenized stocks fail as collateral (Edel exploit)](https://cryptoslate.com/how-tokenized-stocks-fail-as-collateral-even-when-the-stock-price-does-not-move/)
- [Ethosis](https://www.ethosis.org/)
- [Arbitrum Foundation, 2025 year in review (STEP)](https://blog.arbitrum.foundation/arbitrum-in-2025-the-year-of-everywhere/)
