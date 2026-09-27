// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Session, ClosureType} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {ICalendarStoreEvents} from "../../src/libraries/Events.sol";
import {CalendarStore} from "../../src/clock/CalendarStore.sol";

contract CalendarStoreTest is Test, ICalendarStoreEvents {
    CalendarStore cal;
    address timelock = makeAddr("timelock");
    bytes32 constant XNYS = bytes32("XNYS");

    function setUp() public {
        cal = new CalendarStore(timelock);
    }

    function _s(uint40 base, ClosureType t) internal pure returns (Session memory) {
        return Session(base, base + 5 hours, base + 11 hours, base + 16 hours, t);
    }

    function _two(uint40 base) internal pure returns (Session[] memory s) {
        s = new Session[](2);
        s[0] = _s(base, ClosureType.OVERNIGHT);
        s[1] = _s(base + 16 hours, ClosureType.WEEKEND); // weeknight: extOpen == previous extClose
    }

    function test_constructorZero() public {
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new CalendarStore(address(0));
    }

    function test_appendAndRead() public {
        Session[] memory s = _two(1_000_000);
        vm.expectEmit(true, false, false, true);
        emit SessionsAppended(XNYS, 0, 2, s[1].close);
        vm.prank(timelock);
        cal.appendSessions(XNYS, s);
        assertEq(cal.sessionCount(XNYS), 2);
        assertEq(cal.session(XNYS, 1).open, s[1].open);
        assertEq(cal.coverageEnd(XNYS), s[1].close);
        assertEq(cal.coverageEnd(bytes32("NONE")), 0);
        Session[] memory r = cal.sessions(XNYS, 1, 10);
        assertEq(r.length, 1);
        assertEq(r[0].close, s[1].close);
        assertEq(cal.sessions(XNYS, 2, 1).length, 0);
        assertEq(cal.sessions(XNYS, 0, 1).length, 1);

        // append more: must start at or after the previous extClose
        Session[] memory more = new Session[](1);
        more[0] = _s(s[1].extClose, ClosureType.HOLIDAY_WEEKEND);
        vm.prank(timelock);
        cal.appendSessions(XNYS, more);
        assertEq(cal.sessionCount(XNYS), 3);
    }

    function test_findSession() public {
        Session[] memory s = _two(1_000_000);
        vm.prank(timelock);
        cal.appendSessions(XNYS, s);
        (uint256 i, bool found) = cal.findSession(XNYS, 0);
        assertEq(i, 0);
        assertTrue(found);
        (i, found) = cal.findSession(XNYS, s[0].extClose);
        assertEq(i, 1);
        assertTrue(found);
        (i, found) = cal.findSession(XNYS, s[1].extClose);
        assertEq(i, 2);
        assertFalse(found);
    }

    function test_reverts() public {
        Session[] memory s = _two(1_000_000);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        cal.appendSessions(XNYS, s);

        vm.startPrank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownVenue.selector, bytes32(0)));
        cal.appendSessions(bytes32(0), s);
        vm.expectRevert(ICredenceErrors.EmptySessions.selector);
        cal.appendSessions(XNYS, new Session[](0));

        Session[] memory bad = _two(1_000_000);
        bad[1].open = bad[1].extOpen; // extOpen < open violated
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.SessionNotIncreasing.selector, 1));
        cal.appendSessions(XNYS, bad);

        bad = _two(1_000_000);
        bad[0].closureTypeAfter = ClosureType.HALT;
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.InvalidClosureType.selector, 0));
        cal.appendSessions(XNYS, bad);
        bad[0].closureTypeAfter = ClosureType.NONE;
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.InvalidClosureType.selector, 0));
        cal.appendSessions(XNYS, bad);

        bad = _two(1_000_000);
        bad[1] = _s(bad[0].extClose - 1, ClosureType.WEEKEND); // overlaps the previous session
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.SessionOutOfOrder.selector, 1));
        cal.appendSessions(XNYS, bad);

        cal.appendSessions(XNYS, _two(1_000_000));
        Session[] memory older = new Session[](1);
        older[0] = _s(1_000_000, ClosureType.OVERNIGHT); // before the stored tail
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.SessionOutOfOrder.selector, 2));
        cal.appendSessions(XNYS, older);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.SessionIndexOutOfRange.selector, 9));
        cal.session(XNYS, 9);
    }

    /// @dev Append-only: any valid batch grows the count by its length and never rewrites earlier sessions.
    function testFuzz_appendOnly(uint8 n, uint32 gapSeed) public {
        n = uint8(bound(n, 1, 40));
        Session[] memory s = new Session[](n);
        uint40 t = 1_700_000_000;
        for (uint256 i; i < n; ++i) {
            s[i] = _s(t, ClosureType(1 + (i % 3)));
            t = s[i].extClose + uint40(uint256(keccak256(abi.encode(gapSeed, i))) % 3 days);
        }
        vm.prank(timelock);
        cal.appendSessions(XNYS, s);
        Session memory first = cal.session(XNYS, 0);
        vm.prank(timelock);
        Session[] memory tail = new Session[](1);
        tail[0] = _s(t, ClosureType.WEEKEND);
        cal.appendSessions(XNYS, tail);
        assertEq(cal.sessionCount(XNYS), uint256(n) + 1);
        assertEq(cal.session(XNYS, 0).open, first.open);
        assertEq(cal.coverageEnd(XNYS), tail[0].close);
        for (uint256 i; i < n; ++i) {
            (uint256 idx, bool found) = cal.findSession(XNYS, s[i].extClose - 1);
            assertTrue(found);
            assertEq(idx, i);
        }
    }
}
