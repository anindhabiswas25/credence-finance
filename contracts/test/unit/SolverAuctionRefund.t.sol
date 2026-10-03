// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {ISettlementEvents} from "../../src/libraries/Events.sol";
import {SolverAuction} from "../../src/settlement/SolverAuction.sol";
import {MockBlocklistERC20} from "../mocks/MockBlocklistERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice SolverAuction refunds (ADR-0111 §2): an outbid solver whose token refuses the push (a blocklisted USDC
///         address) cannot block a better bid; its refund is credited and withdrawn once the block is lifted.
contract SolverAuctionRefundTest is Test {
    address timelock = makeAddr("timelock");
    address a = makeAddr("solverA");
    address b = makeAddr("solverB");
    SolverAuction venue;
    MockBlocklistERC20 usd;
    MockERC20 fund;

    function setUp() public {
        usd = new MockBlocklistERC20();
        fund = new MockERC20("fund", "F", 18);
        venue = new SolverAuction(timelock);
        vm.startPrank(timelock);
        venue.initializeWiring(address(this), address(usd)); // this test is the adapter
        venue.setSolver(a, true);
        venue.setSolver(b, true);
        vm.stopPrank();
        fund.mint(address(venue), 10e18);
        venue.open(1, address(fund), 10e18, 100e18, uint40(block.timestamp + 15 minutes));
        for (uint256 i; i < 2; ++i) {
            address s = i == 0 ? a : b;
            usd.mint(s, 10_000e6);
            vm.prank(s);
            usd.approve(address(venue), type(uint256).max);
        }
    }

    function test_blockedRefundIsCreditedAndWithdrawnLater() public {
        vm.prank(a);
        venue.bid(1, 100e18); // escrows $1,000
        usd.setBlocked(a, true);
        vm.expectEmit(true, true, false, true, address(venue));
        emit ISettlementEvents.SolverRefunded(1, a, 1_000e6, false);
        vm.prank(b);
        venue.bid(1, 100.01e18); // the better bid lands although A's refund push fails
        assertEq(venue.refundOwed(a), 1_000e6);
        (address best,) = venue.best(1);
        assertEq(best, b);
        // the adapter finalizes: B gets the lot, the adapter the payment; A's credit stays in the venue
        vm.warp(block.timestamp + 15 minutes);
        (bool filled, uint256 proceeds) = venue.finalize(1);
        assertTrue(filled);
        assertEq(proceeds, 1_000.1e6);
        assertEq(fund.balanceOf(b), 10e18);
        assertEq(usd.balanceOf(address(venue)), 1_000e6, "only A's credit remains");
        vm.prank(a);
        vm.expectRevert("blocked");
        venue.withdrawRefund();
        usd.setBlocked(a, false);
        vm.prank(a);
        assertEq(venue.withdrawRefund(), 1_000e6);
        assertEq(usd.balanceOf(a), 10_000e6);
        assertEq(venue.refundOwed(a), 0);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.SettlementNotOpen.selector, 1));
        venue.finalize(1);
    }

    function test_selfRaise_refundsOwnEscrow() public {
        vm.startPrank(a);
        venue.bid(1, 100e18);
        venue.bid(1, 101e18);
        vm.stopPrank();
        assertEq(usd.balanceOf(a), 10_000e6 - 1_010e6);
        assertEq(venue.lot(1).escrow, 1_010e6);
    }

    function test_noBid_returnsTheLot() public {
        vm.warp(block.timestamp + 15 minutes);
        (bool filled, uint256 proceeds) = venue.finalize(1);
        assertFalse(filled);
        assertEq(proceeds, 0);
        assertEq(fund.balanceOf(address(this)), 10e18);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TooLate.selector, uint40(block.timestamp)));
        venue.bid(1, 200e18);
    }
}
