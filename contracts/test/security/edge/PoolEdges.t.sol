// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {EdgeFixture} from "./EdgeFixture.sol";
import {EpochPhase} from "../../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../../src/libraries/Errors.sol";

/// @title Underwriter pool edge cases (matrix rows E-P-*, `docs/qa/edge-cases.md`).
contract PoolEdgesTest is EdgeFixture {
    function setUp() public {
        setUpEdge();
    }

    /// E-P-01: a withdrawal request of exactly the balance works; one share more reverts `InsufficientShares`.
    function test_E_P01_withdrawRequestExactBalance() public {
        uint256 bal = up.balanceOf(uw1);
        vm.prank(uw1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.InsufficientShares.selector, bal, bal + 1));
        up.requestWithdraw(bal + 1);
        vm.prank(uw1);
        up.requestWithdraw(bal);
        assertEq(up.balanceOf(uw1), 0);
    }

    /// E-P-02: the Bell window edge decides the epoch: a request at bellWindowAt − 1 s joins tonight's epoch, one at
    ///         bellWindowAt joins the next (its NAV was already fixed at the open).
    function test_E_P02_withdrawRequestAtTheBellWindowEdge() public {
        uint40 window = _closeAt(0, 0) - 2 hours;
        vm.warp(window - 1);
        vm.prank(uw1);
        assertEq(up.requestWithdraw(1e18), 0);
        vm.warp(window);
        vm.prank(uw1);
        assertEq(up.requestWithdraw(1e18), 1);
    }

    /// E-P-03: claims before the epoch settled revert `EpochNotSettled`; a second claim reverts `NothingToClaim`.
    function test_E_P03_claimsBeforeSettlementAndTwice() public {
        vm.prank(uw1);
        up.requestWithdraw(1_000e18);
        vm.warp(_closeAt(0, 0) + 1 hours);
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(up), 1_000e6);
        assertEq(up.deposit(1_000e6, bob), 0, "queued after the close");
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.EpochNotSettled.selector, 0));
        up.claimDeposit(0);
        vm.stopPrank();
        vm.prank(uw1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.EpochNotSettled.selector, 0));
        up.claimWithdraw(0);
        _closed(0, 1);
        vm.warp(_openAt(0, 1) + 10 minutes);
        up.settleEpoch(0);
        vm.startPrank(uw1);
        assertGt(up.claimWithdraw(0), 0);
        vm.expectRevert(ICredenceErrors.NothingToClaim.selector);
        up.claimWithdraw(0);
        vm.stopPrank();
        vm.startPrank(bob);
        assertGt(up.claimDeposit(0), 0);
        vm.expectRevert(ICredenceErrors.NothingToClaim.selector);
        up.claimDeposit(0);
        vm.stopPrank();
    }

    /// E-P-04: `settleEpoch` at reopenAt + settleDelay − 1 s is not ready; at + settleDelay it settles.
    function test_E_P04_settleExactlyAtTheDelay() public {
        vm.warp(_closeAt(0, 0) - 1 hours);
        up.openEpoch(VENUE);
        _closed(0, 1);
        vm.warp(_openAt(0, 1) + 10 minutes - 1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.EpochNotReady.selector, 0, 1));
        up.settleEpoch(0);
        vm.warp(_openAt(0, 1) + 10 minutes);
        up.settleEpoch(0);
        assertEq(uint8(up.epoch(0).phase), uint8(EpochPhase.SETTLED));
    }

    /// E-P-05: last night's epoch still unsettled at the next Bell (keeper late, a REOPEN lot hanging): cover for the
    ///         new closure is refused (`PolicyEpochMismatch`) and the Bell fails closed to the pre-close sale
    ///         (ADR-0110 §3).
    function test_E_P05_unsettledEpochAtTheNextBellFailsClosed() public {
        vm.warp(_closeAt(0, 0) - 1 hours);
        up.openEpoch(VENUE);
        _closed(0, 1);
        // Tuesday: nobody settled epoch 0
        _day(0, 1);
        _position(alice, idTSLA, tTSLA, 100e18, 18_000e6); // 72 %
        engine.setSafeLtv(TSLA, 1, 0.6e18);
        vm.warp(_closeAt(0, 1) - 1 hours);
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(market), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.PolicyEpochMismatch.selector, 1, 0));
        market.buyCover(idTSLA, 1_000e6, false);
        vm.stopPrank();
        vm.warp(_closeAt(0, 1) - 15 minutes);
        vm.prank(keeper);
        market.enforceBell(idTSLA, _one(alice));
        assertEq(market.position(idTSLA, alice).coverClosureId, 0, "not covered");
        assertGt(market.position(idTSLA, alice).auctionId, 0, "in the pre-close lot");
    }

    /// E-P-06: deposits 1 base unit: outside an epoch it mints (> 0 shares); inside the Bell window it is queued
    ///         and becomes shares at settlement.
    function test_E_P06_oneUnitDeposits() public {
        usdc.mint(bob, 2);
        vm.startPrank(bob);
        usdc.approve(address(up), 2);
        assertGt(up.deposit(1, bob), 0);
        vm.warp(_closeAt(0, 0) - 1 hours);
        assertEq(up.deposit(1, bob), 0, "queued");
        vm.stopPrank();
        _closed(0, 1);
        vm.warp(_openAt(0, 1) + 10 minutes);
        up.settleEpoch(0);
        vm.prank(bob);
        assertGt(up.claimDeposit(0), 0);
    }

    /// E-P-07: resale with nothing to sell: `closeResale` reverts `NoInventory`; `gdaBuy` of an unknown GDA reverts
    ///         `UnknownGda`.
    function test_E_P07_resaleWithNothingToSell() public {
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NoInventory.selector, NVDA));
        up.closeResale(NVDA);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownGda.selector, 7));
        house.gdaBuy(7, 1, 1);
    }
}
