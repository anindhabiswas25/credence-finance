# One week of money flow

Sep 27, 2026 · @Akash Biswas

> **Rev 2.** Renamed from Kairos to Credence Finance. Every figure was re-checked against the Architecture formulas. This is scenario B (a stressed week with an intraday liquidation and a backstop purchase); *One week of money in Credence Finance* is scenario A (a 30% single-stock crash). Build decisions that refine these flows are in `CREDENCE_BUILD_GUIDE.md` §2.

This tab follows ten Credence Finance users in five roles through one week, from Monday's open to the next Monday's reopen auction, and traces every dollar. The week has an intraday liquidation on Thursday, a nervous weekend, and a Monday where two stocks open sharply lower. Every figure was computed from the formulas in the Architecture tab, and all of them are illustrative.

## 1. The cast and where money starts

The week runs on one Credence deployment on Robinhood Chain, lending USDG against Stock Tokens. Everyone below is a separate wallet; the protocol's own accounts are listed at the end.

| User | Role | Starting position | What they do this week |
| --- | --- | --- | --- |
| **Priya** | Borrower | 100 NVDA tokens at $180 ($18,000) | Borrows $13,500 on Monday, buys Gap Cover on Friday |
| **Dev** | Borrower | 100 COIN tokens at $300 ($30,000); owes $22,500 (75%) | Ignores the Bell, gets auto-covered, is fully liquidated on Monday |
| **Ben** | Borrower | 50 TSLA tokens at $400 ($20,000); owes $14,800 (74%) | Partially liquidated in a Thursday intraday batch |
| **Rahul** | Borrower | 500 S&P 500 ETF tokens at $600 ($300,000); owes $150,000 (50%) | Nothing; he is always safe |
| Other borrowers | Borrowers | Owe $599,200 in total | Background: pay interest, some buy cover |
| **Lena** | Senior lender | $200,000 USDG | Deposits into the Senior Vault on Monday |
| **Umar** | Underwriter | $20,000 USDG | Deposits into the Underwriter Pool on Wednesday |
| **Sara** | Underwriter | 10,000 pool shares (worth $10,000) | Requests a withdrawal on Wednesday |
| **Aria Capital** | Auction bidder (market maker) | USDG inventory | Buys collateral in Thursday's and Monday's auctions |
| **Zed** | Auction bidder | USDG | Commits a bid on Monday but never reveals it |
| **Kai** | Keeper | A bot and gas | Runs the Bell enforcement, queueing and clearing calls |

**Protocol accounts at Monday 09:30**

| Account | Balance | Funded by |
| --- | --- | --- |
| Senior Vault | $800,000 supplied by earlier lenders (+ Lena's $200,000 on Monday = $1,000,000) | Lenders |
| Underwriter Pool | $80,000 (+ Umar's $20,000 on Wednesday = $100,000); share price $1.00 | Underwriters |
| Protocol reserve | $20,000 | Past fees |
| Protocol treasury | $0 | — |

**Settings for the week.** Borrowing is $800,000 against $1,000,000 supplied, so utilisation is 80% and the borrow rate is 7.33% a year (held flat all week for simplicity). Interest splits 80% to the Senior Vault, 10% to the Underwriter Pool and 10% to the treasury. Max LTV is 75%, liquidation threshold 80%, penalty 3%, reserve price 97% of the open, target health factor 1.10. Markets were volatile this week, so the weekend volatility scale is stressed at 4.5%. That puts the weekend safe LTV at **71.3%**, so the Bell Check binds for any loan above that.

## 2. Money map: who pays whom

All money in Credence moves along the arrows below. Borrowers pay for loans with interest and, before risky closures, with premiums. That income is split between the people who take risk: senior lenders get most of the interest, and underwriters get a slice of interest plus all the premiums. In return, underwriters pay when a Monday goes badly (the orange arrow).

&#91;embedded content: money map · 5 user groups, 5 contracts, 16 flows\]

Rounded boxes are people; square boxes are contracts. Borrowers never pay underwriters directly: premiums, interest and repayments all pass through the Lending Market, which forwards each to its owner.

**Every flow on the map**

| # | Flow | From → To | When | How much |
| --- | --- | --- | --- | --- |
| 1 | Deposit | Lender → Senior Vault | Any time | Lender's choice |
| 2 | Senior interest | Market → Senior Vault (share price rises) | Every second, as debt accrues | 80% of borrow interest |
| 3 | Loan | Senior Vault → Market → Borrower | On `borrow` | Up to max LTV (or safe LTV near a closure) |
| 4 | Collateral | Borrower → Market | On `addCollateral` | Stock Tokens, held by the Market |
| 5 | Repayment | Borrower → Market → Senior Vault | On `repay`, or from auction proceeds | Principal + interest |
| 6 | Premium | Borrower → Market → Underwriter Pool | Bell window, or added to debt by auto-cover | Formula 4.3 |
| 7 | Risk fee | Market → Underwriter Pool | Every second, as debt accrues | 10% of borrow interest |
| 8 | Protocol fee | Market → Treasury | Every second | 10% of borrow interest |
| 9 | Underwriter deposit / withdrawal | Underwriter ↔ Pool | Deposit any REGULAR hour; withdrawal after an epoch settles | Share price at the time |
| 10 | Collateral to auction | Market → Auction House | When a position is flagged | Lot size, formula 4.5 |
| 11 | Bid payment | Bidder → Auction House | At reveal | Quantity × clearing price |
| 12 | Tokens won | Auction House → Bidder | At settlement | Filled quantity |
| 13 | Sale proceeds | Auction House → Market | At settlement | Repays debt; surplus refunded to the borrower |
| 14 | Penalty | Auction House → Pool, reserve, treasury (one-third each) | At settlement, only if solvent | 3% of proceeds |
| 15 | Shortfall cover | Pool → Market → Senior Vault | At settlement, if proceeds < debt | Debt minus proceeds |
| 16 | Keeper tips | Treasury → Keeper | On each successful keeper call | Fixed tip, $2 in this example |

Two flows are not drawn to keep the map readable: the Underwriter Pool paying the Auction House when it backstops an unsold lot, and bidders' forfeited bonds going to the pool. Both appear in the Monday numbers below.

## 3. The week, day by day

Most of the week is quiet: interest accrues every second and nobody has to do anything. The money moves in three bursts: Thursday's intraday liquidation, Friday's Bell, and Monday's reopen.

&#91;embedded content: one week · 5 user lanes × 7 days\]

Empty cells mean that user did nothing that day. Interest keeps accruing for everyone all week: about $160 a day across the $800,000 book, split $128 to the Senior Vault, $16 to the pool and $16 to the treasury.

### Monday: money goes out as loans

1. **09:30 Lena deposits** $200,000 USDG into the Senior Vault and receives 200,000 vault shares at $1.00. The vault now holds $1,000,000.
2. **10:00 Priya deposits** 100 NVDA tokens ($18,000) and **borrows** $13,500 USDG (75% LTV). The market is in REGULAR hours before any Bell window, so the limit is the 75% max LTV. Money path: Senior Vault → Market → Priya's wallet.
3. Total borrowing is now $800,000 of $1,000,000: 80% utilisation, 7.33% a year.
4. **16:00 close → overnight.** The weeknight safe LTV is above 75%, so no Bell action is needed tonight or on any weeknight this week.

### Tuesday: nothing but interest

No one acts. Priya's debt grows by about $2.71 a day; Rahul's by $30.14 a day.

### Wednesday: underwriters move

1. **Umar deposits** $20,000 into the Underwriter Pool and receives 20,000 pool shares at $1.00. He deposited before Friday's Bell window, so his capital counts for this weekend's epoch: it will earn this weekend's premiums and share this weekend's losses. The pool is now $100,000.
2. **Sara requests a withdrawal** of her 10,000 pool shares (`requestWithdraw`). No money moves yet. Her request is in before the Bell window, so she will be paid **after** the weekend settles, at the post-weekend share price. She cannot escape a risk that has already been underwritten.

### Thursday: an intraday liquidation

1. **13:00** TSLA falls 9% intraday to $364. Ben's debt with interest is $14,809.35 against $18,200 of collateral: health factor 0.98.
2. **Kai calls** `flagForAuction(Ben)` and earns a $2 tip. The Risk Engine sizes the lot: **20.23 TSLA**, just enough to restore health to 1.10 at the reserve price.
3. **60-second batch auction.** Aria bids and the batch clears at $362.18 (99.5% of the live price). Aria pays **$7,326.43** and receives 20.23 TSLA. Kai calls `clear` (+$2).
4. **Settlement.** The 3% penalty of $219.79 is split three ways: $73.26 to the pool, $73.26 to the reserve and $73.26 to the treasury. The remaining $7,106.64 repays Ben's debt and goes back to the Senior Vault. Ben now owes $7,702.72, keeps 29.77 TSLA, and his health factor is 1.13.

### Friday: the Bell

The week has been volatile, so the Risk Engine's weekend volatility scale is 4.5% and the weekend safe LTV is **71.3%**.

1. **14:00 Bell window opens.** Kai's scan finds every position above 71.3% and the app alerts them.
2. **Priya** (debt $13,511.58, LTV 75.06%) sees two choices: repay $685.14, or buy Gap Cover for **$6.53**. She buys cover. Money path: Priya → Market → Underwriter Pool.
3. **Other borrowers** above the line buy cover worth $280 between them; a few repay instead.
4. **Rahul** (50% LTV) is already safe and sees nothing.
5. **Dev** (LTV 75.06%) ignores the alert.
6. **15:45 Bell deadline.** Kai calls `enforceBell` on the 6 positions still out of line (+$12). The pool has room, so **Dev is auto-covered**: the Senior Vault lends the $10.89 premium on his behalf, it is added to his debt (now $22,530.19), and the pool receives it.
7. **Pool total for the epoch:** $297.42 in premiums; the capacity check passes.
8. **16:00 close, 20:00 CLOSED.** Reference prices freeze: NVDA $180, COIN $300.

### Saturday and Sunday: nothing can be liquidated

1. **Saturday.** A crypto sell-off hits the news and COIN's weekend DEX price falls 14%, which trips the stress flag: new borrowing against COIN is paused. NVDA's weekend DEX price drifts 8% lower on a rumour.
2. **The min-price rule works.** NVDA collateral is now valued at min($180, $165.60) = $165.60. A holder who tries to borrow more against NVDA on Saturday is capped at the safe LTV of that lower value. No Friday-price free option exists.
3. **No liquidations.** Priya and Dev can both repay or add collateral if they want to. Neither does.
4. **Sunday 20:00.** The 24/5 feed resumes. Both Priya and Dev are covered, so they are not eligible for emergency liquidation on thin overnight prices. Their positions wait for Monday's regular open.

### Monday: the reopen

The reopen auction and its settlement are broken down in full in the next section.

## 4. Monday reopen, in numbers

NVDA opens 12% down and COIN opens 25% down. Two auctions clear by 09:37: Priya loses 59 of her 100 NVDA tokens but keeps her loan, and Dev loses all his COIN while the Underwriter Pool pays the $672.59 his collateral could not cover. Senior lenders get back every dollar they are owed.

**Opening prints and health.** NVDA $158.40 (−12%), COIN $225.00 (−25%). TSLA and the S&P 500 ETF open within 1.5%, so Ben and Rahul stay healthy.

| Position | Debt at 09:30 (with interest) | Collateral at the open | Health factor | Action |
| --- | --- | --- | --- | --- |
| Priya | $13,519.02 | 100 NVDA × $158.40 = $15,840 | 0.94 | Queued; partial sale |
| Dev | $22,542.59 | 100 COIN × $225.00 = $22,500 | 0.80 | Queued; the lot formula asks for 128.6 tokens, more than he has, so a full close |

**The auction timeline**

| Time | Step | Money |
| --- | --- | --- |
| 09:30 | Clock writes the open prints; Kai flags Priya and Dev | Kai +$4 |
| 09:32 | Lots fixed: 59.08 NVDA (reserve $153.65), 100 COIN (reserve $218.25) | — |
| 09:32–09:35 | Commit phase. Aria commits on both lots. Zed commits a COIN bid with an $86 bond | Bonds locked |
| 09:35–09:37 | Reveal phase. Aria reveals and escrows payment. Zed never reveals | Aria escrows $22,357.15 |
| 09:37 | Clear. NVDA: Aria fills all 59.08 at **$156.02**. COIN: bids at or above the reserve cover only 60 tokens (Aria at $219.00), so the pool buys the other 40 at the $218.25 reserve | Pool pays $8,730.00; Zed's $86 bond goes to the pool; Kai +$4 |

&#91;embedded content: Monday settlement · 4 payers, 3 receivers\]

**Settlement, position by position**

|  | Priya (partial) | Dev (full close, short) |
| --- | --- | --- |
| Tokens sold | 59.08 NVDA | 100 COIN (60 to Aria, 40 to the pool) |
| Proceeds | $9,217.15 | $13,140.00 + $8,730.00 = $21,870.00 |
| Penalty (3%, only if solvent) | $276.51 → $92.17 each to pool, reserve and treasury | $0 (waived, the position is short) |
| Debt repaid from proceeds | $8,940.64 | $21,870.00 |
| Shortfall | $0 | **$672.59, paid by the Underwriter Pool** |
| Borrower after | Owes $4,578.38, keeps 40.92 NVDA, health factor 1.13 | Owes nothing (non-recourse), holds no COIN |
| Senior Vault receives | $8,940.64 | $22,542.59 (the full debt) |

**What the pool did and why.** Dev was covered (auto-cover on Friday), so the pool paid his shortfall exactly as the policy says. Had he been uncovered, the Bell enforcement would have sold COIN down to 71.3% LTV on Friday afternoon, and his remaining shortfall would still have landed on the pool first under the waterfall. The pool also now holds 40 COIN it bought at $218.25 ($8,730). That is an asset swap, not a loss: cash went out and tokens came in.

**After settlement.** The COIN clock moves to REGULAR, and the pool's 40 COIN go into a Gradual Dutch Auction. By Wednesday they sell at an average of $224.00 ($8,960.00), a $230.00 gain that belongs to the **next** epoch, because that capital is carrying next week's risk.

## 5. Every cash move of the week, in order

There are 23 transfers in the week, and each one is listed below. Interest is not in this list: it is not a cash transfer. It accrues as a growing debt for borrowers and a rising share price for the Senior Vault, and it turns into cash only when a debt is repaid or auctioned.

| # | When | From → To | Amount | Why |
| --- | --- | --- | --- | --- |
| 1 | Mon 09:30 | Lena → Senior Vault | $200,000.00 | Deposit, 200,000 vault shares |
| 2 | Mon 10:00 | Priya → Market | 100 NVDA | Collateral |
| 3 | Mon 10:00 | Senior Vault → Priya | $13,500.00 | Loan |
| 4 | Wed | Umar → Underwriter Pool | $20,000.00 | Deposit, 20,000 pool shares |
| 5 | Wed | (none) | — | Sara's withdrawal request is queued; no cash yet |
| 6 | Thu 13:00 | Market → Auction House | 20.23 TSLA | Ben's lot |
| 7 | Thu 13:01 | Aria → Auction House | $7,326.43 | Winning bid at $362.18 |
| 8 | Thu 13:01 | Auction House → Aria | 20.23 TSLA | Tokens won |
| 9 | Thu 13:01 | Auction House → Senior Vault | $7,106.64 | Repays Ben's debt |
| 10 | Thu 13:01 | Auction House → Pool, reserve, treasury | $73.26 each | Ben's $219.79 penalty |
| 11 | Fri 14:20 | Priya → Underwriter Pool | $6.53 | Gap Cover premium |
| 12 | Fri 14:00–15:45 | Other borrowers → Underwriter Pool | $280.00 | Gap Cover premiums |
| 13 | Fri 15:45 | Senior Vault → Underwriter Pool | $10.89 | Dev's auto-cover premium, lent to him and added to his debt |
| 14 | Thu–Fri | Treasury → Kai | $4.00 + $12.00 | Keeper tips |
| 15 | Mon 09:35 | Zed → Underwriter Pool | $86.00 | Bond forfeited for not revealing |
| 16 | Mon 09:37 | Aria → Auction House | $22,357.15 | 59.08 NVDA at $156.02 + 60 COIN at $219.00 |
| 17 | Mon 09:37 | Underwriter Pool → Auction House | $8,730.00 | Backstop: 40 COIN at the $218.25 reserve |
| 18 | Mon 09:37 | Auction House → Aria and Pool | 59.08 NVDA + 60 COIN; 40 COIN | Tokens won |
| 19 | Mon 09:37 | Auction House → Senior Vault | $30,810.64 | Repays Priya ($8,940.64) and Dev ($21,870.00) |
| 20 | Mon 09:37 | Auction House → Pool, reserve, treasury | $92.17 each | Priya's $276.51 penalty |
| 21 | Mon 09:37 | Underwriter Pool → Senior Vault | $672.59 | Dev's shortfall |
| 22 | Mon 09:37 | Treasury → Kai | $8.00 | Keeper tips |
| 23 | Mon after settlement | Underwriter Pool → Sara | $9,998.82 | 10,000 shares redeemed at $0.99988 |

Next epoch, Monday to Wednesday: GDA buyers pay the pool $8,960.00 for its 40 COIN.

**Checks that the books balance**

- **Monday auction cash in = cash out.** In: $22,357.15 + $8,730.00 = $31,087.15. Out: $30,810.64 of debt repaid + $276.51 of penalty = $31,087.15.
- **Senior Vault is made whole.** Priya's and Dev's debts at 09:30 were $13,519.02 and $22,542.59. The vault received $8,940.64 (Priya still owes the other $4,578.38) + $21,870.00 + $672.59 = Dev's full $22,542.59.
- **Interest splits exactly.** Total accrued this week is $1,119.72 = $895.77 senior + $111.97 pool + $111.97 treasury.

## 6. End of week: who earned what

Senior lenders earned their interest and lost nothing. The Underwriter Pool collected $660.83 and paid out $672.59, ending the bad week $11.77 down. The protocol kept a small fee. That is the design working: the people who were paid to take the Monday risk are the ones who absorbed it.

| User | What happened | Result for the week |
| --- | --- | --- |
| **Lena** (senior lender) | 20% of the vault's $895.77 interest | **+$179.15**; vault share price $1.000896 |
| **Senior Vault** (all lenders) | Interest accrued; every debt repaid or still healthy | **+$895.77**, no losses |
| **Underwriter Pool** | In: $111.97 risk fee + $297.42 premiums + $165.43 penalty share + $86.00 bond = $660.83. Out: $672.59 shortfall | **−$11.77**; share price $0.99988 |
| **Umar** (underwriter) | 20,000 shares | $20,000.00 → **$19,997.65** |
| **Sara** (underwriter, exiting) | Paid after settlement, at the post-weekend price | $10,000.00 → **$9,998.82** received |
| **Protocol reserve** | Penalty thirds | **+$165.43** |
| **Protocol treasury** | $111.97 fee + $165.43 penalty thirds − $24.00 keeper tips | **+$253.41** |
| **Priya** (borrower) | Interest $19.02, premium $6.53, penalty $276.51; sold 59.08 NVDA at $156.02 vs a $158.40 open | Credence costs **$302.06**; still owes $4,578.38 against 40.92 NVDA (health factor 1.13) |
| **Dev** (borrower) | Lost 100 COIN (worth $22,500 at the open); $22,542.59 debt erased | Walks away owing nothing; his loss is the collateral |
| **Ben** (borrower) | Interest $15.32, penalty $219.79 | Owes $7,708.68 at week end, keeps 29.77 TSLA |
| **Rahul** (borrower) | Interest only | **−$210.96** accrued interest |
| **Aria** (bidder) | Bought 20.23 TSLA, 59.08 NVDA and 60 COIN below the live or opening price at the time | About **$537** of discount before her hedging and price risk |
| **Zed** (bidder) | Did not reveal | **−$86.00** |
| **Kai** (keeper) | 7 successful calls earning 12 tips of $2 (Thursday flag and clear; one Friday `enforceBell` over 6 positions; Monday's two flags and two clears) | **+$24.00**, minus gas |

**Where the borrowers' money went.** The week's $1,119.72 of interest went 80% to lenders, 10% to the pool and 10% to the treasury. Premiums ($297.42) went 100% to the pool. Penalties ($496.30 across Ben and Priya) went one-third each to the pool, the reserve and the treasury.

**The same week without a bad Monday.** If NVDA and COIN had opened flat, there would be no Monday auctions and no shortfall. The pool would have kept its $111.97 risk fee, $297.42 of premiums and Ben's $73.26 penalty share: **+$482.65**, about 0.48% for the week. That is high because this was a stressed week in which many loans needed cover. In a calm week the Bell barely binds, premiums are near zero, and the pool earns mostly its risk fee: about $112 a week, roughly 5.8% a year on $100,000. Underwriters are paid well in nervous weeks because those are the weeks with the risk.

**The one number to watch.** The pool is solvent as long as its premiums, fees and penalties outrun its shortfalls over many weeks. The Risk Engine's job (formula 4.3 in the Architecture tab) is to price the premium so that this holds on the historical record, with a loading on top.

## 7. Side flow: a Treasury-fund borrower on Arbitrum One

The same week on the Arbitrum One deployment is almost silent, because Treasury-fund collateral barely moves. It runs on its own Senior Vault and Underwriter Pool; no money crosses between the two chains.

**Example (illustrative):** a DAO treasury holds $1,000,000 of BENJI, a tokenized US government money fund, and needs $850,000 of USDC for a grant programme without selling.

| When | What happens | Money |
| --- | --- | --- |
| Monday | The treasury, already allowlisted by the issuer, deposits $1,000,000 BENJI and borrows $850,000 USDC (85% LTV, under the 90% max) | Senior Vault → DAO: $850,000 USDC |
| Every day | The fund keeps paying its yield to the token holder; the loan accrues interest | Illustrative: fund yield about 4% a year (about $767 this week); borrow rate 5.5% (about $897 this week) |
| Friday | Bell window: the NAV safe LTV is above 90%, so nothing binds | None |
| Weekend | CLOSED: no NAV update, no redemptions, nothing to liquidate | None |
| Monday | First fresh NAV, slightly higher from accrued yield; REOPEN finds nothing under water | None |

The DAO's net cost for the week is about $130: roughly $897 of interest against $767 of fund yield kept. That is the price of borrowing $850,000 without selling its Treasury position.

**If something went wrong** (the NAV dropping, or the issuer gating redemptions), the path is the one in Architecture section 3.8: a settlement-solver auction pays cash at T+0; if no solver bids, the pool advances the cash and waits for redemption itself; if redemptions are gated, the market halts with repay always open.
