// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClockFixture} from "../utils/ClockFixture.sol";
import {Session, ClockState, ClockData, ClosureType, FeedMarketStatus} from "../../src/libraries/Types.sol";

/// @title A full real week of sessions through the AssetClock (Build Guide §14, sprint-1 item 8).
/// @notice Calendar = BE-backend's generated XNYS JSON (fixture slice, same shape). Two real weeks:
///         - Thanksgiving 2026: Mon 11-23 … Wed 11-25 close → Thu holiday → Fri 11-27 early close 13:00 → weekend
///           → Mon 11-30 REOPEN.
///         - Good Friday 2027: Mon 03-22 … Thu 03-25 close → Fri holiday → weekend → Mon 03-29 REOPEN (4 days, R-07).
contract ClockWeekScenarioTest is ClockFixture {
    uint256 internal price = 180e18;
    uint64 internal expectedClosures;
    uint256 internal reopens;

    function setUp() public {
        setUpStack();
    }

    // ───────────── helpers ─────────────

    function _s(uint256 i) internal view returns (Session memory) {
        return sessions[i];
    }

    /// @dev Relayers publish a live print with the status the vendor would report at this time.
    function _tick(uint8 status) internal {
        _liveBoth(price, status);
    }

    function _at(uint256 t, uint8 status) internal returns (ClockState st) {
        vm.warp(t);
        _tick(status);
        st = _poke();
    }

    /// @dev Regular session i: open print at the open, live prints through the day, close print at the close.
    function _tradeSession(uint256 i, uint256 openPx, uint256 closePx) internal {
        Session memory s = _s(i);
        // pre-market
        assertEq(
            uint8(_at(s.open - 30 minutes, FeedMarketStatus.PRE)), uint8(ClockState.EXTENDED), "pre-market"
        );

        // 09:30 open: both vendors publish the official opening print
        vm.warp(s.open);
        _openPrint(feedA, NVDA, openPx, s.open);
        _openPrint(feedB, NVDA, openPx, s.open);
        price = openPx;
        _tick(FeedMarketStatus.REGULAR);
        ClockData memory before = _info();
        ClockState st = _poke();
        if (before.reopenPending) {
            assertEq(uint8(st), uint8(ClockState.REOPEN), "REOPEN at the open");
            reopens += 1;
            ClockData memory d = _info();
            assertEq(d.openPrint, openPx, "open print");
            assertEq(d.openPrintAt, s.open);
            // the reopen auction clears and the auction house releases the clock
            vm.warp(s.open + 7 minutes);
            _tick(FeedMarketStatus.REGULAR);
            vm.prank(auctionHouse);
            clock.markReopenComplete(NVDA, d.closureId);
            assertEq(uint8(clock.state(NVDA)), uint8(ClockState.REGULAR), "REGULAR after reopen");
            assertFalse(_info().reopenPending);
        }

        _intraday(s, closePx);
        _closeSession(i, closePx);
    }

    /// @dev REGULAR, valuation = live price, Bell window / deadline before the close.
    function _intraday(Session memory s, uint256 closePx) internal {
        price = closePx;
        assertEq(
            uint8(_at(s.close - 3 hours, FeedMarketStatus.REGULAR)), uint8(ClockState.REGULAR), "intraday"
        );
        assertEq(oracle.valuationPrice(NVDA), closePx, "live valuation");
        assertFalse(clock.isBellWindow(NVDA));
        assertEq(_info().nextCloseAt, s.close, "next close");
        assertEq(_info().bellWindowAt, s.close - 2 hours);
        assertEq(_info().bellAt, s.close - 15 minutes);

        _at(s.close - 1 hours, FeedMarketStatus.REGULAR);
        assertTrue(clock.isBellWindow(NVDA), "bell window");
        assertFalse(clock.isAfterBellDeadline(NVDA));
        _at(s.close - 10 minutes, FeedMarketStatus.REGULAR);
        assertTrue(clock.isAfterBellDeadline(NVDA), "after bell deadline");
    }

    /// @dev Close: the official closing print lands 20 s after the close; a closure of the calendar's type opens.
    function _closeSession(uint256 i, uint256 closePx) internal {
        Session memory s = _s(i);
        _at(s.close - 5, FeedMarketStatus.REGULAR);
        vm.warp(s.close + 20);
        _closePrint(feedA, NVDA, closePx, s.open, s.close);
        _closePrint(feedB, NVDA, closePx, s.open, s.close);
        _tick(FeedMarketStatus.POST);
        uint64 idBefore = _info().closureId;
        assertEq(uint8(_poke()), uint8(ClockState.EXTENDED), "post-market");
        expectedClosures += 1;
        ClockData memory c = _info();
        assertEq(c.closureId, idBefore + 1, "INV-CLK-01: +1 at the close");
        assertEq(uint8(c.closureType), uint8(s.closureTypeAfter), "closure type from the calendar");
        assertEq(c.refPrice, closePx, "ref = official close");
        assertEq(c.closeAt, s.close);
        assertEq(c.reopenAt, _s(i + 1).open, "reopen = next open");
        assertEq(c.venueEpoch, i, "venueEpoch = session index");
        assertTrue(c.reopenPending);
        // INV-ORA-01 in EXTENDED
        assertLe(oracle.valuationPrice(NVDA), c.refPrice);
    }

    // ───────────── Thanksgiving week 2026 ─────────────

    uint256 internal tgFri;
    uint256 internal tgMon;
    uint256 internal tgWed;
    uint256 internal tgBlackFri;
    uint256 internal tgNextMon;

    function test_thanksgivingWeek() public {
        tgFri = _idx("2026-11-20");
        tgMon = _idx("2026-11-23");
        tgWed = _idx("2026-11-25");
        tgBlackFri = _idx("2026-11-27");
        tgNextMon = _idx("2026-11-30");
        assertEq(tgBlackFri, tgWed + 1, "Thursday is a holiday: no session");
        assertEq(uint8(_s(tgWed).closureTypeAfter), uint8(ClosureType.HOLIDAY_WEEKEND), "mid-week holiday");
        assertEq(_s(tgBlackFri).close - _s(tgBlackFri).open, 3.5 hours, "early close 13:00");

        _tgFridayAndWeekend();
        _tgMonToThanksgiving();
        _tgBlackFridayToMonday();

        assertEq(_info().closureId, expectedClosures, "INV-CLK-01: exactly one closure per scheduled close");
        assertEq(expectedClosures, 6);
        assertEq(reopens, 5, "Mon, Tue, Wed, Fri, Mon each reopened through REOPEN");
    }

    function _tgFridayAndWeekend() internal {
        // list during Friday 11-20's session, before the close
        vm.warp(_s(tgFri).open + 1 hours);
        _list();
        _tick(FeedMarketStatus.REGULAR);
        assertEq(uint8(_poke()), uint8(ClockState.REGULAR));
        assertEq(_info().closureId, 0);

        // Friday close → weekend
        price = 181e18;
        Session memory f = _s(tgFri);
        _at(f.close - 30, FeedMarketStatus.REGULAR);
        vm.warp(f.close + 20);
        _closePrint(feedA, NVDA, 181e18, f.open, f.close);
        _closePrint(feedB, NVDA, 181e18, f.open, f.close);
        _tick(FeedMarketStatus.POST);
        assertEq(uint8(_poke()), uint8(ClockState.EXTENDED));
        expectedClosures += 1;
        assertEq(uint8(_info().closureType), uint8(ClosureType.WEEKEND));
        assertEq(clock.closureDays(NVDA), 3, "R-07: a normal weekend is 3 days");

        // Saturday: CLOSED; valuation = ref (no deep DEX)
        price = 170e18; // a weekend price can lower value, never raise it
        assertEq(
            uint8(_at(f.extClose + 20 hours, FeedMarketStatus.CLOSED)), uint8(ClockState.CLOSED), "Saturday"
        );
        _weekendDexChecks();

        // Sunday 20:00: the 24/5 overnight window of Monday's session
        assertEq(
            uint8(_at(_s(tgMon).extOpen + 1 hours, FeedMarketStatus.OVERNIGHT)), uint8(ClockState.EXTENDED)
        );
        assertLe(oracle.valuationPrice(NVDA), 181e18, "INV-ORA-01 overnight");
    }

    function _weekendDexChecks() internal {
        assertEq(oracle.valuationPrice(NVDA), 181e18);
        dex.set(175e18, true, 300_000e18); // deep pool below ref → min() lowers value
        assertEq(oracle.valuationPrice(NVDA), 175e18);
        dex.set(190e18, true, 300_000e18); // pumped weekend price never raises it
        assertEq(oracle.valuationPrice(NVDA), 181e18);
        dex.set(0, false, 0);
    }

    function _tgMonToThanksgiving() internal {
        _tradeSession(tgMon, 178e18, 182e18);
        assertEq(clock.closureDays(NVDA), 1, "weeknight = 1 day");
        _tradeSession(tgMon + 1, 182e18, 183e18);
        _tradeSession(tgWed, 183e18, 184e18);
        assertEq(uint8(_info().closureType), uint8(ClosureType.HOLIDAY_WEEKEND));
        assertEq(clock.closureDays(NVDA), 2, "Wed close -> Fri open = 2 days");

        // Thanksgiving Thursday: CLOSED all day until Friday's overnight window at Thu 20:00
        assertEq(
            uint8(_at(_s(tgWed).extClose + 12 hours, FeedMarketStatus.CLOSED)),
            uint8(ClockState.CLOSED),
            "holiday"
        );
        assertEq(_info().closureId, expectedClosures, "no closure on a holiday");
        assertEq(
            uint8(_at(_s(tgBlackFri).extOpen + 1, FeedMarketStatus.OVERNIGHT)), uint8(ClockState.EXTENDED)
        );
    }

    function _tgBlackFridayToMonday() internal {
        // Black Friday: early close at 13:00, Bell window 11:00, deadline 12:45; post-market ends 17:00
        _tradeSession(tgBlackFri, 184e18, 185e18);
        assertEq(uint8(_info().closureType), uint8(ClosureType.WEEKEND));
        assertEq(uint8(_at(_s(tgBlackFri).extClose - 1, FeedMarketStatus.POST)), uint8(ClockState.EXTENDED));
        assertEq(
            uint8(_at(_s(tgBlackFri).extClose + 1, FeedMarketStatus.CLOSED)),
            uint8(ClockState.CLOSED),
            "17:00"
        );
        assertEq(clock.closureDays(NVDA), 3);

        // Monday 11-30 REOPEN
        vm.warp(_s(tgNextMon).extOpen + 2 hours);
        _tick(FeedMarketStatus.OVERNIGHT);
        _poke();
        _tradeSession(tgNextMon, 186e18, 186e18);
    }

    // ───────────── Good Friday 2027: holiday Friday, 4-day closure ─────────────

    function test_goodFridayWeek() public {
        uint256 prevFri = _idx("2027-03-19");
        uint256 mon = _idx("2027-03-22");
        uint256 thu = _idx("2027-03-25");
        uint256 nextMon = _idx("2027-03-29");
        assertEq(nextMon, thu + 1, "Good Friday: no session");
        assertEq(uint8(_s(thu).closureTypeAfter), uint8(ClosureType.HOLIDAY_WEEKEND));

        vm.warp(_s(prevFri).open + 2 hours);
        _list();
        _tick(FeedMarketStatus.REGULAR);
        _poke();
        Session memory f = _s(prevFri);
        _at(f.close - 10, FeedMarketStatus.REGULAR);
        vm.warp(f.close + 10);
        _closePrint(feedA, NVDA, price, f.open, f.close);
        _closePrint(feedB, NVDA, price, f.open, f.close);
        _tick(FeedMarketStatus.POST);
        _poke();
        expectedClosures += 1;

        for (uint256 i = mon; i <= thu; ++i) {
            _tradeSession(i, price, price + 1e18);
        }
        ClockData memory c = _info();
        assertEq(uint8(c.closureType), uint8(ClosureType.HOLIDAY_WEEKEND));
        assertEq(c.reopenAt, _s(nextMon).open);
        assertEq(clock.closureDays(NVDA), 4, "R-07: Thu close -> Mon open = 4 days");
        (uint40 closeAt, uint40 reopenAt, ClosureType t) = clock.closureWindow(NVDA);
        assertEq(closeAt, _s(thu).close);
        assertEq(reopenAt, _s(nextMon).open);
        assertEq(uint8(t), uint8(ClosureType.HOLIDAY_WEEKEND));

        // Good Friday during US trading hours: CLOSED, and no closure is opened
        assertEq(uint8(_at(_s(thu).close + 1 days, FeedMarketStatus.CLOSED)), uint8(ClockState.CLOSED));
        assertEq(_info().closureId, expectedClosures);
        // A pumped Friday DEX print cannot raise the value; a crash lowers it and raises the stress flag
        dex.set(price + 50e18, true, 1_000_000e18);
        assertEq(oracle.valuationPrice(NVDA), c.refPrice);
        assertFalse(oracle.stressFlag(NVDA));
        dex.set(c.refPrice * 85 / 100, true, 1_000_000e18);
        assertEq(oracle.valuationPrice(NVDA), c.refPrice * 85 / 100);
        assertTrue(oracle.stressFlag(NVDA), "stress: DEX < 90% of ref");
        dex.set(0, false, 0);

        vm.warp(_s(nextMon).extOpen + 1 hours);
        _tick(FeedMarketStatus.OVERNIGHT);
        _poke();
        _tradeSession(nextMon, price, price);
        assertEq(_info().closureId, expectedClosures);
        assertEq(reopens, 5, "Mon..Thu and the Monday after Good Friday");
    }

    // ───────────── the whole fixture: 126 real sessions, poked only at the boundaries ─────────────

    function test_sixMonthsOfSessions_oneClosurePerClose() public {
        vm.warp(_s(0).open + 1 hours);
        _list();
        uint64 opened;
        for (uint256 i; i + 1 < sessions.length; ++i) {
            Session memory s = _s(i);
            vm.warp(s.close - 60);
            _tick(FeedMarketStatus.REGULAR);
            _poke();
            vm.warp(s.close + 30);
            _closePrint(feedA, NVDA, price, s.open, s.close);
            _tick(FeedMarketStatus.POST);
            _poke();
            opened += 1;
            ClockData memory d = _info();
            assertEq(d.closureId, opened);
            assertEq(uint8(d.closureType), uint8(s.closureTypeAfter));
            // R-07 closure length in days
            uint256 gapDays = (uint256(_s(i + 1).open - s.close) + 1 days - 1) / 1 days;
            assertEq(clock.closureDays(NVDA), gapDays);
            if (s.closureTypeAfter == ClosureType.OVERNIGHT) assertEq(gapDays, 1);
            if (s.closureTypeAfter == ClosureType.WEEKEND) assertEq(gapDays, 3);
            if (s.closureTypeAfter == ClosureType.HOLIDAY_WEEKEND) assertGe(gapDays, 2);
        }
    }
}
