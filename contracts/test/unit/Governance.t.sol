// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CoreFixture} from "../utils/CoreFixture.sol";
import {ClockState, GuardianOverlay} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {CredenceGuardian} from "../../src/governance/CredenceGuardian.sol";
import {CredenceTimelock} from "../../src/governance/CredenceTimelock.sol";
import {CredenceMarket} from "../../src/core/CredenceMarket.sol";

/// @notice CredenceGuardian (§8.11: only risk-reducing, 6 h delayed unpause, haircut ≤ 10 pp for 7 days) and
///         CredenceTimelock (OZ TimelockController, no admin).
contract GovernanceTest is CoreFixture {
    function setUp() public {
        vm.warp(1_790_000_000);
        setUpCore();
    }

    function test_wiringAndConstants() public {
        assertEq(guardianC.UNPAUSE_DELAY(), 6 hours);
        assertEq(guardianC.MAX_HALT(), 7 days);
        assertEq(guardianC.HAIRCUT_TTL(), 7 days);
        assertEq(guardianC.MAX_HAIRCUT_BPS(), 1000);
        assertEq(guardianC.markets().length, 1);
        assertEq(guardianC.clock(), address(clk));
        assertEq(guardianC.safe(), safe);
        assertEq(guardianC.timelock(), timelock);
        address[] memory ms = new address[](0);
        vm.expectRevert(ICredenceErrors.AlreadyWired.selector);
        guardianC.initializeWiring(ms, address(clk));
        CredenceGuardian g = new CredenceGuardian(timelock, safe);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        g.initializeWiring(ms, address(0));
        address[] memory bad = new address[](1);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        g.initializeWiring(bad, address(clk));
        vm.prank(safe);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        g.initializeWiring(ms, address(clk));
        vm.prank(safe);
        vm.expectRevert(ICredenceErrors.NotWired.selector);
        g.haltAsset(NVDA, uint40(block.timestamp + 1 days));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new CredenceGuardian(address(0), safe);
    }

    function test_onlySafe() public {
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        guardianC.pauseBorrow(idNVDA);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        guardianC.scheduleUnpauseBorrow(idNVDA);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        guardianC.executeUnpause(idNVDA);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        guardianC.raiseHaircut(idNVDA, 100);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        guardianC.pauseCover(address(market));
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        guardianC.scheduleUnpauseCover(address(market));
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        guardianC.executeUnpauseCover(address(market));
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        guardianC.haltAsset(NVDA, uint40(block.timestamp + 1));
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        guardianC.extendClosed(NVDA, uint40(block.timestamp + 1));
        vm.stopPrank();
    }

    function test_borrowPauseOneMarketAndDelayedUnpause() public {
        vm.startPrank(safe);
        guardianC.pauseBorrow(idNVDA);
        assertTrue(market.overlay(idNVDA).borrowPaused);
        assertFalse(market.overlay(idAAPL).borrowPaused);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnpauseNotScheduled.selector, idNVDA));
        guardianC.executeUnpause(idNVDA);
        guardianC.scheduleUnpauseBorrow(idNVDA);
        uint40 at = guardianC.unpauseBorrowAt(idNVDA);
        assertEq(at, block.timestamp + 6 hours);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnpauseNotReady.selector, idNVDA, at));
        guardianC.executeUnpause(idNVDA);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownMarket.selector, bytes32(uint256(1))));
        guardianC.pauseBorrow(bytes32(uint256(1)));
        vm.stopPrank();
        // the timelock unpauses instantly
        vm.prank(timelock);
        guardianC.executeUnpause(idNVDA);
        assertFalse(market.overlay(idNVDA).borrowPaused);
        assertEq(guardianC.unpauseBorrowAt(idNVDA), 0);
    }

    function test_coverPauseAndUnpause() public {
        vm.startPrank(safe);
        guardianC.pauseCover(address(market));
        assertTrue(market.overlay(bytes32(0)).coverPaused);
        vm.expectRevert();
        guardianC.pauseCover(address(0xBEEF));
        vm.expectRevert();
        guardianC.executeUnpauseCover(address(market));
        guardianC.scheduleUnpauseCover(address(market));
        vm.expectRevert();
        guardianC.executeUnpauseCover(address(market));
        vm.warp(block.timestamp + 6 hours);
        guardianC.executeUnpauseCover(address(market));
        vm.stopPrank();
        assertFalse(market.overlay(bytes32(0)).coverPaused);
        vm.prank(safe);
        guardianC.pauseCover(address(market));
        vm.prank(timelock);
        guardianC.executeUnpauseCover(address(market));
        assertFalse(market.overlay(bytes32(0)).coverPaused);
    }

    function test_haircutOnlyRisesAndTimelockConfirms() public {
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.HaircutTooLarge.selector, 1001, 1000));
        guardianC.raiseHaircut(idNVDA, 1001);
        guardianC.raiseHaircut(idNVDA, 300);
        GuardianOverlay memory o = market.overlay(idNVDA);
        assertEq(o.haircut, 0.03e18);
        assertEq(o.haircutUntil, block.timestamp + 7 days);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.HaircutNotHigher.selector, 300, 300));
        guardianC.raiseHaircut(idNVDA, 300);
        guardianC.raiseHaircut(bytes32(0), 200); // global overlay
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownMarket.selector, bytes32(uint256(1))));
        guardianC.raiseHaircut(bytes32(uint256(1)), 100);
        vm.stopPrank();
        // after expiry a lower haircut is a fresh raise
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(safe);
        guardianC.raiseHaircut(idNVDA, 100);
        // the timelock confirms by setting new risk params, which clears the haircut
        vm.prank(timelock);
        market.setRiskParams(idNVDA, 0.74e18, 0.8e18, 0.03e18);
        assertEq(market.overlay(idNVDA).haircut, 0);
        assertEq(market.marketParams(idNVDA).maxLtv, 0.74e18);
    }

    function test_haltAndExtendClosedOnlyExtend() public {
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UntilInPast.selector, uint40(block.timestamp)));
        guardianC.haltAsset(NVDA, uint40(block.timestamp));
        uint40 tooLate = uint40(block.timestamp + 8 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICredenceErrors.UntilTooLate.selector, tooLate, uint40(block.timestamp + 7 days)
            )
        );
        guardianC.haltAsset(NVDA, tooLate);
        guardianC.haltAsset(NVDA, uint40(block.timestamp + 2 days));
        assertEq(uint8(clk.restrictedState(NVDA)), uint8(ClockState.HALTED));
        guardianC.extendClosed(AAPL, uint40(block.timestamp + 3 days));
        vm.expectRevert(); // the clock never shortens a live restriction
        guardianC.extendClosed(AAPL, uint40(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function test_marketOverlayRules() public {
        GuardianOverlay memory o;
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        market.applyOverlay(idNVDA, o);
        vm.startPrank(address(guardianC));
        o.haircut = 0.11e18;
        o.haircutUntil = uint40(block.timestamp + 1 days);
        vm.expectRevert(ICredenceErrors.OverlayNotRiskReducing.selector);
        market.applyOverlay(idNVDA, o);
        o.haircut = 0.05e18;
        o.haircutUntil = uint40(block.timestamp + 8 days);
        vm.expectRevert(ICredenceErrors.OverlayNotRiskReducing.selector);
        market.applyOverlay(idNVDA, o);
        o.haircutUntil = uint40(block.timestamp + 1 days);
        market.applyOverlay(idNVDA, o);
        o.haircut = 0.01e18;
        vm.expectRevert(ICredenceErrors.OverlayNotRiskReducing.selector);
        market.applyOverlay(idNVDA, o);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.MarketNotFound.selector, bytes32(uint256(5))));
        market.applyOverlay(bytes32(uint256(5)), o);
        vm.stopPrank();
    }

    function test_timelockHasNoAdmin() public {
        address gov = makeAddr("govSafe");
        address[] memory proposers = new address[](1);
        proposers[0] = gov;
        address[] memory executors = new address[](1); // address(0): anyone executes
        CredenceTimelock tl = new CredenceTimelock(1 hours, proposers, executors);
        assertEq(tl.getMinDelay(), 1 hours);
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), gov));
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), gov));
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)));
        assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(this)), "no deployer admin");
        // a timelocked parameter change: schedule, wait, anyone executes
        CredenceMarket m = new CredenceMarket(address(tl), address(guardianC));
        bytes memory call = abi.encodeCall(m.setReserveFeeShare, (2500));
        vm.prank(gov);
        tl.schedule(address(m), 0, call, bytes32(0), bytes32(0), 1 hours);
        vm.expectRevert();
        tl.execute(address(m), 0, call, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 1 hours);
        tl.execute(address(m), 0, call, bytes32(0), bytes32(0));
        assertEq(m.reserveFeeShareBps(), 2500);
    }
}
