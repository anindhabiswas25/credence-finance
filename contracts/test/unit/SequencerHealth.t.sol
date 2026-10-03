// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {SequencerHealth} from "../../src/oracle/SequencerHealth.sol";

contract SequencerHealthTest is Test {
    SequencerHealth sh;
    address clock = makeAddr("clock");

    function setUp() public {
        sh = new SequencerHealth();
    }

    function test_wiringOnce() public {
        vm.prank(makeAddr("x"));
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        sh.setClock(clock);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        sh.setClock(address(0));
        sh.setClock(clock);
        assertEq(sh.clock(), clock);
        vm.expectRevert(ICredenceErrors.AlreadyWired.selector);
        sh.setClock(clock);
    }

    function test_recordAndGap() public {
        sh.setClock(clock);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        sh.recordPoke();
        vm.warp(1000);
        vm.prank(clock);
        assertEq(sh.recordPoke(), 0);
        assertEq(sh.lastSeen(), 1000);
        vm.warp(1300);
        assertEq(sh.gapSince(0), 300);
        assertEq(sh.gapSince(1200), 100); // max(lastSeen, t)
        assertEq(sh.gapSince(2000), 0); // in the future
        vm.prank(clock);
        assertEq(sh.recordPoke(), 1000);
        (bool up, uint40 since) = sh.isUp();
        assertTrue(up);
        assertEq(since, 0);
    }
}
