// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {Epoch, EpochPhase, Inventory, ClockState} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice UnderwriterPool edge paths: views, settlement preconditions, inventory marks with a failing oracle,
///         deposits between a close and the settlement, and a keeper tip that cannot be paid.
contract UnderwriterPoolEdgesTest is RiskFixture {
    address alice = makeAddr("alice");

    function setUp() public {
        setUpRisk();
        _underwrite(uw1, 100_000e6);
    }

    function test_viewsOutsideAnEpoch() public view {
        (uint64 e, bool live) = up.activeEpoch();
        assertFalse(live);
        assertEq(e, 0);
        assertEq(up.currentEpoch(VENUE), 0);
        assertEq(up.lossVector().length, 0);
        assertEq(up.inventoryAssets().length, 0);
        assertEq(up.reservedUnpaid(), 0);
        assertEq(up.queuedDeposits(), 0);
        (uint256 sh, uint256 paid) = up.pendingWithdraw(0, uw1);
        assertEq(sh + paid, 0);
        assertEq(up.unearnedPremiums(), 0);
    }

    function test_depositAfterTheCloseIsQueuedUntilSettlement() public {
        vm.warp(_closeAt(0, 0) + 1 hours); // Monday night: nobody opened Monday's epoch
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(up), 1_000e6);
        assertEq(up.deposit(1_000e6, alice), 0);
        vm.stopPrank();
        assertEq(up.pendingDeposit(0, alice), 1_000e6);
        assertEq(up.queuedDeposits(), 1_000e6);
        vm.warp(_openAt(0, 1) + 11 minutes);
        up.settleEpoch(0);
        vm.prank(alice);
        assertEq(up.claimDeposit(0), 1_000e18);
    }

    function test_settlementPreconditions() public {
        vm.warp(_closeAt(0, 0) - 1 hours);
        up.openEpoch(VENUE);
        // an epoch that is not the active one cannot settle while another is open
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.EpochStillOpen.selector, 0));
        up.settleEpoch(1);
        // a REOPEN auction that has not settled blocks the epoch
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        _closed(0, 1);
        uint40 printAt = _openAt(0, 1);
        vm.warp(printAt + 5);
        _reopen(0, 1, printAt, [uint128(140e18), 200e18, 250e18]);
        orc.setPrice(NVDA, 140e18);
        address[] memory bs = new address[](1);
        bs[0] = alice;
        market.flagForAuction(idNVDA, bs);
        vm.warp(printAt + 11 minutes);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.EpochNotReady.selector, 0, 2));
        up.settleEpoch(0);
        assertEq(uint8(up.epoch(0).phase), uint8(EpochPhase.OPEN));
    }

    function test_settlingANeverOpenedEpochWhileAnotherIsOpen() public {
        vm.warp(_closeAt(0, 1) - 1 hours);
        up.openEpoch(VENUE); // Tuesday's
        // Monday's epoch was never opened (no policies): it settles on its own schedule; Tuesday's stays open
        up.settleEpoch(0);
        assertEq(uint8(up.epoch(0).phase), uint8(EpochPhase.SETTLED));
        (uint64 e, bool live) = up.activeEpoch();
        assertTrue(live);
        assertEq(e, 1);
        // the open epoch itself cannot settle before its reopen
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.EpochNotReady.selector, 1, 1));
        up.settleEpoch(1);
    }

    function test_inventoryMarkWithAFailingOracle() public {
        tNVDA.mint(address(up), 10e18);
        vm.prank(address(house));
        up.backstopBuy(1, NVDA, address(tNVDA), 10e18, 150e18);
        Inventory memory inv = up.inventory(NVDA);
        assertEq(inv.cost, 1_500e6);
        uint256 navOk = up.nav();
        orc.setReverting(true);
        assertEq(up.nav(), navOk - 1_500e6, "an unreadable price marks the inventory at 0");
        orc.setReverting(false);
        // another token for the same asset is refused
        MockERC20 other = new MockERC20("x", "x", 18);
        vm.prank(address(house));
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        up.backstopBuy(2, NVDA, address(other), 1e18, 1e18);
        assertEq(up.inventoryAssets().length, 1);
    }

    function test_aTipThatCannotBePaidDoesNotBlock() public {
        vm.prank(timelock);
        tips.setPayer(address(up), false); // tips.pay now reverts for the pool
        vm.warp(_closeAt(0, 0) - 1 hours);
        vm.prank(keeper);
        up.openEpoch(VENUE);
        assertEq(usdc.balanceOf(keeper), 0);
        assertTrue(up.epoch(0).phase == EpochPhase.OPEN);
    }
}
