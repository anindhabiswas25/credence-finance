# ADR-0113 · BE-chain · QA-sec S4 findings QA-01…QA-08: fixes and one spec gap (GDA across a closure)

Status: accepted (S4) · Date: 2026-09-29 · Findings: `docs/security/triage.md` (QA-sec), board REQUESTs 14:25 / 14:30

| # | Sev | Fix | Where |
| --- | --- | --- | --- |
| QA-01 | M | `gdaBuy`: the buyer pays the pool, the pool books the sale (`onGdaSale`), **then** the tokens leave; a receive hook sees final NAV | `AuctionHouse.gdaBuy` |
| QA-02 | M | An open bid below the reserve fixed with the lot reverts `BidBelowReserve` (it can never fill, so it may not take one of the 64 slots). A REOPEN reveal below R is accepted but stays **unrevealed**, so its bond is forfeited to the pool at clearing like a non-reveal's | `placeBid`, `revealBid` |
| QA-03 | M | `gdaBuy` only while the asset's clock is REGULAR (`ActionNotAllowedInState(7, s)`), and the GDA cost is floored at qty × (1 − κ) × V_live (`GdaLib.cost`, also in `gdaPrice`) | `AuctionHouse`, new `GdaLib` |
| QA-04 | M | `resellInventory` only while the asset is REGULAR (`ActionNotAllowedInState(8, s)`), so k = 1.02 × V never comes from a closed-market min(reference, DEX TWAP) | `PoolLib.listInventory` |
| QA-05 | L | ERC-4626 `deposit` returns the shares the receiver got (first deposit: minus the 1e3 dead shares); `mint` gives the receiver exactly `shares` and charges the dead shares to the caller | `SeniorVault` |
| QA-06 | L | Accrual floors the two fee shares once, together (`fees = i·(ρJ+ρp)/BPS`, `ft = fees − fp`), so the senior remainder never falls as time passes | `MarketLib.interest` |
| QA-07 | L | `claimWithdraw` advances the FIFO head past paid (≤ 1 unit dust per withdrawer) epochs | `PoolLib.advanceHead` |
| QA-08 | M | A report may move `seq` by at most `MAX_SEQ_STEP` = 2³² (`SeqStepTooLarge`); the relayer counts up by 1. `RedStonePriceSource` keeps no seq | `CredencePriceFeed._store` |
| CI | — | `forge snapshot` (make and CI) excludes `test/{invariant,security,fuzz}/**` | `mk/contracts.mk`, `contracts.yml` |

## QA-03: spec gap for the PM
F-4.5e (§9.6e) defines the GDA price but is silent on closures. As specified, emission and decay keep running while the
market is shut, so a Friday listing's oldest units cost ~13 % of V by Monday 09:30 and the first buyer after the open
takes the difference from underwriters. Chosen behaviour: (a) no GDA sale outside REGULAR, and (b) never below
(1 − κ) × V_live, the reserve the pool bought the inventory at; the GDA therefore descends from 1.02 V to the floor and
then sells flat at the floor. This matches R-12's inventory mark min(cost, V(1 − κ)), so a sale never realises a loss
against the mark. Alternative the PM may prefer: pause the GDA clock outside REGULAR (more storage, same outcome for
underwriters). Reported under spec issues.

## Code size
`AuctionHouse` takes the GDA pricing into the linked `GdaLib`, and `UnderwriterPool` the FIFO scans into `PoolLib`, to
stay under 24 KB (AH 24,175 B, pool 24,266 B).

## ABI
v3 gains one error (`SeqStepTooLarge`); everything else is behaviour. QA-sec's `…Today` tests, which pin the pre-fix
behaviour, now fail by design and are theirs to drop.
