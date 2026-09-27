# One week of money in Credence Finance

Sep 26, 2026 · @Akash Biswas

> **Rev 2.** Renamed from Kairos to Credence Finance. Every figure was re-checked against the Architecture formulas. This is scenario A (a 30% single-stock crash, a pre-close sale and a covered full close); *One week of money flow* is scenario B. Build decisions that refine these flows are in `CREDENCE_BUILD_GUIDE.md` §2.

One simulated week on a small Credence market, from one Monday to the next, following every dollar between seven users and the protocol's own accounts. All numbers are illustrative and computed exactly from the formulas in the main tab.

## The cast and the setup

Seven people and three protocol accounts take part in one week on Robinhood Chain. The week ends with a 30% Monday crash in one stock, so every money path in Credence gets used at least once.

| Who | Role | Starts with | What they do this week |
| --- | --- | --- | --- |
| **Lena** | Senior lender | $230,000 USDG | Deposits into the Senior Vault on Monday |
| **Uma** | Gap underwriter | $40,000 USDG | Deposits into the Underwriter Pool on Monday |
| **Rahul** | Borrower | 500 AAPL tokens ($100,000) | Borrows $60,000 on Monday (60% LTV) |
| **Maya** | Borrower | 300 TSLA tokens ($75,000) | Borrows $55,500 on Tuesday (74% LTV); has turned auto-cover off |
| **Priya** | Borrower | 500 NVDA tokens ($90,000) | Borrows $67,000 on Wednesday (74.4% LTV) |
| **Mo** | Market maker, auction bidder | $200,000 USDG | Bids in Friday's pre-close sale and Monday's auction |
| **Omar** | Market maker, auction bidder | $200,000 USDG | Bids in Monday's auction |
| **Kai** | Keeper | $0 | Calls the public keeper functions and earns tips |
| Senior Vault | Protocol account | $0 | Holds lenders' money, lends it out |
| Underwriter Pool | Protocol account | $0 | First-loss capital; sells Gap Cover |
| Treasury / Reserve | Protocol accounts | $1,000 / $0 | Collect fees and penalties; the treasury pays keeper tips |

**Market setup.** Friday closing prices: AAPL $200, TSLA $250, NVDA $180. Max LTV 75%, liquidation threshold 80%, liquidation penalty 3% (1% for a pre-close sale), α = 0.1%, κ = 3%, target health factor 1.10.

**Interest.** With $182,500 borrowed out of $230,000 supplied, utilisation is 79.3% and the borrow rate is 7.29% a year (formula 4.6 on the main tab). For simplicity it is held at that level all week. Interest is split 80% to the Senior Vault, 10% to the Underwriter Pool and 10% to the protocol treasury.

**Gap model.** Same stand-in as the main tab's worked example: a fat-tailed Student-t distribution in place of the historical scenario set.

## Money map

All money in Credence moves along 17 paths between 9 parties. Borrowers' interest feeds three accounts, premiums and penalties feed the pool, and the pool pays out only when an auction falls short.

&#91;embedded content: money map · 9 parties, 17 money paths\]

Two paths are not drawn, to keep the picture readable: the Underwriter Pool also receives one-third of every liquidation penalty (the Auction House splits it three ways), and the pool can buy unsold collateral at the reserve price (the backstop). Neither is used in the base case below except the penalty split.

| Money path | From → to | When it happens | This week |
| --- | --- | --- | --- |
| Deposit | Lena → Senior Vault | Any time | $230,000.00 |
| Pool capital | Uma → Underwriter Pool | REGULAR hours; joins the next epoch | $40,000.00 |
| Loans | Senior Vault → borrowers | On `borrow` | $182,500.00 |
| Gap Cover premium | Priya → Underwriter Pool | Before the Bell deadline | $35.95 |
| Pre-close sale payment | Mo → Auction House | Friday 15:45–16:00 batch | $23,559.96 |
| Debt repaid from sales | Auction House → Senior Vault | At settlement | $85,379.36 |
| Penalty split | Auction House → pool, reserve, treasury (⅓ each) | At settlement, only if solvent | $78.53 each |
| Interest actually paid | Borrowers → Senior Vault | On any repayment | $102.72 |
| Risk fee (10% of paid interest) | Senior Vault → Underwriter Pool | On each repayment | $10.27 |
| Protocol fee (10% of paid interest) | Senior Vault → treasury | On each repayment | $10.27 |
| Reopen auction payments | Mo, Omar → Auction House | Monday 09:37 | $62,055.00 |
| Shortfall payout | Underwriter Pool → Senior Vault | At settlement | $5,011.69 |
| Keeper tips | Treasury → Kai | After each keeper call | $16.00 |

"Debt repaid from sales" is Maya's $23,324.36 from Friday plus the whole $62,055 from Monday. The Friday figure is her sale proceeds minus the 1% penalty; on Monday Priya was short, so the penalty was waived. Interest still sitting unpaid inside Rahul's and Maya's debt ($101.28) is not in the table; it is money owed, not yet moved.

## The week at a glance

Nothing dramatic happens until Thursday's news. From then on each day moves real money: Friday's Bell, a weekend where nothing may be liquidated, and a Monday auction that settles in seven minutes.

&#91;embedded content: one week · 7 days, 1 epoch\]

## Monday to Thursday: money goes in, loans go out

By Wednesday afternoon, $182,500 of Lena's $230,000 is lent out, and the Senior Vault holds $47,500 in cash. From then on the only thing moving is interest, which accrues inside each loan and is not paid in cash until someone repays.

| When | Who | Action (contract call) | Money moves | Vault cash after | Pool after | Position after |
| --- | --- | --- | --- | --- | --- | --- |
| Mon 10:00 | Lena | `SeniorVault.deposit(230,000)` | $230,000 Lena → vault; she gets 230,000 shares at $1.00 | $230,000 | — | — |
| Mon 10:00 | Uma | `UnderwriterPool.deposit(40,000)` | $40,000 Uma → pool; she joins this weekend's epoch because it is before the Bell window | $230,000 | $40,000 | — |
| Mon 10:00 | Rahul | `addCollateral(500 AAPL)`, `borrow(60,000)` | 500 AAPL Rahul → market; $60,000 vault → Rahul | $170,000 | $40,000 | LTV 60.0%, HF 1.33 |
| Tue 10:00 | Maya | `addCollateral(300 TSLA)`, `borrow(55,500)` | 300 TSLA → market; $55,500 vault → Maya | $114,500 | $40,000 | LTV 74.0%, HF 1.08 |
| Wed 10:00 | Priya | `addCollateral(500 NVDA)`, `borrow(67,000)` | 500 NVDA → market; $67,000 vault → Priya | $47,500 | $40,000 | LTV 74.4%, HF 1.07 |
| Every weeknight | Everyone | Bell Check runs automatically | None: each overnight safe LTV is above 75%, so nobody must act | — | — | — |
| Thu 17:00 | Kai | `RiskEngine.updateSigma(…)`, signed by the oracle committee | None | — | — | Weekend safe LTVs tighten (below) |

**Interest, accruing, not moving.** At 7.29% a year, Rahul's debt grows $11.98 a day, Maya's $11.08 and Priya's $13.38. The borrow index rises every second, and so does the value of Lena's vault shares (by 80% of that accrual) and of Uma's pool shares (by 10%). No cash changes hands until a loan is repaid, sold down or closed.

**Thursday's news.** A sector-wide headline pushes volatility up, and Kai's daily update raises every stock's weekend gap scale by 1.5×. The Risk Engine recomputes the weekend's safe LTVs (formula 4.2):

| Stock | Weekend σ | 1-in-1,000 gap | Safe LTV | Who is affected |
| --- | --- | --- | --- | --- |
| AAPL | 3.0% | −17.7% | 75.0% (capped at max LTV) | Rahul at 60%: safe |
| NVDA | 4.5% | −26.5% | 71.26% | Priya at 74.5%: must act Friday |
| TSLA | 6.0% | −35.4% | 62.68% | Maya at 74.0%: must act Friday |

The app sends Priya and Maya a heads-up on Thursday evening with the exact amounts they will need on Friday.

## Friday: the Bell

Three borrowers leave Friday three different ways. Rahul does nothing. Priya pays $35.95 to keep her loan as it is. Maya does nothing either, but she is over the line and has auto-cover off, so the protocol sells 94.43 of her TSLA tokens before the close.

**14:00, the Bell window opens.** Debts now include four, three and two days of interest.

| Borrower | Debt | Collateral value | LTV | Safe LTV | Status | Cure options shown in the app |
| --- | --- | --- | --- | --- | --- | --- |
| Rahul | $60,049.93 | $100,000 | 60.05% | 75.00% | SAFE | None needed |
| Priya | $67,028.99 | $90,000 | 74.48% | 71.26% | NEEDS\_ACTION | Repay $2,896.78 **or** add 22.58 NVDA **or** buy cover for $35.95 |
| Maya | $55,535.10 | $75,000 | 74.05% | 62.68% | NEEDS\_ACTION | Repay $8,527.09 **or** add 54.42 TSLA **or** buy cover (auto-cover is off) |

**15:30, Priya buys Gap Cover** (`buyCover`). She pays $35.95 in USDG from her wallet to the Underwriter Pool. How the premium is built (formula 4.3):

- Her lenders lose money only if NVDA opens Monday below −23.22%; the model puts that at 0.148%.
- Expected loss $15.12; expected shortfall (worst 2.5%) $604.99.
- The pool is 20% utilised after this policy, so the price multiplier is 1 + 4 × 0.2² = 1.16.
- Premium = 1.16 × (2 × $15.12 + 15% × 3/365 × $604.99) = **$35.95**.

The premium sits in the pool but belongs to this epoch; Uma is credited with it only after Monday's settlement.

**15:45, Bell deadline.** Maya has done nothing. Kai calls `enforceBell([Maya])` and earns a $3 tip from the treasury. Maya has auto-cover off, so her position goes to the pre-close sale.

**15:45–16:00, pre-close batch.** The Risk Engine sizes the sale so that Maya lands exactly at the 62.68% safe LTV after a 1% penalty:

- Debt at 16:00: $55,536.02. Tokens to sell: **94.4287 TSLA**.
- Mo bids and the batch clears at **$249.50** (TSLA is trading at $250). Mo pays $23,559.96 and receives 94.4287 TSLA.
- Penalty 1% = $235.60, split three ways: **$78.53** each to the Underwriter Pool, the protocol reserve and the treasury.
- The remaining $23,324.36 repays Maya's debt: first the $36.02 of accrued interest (the vault keeps $28.82, and forwards $3.60 to the pool and $3.60 to the treasury), then $23,288.34 of principal.
- Maya is left with 205.57 TSLA and $32,211.66 of debt: LTV 62.68%, exactly safe.
- Kai calls `clear()` on the batch: another $5 tip.

**16:00, the close.** The clock freezes the reference prices and opens the epoch. Balances going into the weekend:

| Account | Cash | Change on Friday |
| --- | --- | --- |
| Senior Vault | $70,817.16 | +$23,317.16 (Maya's repayment, less the $7.20 of fees forwarded) |
| Underwriter Pool | $40,118.09 | +$35.95 premium, +$78.53 penalty, +$3.60 risk fee |
| Reserve | $78.53 | +$78.53 penalty |
| Treasury | $1,074.14 | +$78.53 penalty, +$3.60 fee, −$8 tips |

Uma's $40,118.09 is now locked until the epoch settles; any withdrawal she wanted this week had to be requested before 14:00.

## Saturday and Sunday: bad news, and no money moves

NVDA's token falls 23% on the weekend DEX after Saturday news, and Priya's position would be liquidated on any ordinary lending protocol. In Credence not a single dollar moves all weekend, because a weekend price can lower what people may borrow but can never trigger a sale.

| When | What happens | Effect on money |
| --- | --- | --- |
| Fri 20:00 | 24/5 feed stops; the clock moves every market to CLOSED | None |
| Sat 11:00 | News hits; the NVDA token's 1-hour DEX TWAP falls to $138 (−23% vs Friday's $180) | None. The valuation price becomes min($180, $138) = $138 |
| Sat 11:00 | $138 is below 90% of the frozen close, so the **stress flag** turns on for NVDA | New NVDA borrowing paused; banner in the app; keepers alerted |
| Sat–Sun | Priya's health factor at $138 is about 0.82 | **No liquidation**: the market is CLOSED. She may repay or add collateral if she wants to; she does neither |
| Sat–Sun | TSLA's DEX TWAP drifts to $236; Maya's LTV at that price is about 66% | She cannot borrow more (above the 62.68% safe LTV at the lower price), but nothing is forced |
| Sat–Sun | AAPL's TWAP is about $197 | No effect on Rahul |
| Sun 20:00 | 24/5 feed resumes (EXTENDED). NVDA trades thinly around $129 overnight; Priya's health factor is about 0.77 | Below the 0.92 emergency line, but Priya's loan is **covered**, so it waits for the regular open. Uncovered, she would be sold into this thin overnight market |
| Mon 04:00–09:30 | Pre-market: NVDA around $127, TSLA $231, AAPL $195 | Monitoring only |

**What each person can do during the weekend**

| Person | Can | Cannot |
| --- | --- | --- |
| Lena | Withdraw from the vault, up to its $70,817.16 of idle cash | — |
| Uma | Sell her pool shares on a DEX (the buyer takes on the epoch's risk) | Withdraw from the pool; her capital is locked until settlement |
| Borrowers | Repay, add collateral, borrow within the safe LTV at the lower price | Buy cover; borrow against Friday's stale price |
| Mo, Omar | Prepare bids for Monday | Buy any collateral; nothing is for sale |
| Kai | Keep `poke()`-ing the clock | Trigger any liquidation |

## Monday: reopen, auction and settlement

NVDA opens 30% down. Priya's whole position is auctioned in seven minutes at one price, $124.11; the $5,011.69 gap between that and her debt is paid by the Underwriter Pool; and Lena does not lose a cent.

**09:30, open prints** (each cross-checked against the second feed): NVDA **$126** (−30%), TSLA **$230** (−8%), AAPL **$194** (−3%). The clock enters REOPEN.

| Borrower | Debt at 09:37 | Collateral at the open | Health factor | Outcome |
| --- | --- | --- | --- | --- |
| Rahul | $60,083.69 | 500 × $194 = $97,000 | 1.29 | Nothing happens |
| Maya | $32,229.25 | 205.57 × $230 = $47,281.40 | 1.17 | Nothing happens. Friday's sale kept her safe |
| Priya | $67,066.69 | 500 × $126 = $63,000 | 0.75 | Queued for the reopen auction |

**The auction, minute by minute**

| Time | Step | Detail |
| --- | --- | --- |
| 09:30:05 | Queue | Kai calls `flagForAuction(Priya)`; the contract verifies HF < 1 at the open. Tip: $3 |
| 09:32 | Size the lot | The formula in 4.5 asks for 789 tokens, more than she has, so it is a **full close**: lot = 500 NVDA. Reserve R = 97% × $126 = $122.22 |
| 09:32–09:35 | Commit | Mo commits 300 @ $124.40 (bond $3,732); Omar commits 300 @ $124.11 (bond $3,723.30). Neither can see the other's bid |
| 09:35–09:37 | Reveal | Both reveal and escrow full payment |
| 09:37 | Clear | Sorted by price: Mo's 300 fill first, then 200 of Omar's 300. The lowest accepted price is $124.11, so **both pay $124.11**. Mo pays $37,233 (not $37,320); Omar pays $24,822, and his unfilled 100 and both bonds are returned. Kai's tip: $5 |

&#91;embedded content: Monday settlement · debt paid from auction plus pool\]

**Settlement, at 09:37**

1. Auction proceeds: $62,055. That is less than Priya's debt of $67,066.69, so the position is fully closed and the 3% penalty is **waived**. Every dollar of proceeds goes to the debt.
2. Shortfall: $67,066.69 − $62,055 = **$5,011.69**. Priya was covered, so the waterfall starts at the Underwriter Pool, which pays all of it (it had $40,118.09). The protocol reserve and the Senior Vault are untouched.
3. The Senior Vault receives $67,066.69 in total. The $66.69 that was interest is split: $53.35 stays with the vault for senior lenders, $6.67 to the pool, $6.67 to the treasury.
4. Priya receives nothing and owes nothing: the loan is non-recourse. 300 NVDA go to Mo and 200 to Omar.
5. The epoch settles. The pool's premium ($35.95), penalty share ($78.53) and risk fees ($10.27 paid, $10.13 accrued) are credited, and the payout ($5,011.69) is debited. The pool's share price moves once: Uma's $40,000 is now worth **$35,123.19**.
6. The clock moves NVDA, TSLA and AAPL to REGULAR. NVDA's stress flag clears once the live price is back and the feeds agree.
