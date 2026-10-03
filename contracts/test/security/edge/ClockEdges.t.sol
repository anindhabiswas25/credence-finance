// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClockFixture} from "../../utils/ClockFixture.sol";
import {ClockState, ClosureType, Session} from "../../../src/libraries/Types.sol";

/// @title Clock edge cases on the real XNYS calendar (matrix rows E-C-*, `docs/qa/edge-cases.md`).
/// @notice DST switches, an early close and a holiday, read through the clock's calendar views (the ones the market,
///         the pool and the keeper use): state at the exact second, the closure window, closure days and the Bell.
contract ClockEdgesTest is ClockFixture {
    uint256 internal constant FRI_OCT30 = 21; // last session on EDT
    uint256 internal constant MON_NOV02 = 22; // first on EST
    uint256 internal constant WED_NOV25 = 39; // before Thanksgiving
    uint256 internal constant FRI_NOV27 = 40; // early close 13:00 ET
    uint256 internal constant MON_NOV30 = 41;
    uint256 internal constant FRI_MAR12 = 111; // last on EST
    uint256 internal constant MON_MAR15 = 112; // first on EDT

    function setUp() public {
        setUpStack();
        vm.warp(sessions[0].extOpen - 1);
        _list();
    }

    function _state() internal view returns (ClockState) {
        return clock.calendarState(NVDA);
    }

    function _assertWindow(uint256 i, uint256 j, ClosureType t, uint256 days_) internal view {
        (uint40 closeAt, uint40 reopenAt, ClosureType ty) = clock.closureWindow(NVDA);
        assertEq(closeAt, sessions[i].close, "closeAt");
        assertEq(reopenAt, sessions[j].open, "reopenAt");
        assertEq(uint8(ty), uint8(t), "closure type");
        assertEq(clock.closureDays(NVDA), days_, "closure days");
    }

    /// E-C-01: DST ends over the weekend of 2026-10-30. Friday closes 20:00 UTC; Monday opens 14:30 UTC. At 13:30 UTC
    ///         (the old open) the asset is still pre-market, it opens at the exact second, and the Bell times follow
    ///         the new close (21:00 UTC).
    function test_E_C01_dstEndsOverAWeekend() public {
        Session memory fri = sessions[FRI_OCT30];
        Session memory mon = sessions[MON_NOV02];
        assertEq(mon.open - fri.close, 2 days + 18 hours + 30 minutes);
        vm.warp(fri.close - 15 minutes - 1);
        assertFalse(clock.isAfterBellDeadline(NVDA));
        vm.warp(fri.close - 15 minutes);
        assertTrue(clock.isAfterBellDeadline(NVDA));
        vm.warp(fri.close);
        _assertWindow(FRI_OCT30, MON_NOV02, ClosureType.WEEKEND, 3);
        vm.warp(mon.open - 1 hours);
        assertEq(uint8(_state()), uint8(ClockState.EXTENDED), "13:30 UTC is pre-market after the switch");
        vm.warp(mon.open - 1);
        assertEq(uint8(_state()), uint8(ClockState.EXTENDED));
        vm.warp(mon.open);
        assertEq(uint8(_state()), uint8(ClockState.REGULAR));
        vm.warp(mon.close - 2 hours - 1);
        assertFalse(clock.isBellWindow(NVDA));
        vm.warp(mon.close - 2 hours); // 19:00 UTC, not 18:00
        assertTrue(clock.isBellWindow(NVDA));
    }

    /// E-C-02: DST starts over the weekend of 2027-03-12: Friday closes 21:00 UTC, Monday opens 13:30 UTC.
    function test_E_C02_dstStartsOverAWeekend() public {
        Session memory fri = sessions[FRI_MAR12];
        Session memory mon = sessions[MON_MAR15];
        assertEq(mon.open - fri.close, 2 days + 16 hours + 30 minutes);
        vm.warp(fri.close + 1);
        _assertWindow(FRI_MAR12, MON_MAR15, ClosureType.WEEKEND, 3);
        vm.warp(mon.open - 1);
        assertEq(uint8(_state()), uint8(ClockState.EXTENDED));
        vm.warp(mon.open);
        assertEq(uint8(_state()), uint8(ClockState.REGULAR));
        vm.warp(mon.close - 15 minutes); // 19:45 UTC
        assertTrue(clock.isAfterBellDeadline(NVDA));
    }

    /// E-C-03: Thanksgiving: Wednesday's close starts a HOLIDAY_WEEKEND closure (the calendar type for a mid-week holiday) to Friday (2 days); Thursday is closed all
    ///         day; Friday closes early at 18:00 UTC, so its Bell deadline is 17:45 UTC — at the usual 20:45 UTC the
    ///         asset is already past the close.
    function test_E_C03_thanksgivingHolidayAndEarlyClose() public {
        Session memory wed = sessions[WED_NOV25];
        Session memory fri = sessions[FRI_NOV27];
        vm.warp(wed.close);
        _assertWindow(WED_NOV25, FRI_NOV27, ClosureType.HOLIDAY_WEEKEND, 2);
        vm.warp(wed.close + 18 hours); // Thursday 15:00 UTC, a normal session time
        assertEq(uint8(_state()), uint8(ClockState.CLOSED), "holiday");
        vm.warp(fri.open);
        assertEq(uint8(_state()), uint8(ClockState.REGULAR));
        vm.warp(fri.close - 2 hours);
        assertTrue(clock.isBellWindow(NVDA), "Bell window 16:00 UTC");
        vm.warp(fri.close - 15 minutes);
        assertTrue(clock.isAfterBellDeadline(NVDA), "Bell 17:45 UTC");
        vm.warp(fri.close);
        assertEq(uint8(_state()), uint8(ClockState.EXTENDED), "post-market after the early close");
        _assertWindow(FRI_NOV27, MON_NOV30, ClosureType.WEEKEND, 3);
        vm.warp(fri.close + 2 hours + 45 minutes); // the usual 20:45 UTC
        assertFalse(clock.isAfterBellDeadline(NVDA), "no second Bell on the usual schedule");
        vm.warp(fri.extClose);
        assertEq(uint8(_state()), uint8(ClockState.CLOSED));
    }

    /// E-C-04: the last covered session: after its open no reopen is known, so the closure is open-ended
    ///         (`closureDays` reverts) and after its close there is no next Bell. (Poke → HALTED, fail closed:
    ///         `AssetClock.t.sol: test_calendarStates`.)
    function test_E_C04_calendarCoverageRunsOut() public {
        Session memory last = sessions[sessions.length - 1];
        vm.warp(last.close + 1);
        (uint40 closeAt, uint40 reopenAt,) = clock.closureWindow(NVDA);
        assertEq(closeAt, last.close);
        assertEq(reopenAt, 0);
        vm.expectRevert();
        clock.closureDays(NVDA);
        assertFalse(clock.isBellWindow(NVDA));
        assertFalse(clock.isAfterBellDeadline(NVDA));
    }
}
