# The open print is ±50 % from the previous close (OpenPrintDeviation, RB-05)

**What fired:** at a reopen, the open print written by the clock differs by more than 50 % from the closure's frozen reference close (`credence_keeper_open_print_deviation_ratio{asset}`, signed). The page lasts one hour after the print. Threat-model row 4: a manipulated or wrong print would liquidate or under-collateralise positions at the reopen auction.

1. Look at the numbers:
   ```sh
   curl -s 'http://127.0.0.1:8787/v1/clock/<TICKER>:XNAS?chain=46630' | jq '{state, refPrice, openPrint, openPrintAt, openPrintFallback, feeds}'
   ```
2. **A real move** (a split not handled as a corporate action, news, a delisting): compare with a public quote. A split → [corporate-action.md](corporate-action.md).
3. **A wrong print** (a vendor glitch, a wrong package): the guardian Safe pauses the asset at once (the Guardian Safe, 2-of-4), so the REOPEN auction does not clear at that price. Post on the board.
4. The missing-open-print path (RB-05): if no print comes within 15 min, the TWAP fallback applies when both feeds' 5-minute TWAPs agree; else the asset stays CLOSED and the guardian extends it.
5. Exactly ±50 % does not page.
