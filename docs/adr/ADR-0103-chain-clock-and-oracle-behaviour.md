# ADR-0103 · BE-chain · AssetClock and OracleAdapter behaviour the guide leaves open

Status: Accepted · Date: 2026-09-28 · Owner: BE-chain

Guide §8.2.2 and §8.3.2 define the transition algorithm and the price rules. Implementing and testing them surfaced the points below. Each one is covered by a named test in `contracts/test/unit/AssetClock.t.sol` or `OracleAdapter.t.sol`.

| # | Topic | Decision | Why |
| --- | --- | --- | --- |
| 1 | Reference at the close (step 3) | `refPrice` is taken from `lastRegularClose` = the official CLOSE if it is at least as recent as the last REGULAR-status print, otherwise that print. While a scheduled closure's `refTime < closeAt` (provisional), each poke adopts a newer regular close and emits `ReferenceUpdated`. | The official closing auction print lands seconds to minutes after 16:00. Taking only the official close would HALT every asset at every close. |
| 2 | Missing reference | "≥ session.open, else HALTED" applies to **scheduled** closures only. A HALT or CORP_ACTION closure whose halt reference is unavailable is not held HALTED: its valuation reverts `NoReferencePrice`, which already fails closed. | Found by the tests. Holding it HALTED meant such a closure could never reach REOPEN. |
| 3 | Halt reference | A HALT closure's `refPrice` = min(last regular close, primary latest, secondary latest). | A crash-triggered halt must not be valued at yesterday's close. |
| 4 | Non-calendar closures | Any move into CLOSED / HALTED / CORP_ACTION while no closure is pending opens a closure (`closureId++`, type HALT or CORP_ACTION, `reopenAt` = the next scheduled open). This covers a feed halt, the feed saying closed, a guardian restriction, or a corporate action. | Every closure ends through REOPEN, so the open print and the reopen auction always run. |
| 5 | Missed pokes | One poke processes every scheduled close that passed since the last one, one closure each (INV-CLK-01). | Keeper downtime must not lose closures. |
| 6 | Sequencer gap (R-20) | Only time after the pending closure's `reopenAt` counts: `gap = now − max(prevPoke, reopenAt)`, extension += gap + 120 s when gap > 120 s. | Otherwise a quiet weekend would pile up a phase extension. |
| 7 | Open-print fallback | After `reopenAt + 15 min + ext`, the fallback is the two feeds' trailing 5-minute TWAPs, which must agree within 1.5%. The window then lies entirely after the scheduled open. | "5-minute TWAP taken from reopenAt" with a trailing window. No history beyond the 96-entry ring is needed. |
| 8 | After a halt | The open print is the first fresh (≤ 60 s) REGULAR-status price, observed after the halt started, on which both feeds agree within 1.5%. | §8.2.2 step 8. |
| 9 | NAV assets | Reopen when a fresh, valid NAV newer than `closeAt` exists. Stale (> 26 h) → CLOSED; `navInvalid` (> 50 h or a > 0.5% one-step drop), gated redemptions or a freeze → HALTED. | Architecture §3.8. See the report's spec issue on 50 h vs a normal weekend. |
| 10 | Feed status | STATUS/LIVE `marketStatus = HALTED` on either feed → HALTED (new `FeedHealth.statusHalted`). The primary saying CLOSED while the calendar is open → CLOSED. | Fail closed (P8). |
| 11 | Guardian | Restrictions are stored per state (`haltedUntil`, `closedUntil`). A new one must end at or after the active one of the same kind, and at most 7 days out. A shorter HALT therefore never shortens a longer CLOSED. | INV-CLK-02. |
| 12 | `markReopenComplete` | Allowed callers: the wired auction house and the settlement adapter. A stale `closureId` is a no-op, a future one reverts, and calling before the open print reverts. | The auction house may finish after a newer closure started, and must not get stuck. |
| 13 | Listing | A newly listed asset is CLOSED until its first poke. A closure already in progress at listing is not replayed. | No reference exists for it. |
| 14 | `closureDays` | Reverts `ClosureOpenEnded` when either end of the closure is unknown (before the first session, or past coverage). | Found by the tests: it returned `ceil(open / 1 day)`. |
| 15 | Equity sources | An EQUITY asset needs both a primary and a secondary feed. | The open print needs a cross-check. |
