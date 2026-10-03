// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {EdgeFixture} from "./EdgeFixture.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {ICredenceErrors} from "../../../src/libraries/Errors.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @title Senior vault edge cases (matrix rows E-V-*, `docs/qa/edge-cases.md`).
contract VaultEdgesTest is EdgeFixture {
    function setUp() public {
        setUpEdge();
    }

    function _drainNvda(uint256 leave) internal {
        _collateral(alice, idNVDA, tNVDA, 10_000e18);
        _borrow(alice, idNVDA, market.liquidity(idNVDA) - leave);
    }

    /// E-V-01: a market fully borrowed: `maxWithdraw` counts only what can leave, and a withdrawal one unit above it
    ///         reverts `ERC4626ExceededMaxWithdraw` instead of paying partially.
    function test_E_V01_withdrawAtTheLiquidityEdge() public {
        _drainNvda(0);
        uint256 max = vault.maxWithdraw(lender);
        assertEq(max, market.liquidity(idAAPL) + market.liquidity(idTSLA) + vault.idle());
        vm.prank(lender);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, lender, max + 1, max)
        );
        vault.withdraw(max + 1, lender, lender);
        vm.prank(lender);
        vault.withdraw(max, lender, lender);
        assertEq(vault.maxWithdraw(lender), 0);
    }

    /// E-V-02: the redeem queue is strict FIFO (R-17): a head request larger than the liquidity blocks a smaller one
    ///         behind it; both go through once the borrower repays.
    function test_E_V02_redeemQueueHeadOfLineBlocking() public {
        _drainNvda(0);
        uint256 big = vault.balanceOf(lender) * 9 / 10; // ≈ 1.35M > the ≈ 1M left
        vm.prank(lender);
        uint256 r0 = vault.requestRedeem(big, lender);
        _deposit(bob, 10_000e6);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 r1 = vault.requestRedeem(bobShares, bob);
        vault.processQueue(10);
        assertFalse(vault.redeemRequest(r0).processed);
        assertFalse(vault.redeemRequest(r1).processed, "blocked behind the head");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.RequestNotProcessed.selector, r1));
        vault.claimRedeem(r1);
        // the borrower repays; the queue drains in order
        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(market), type(uint256).max);
        market.repay(idNVDA, alice, 0, market.position(idNVDA, alice).borrowShares);
        vm.stopPrank();
        vault.processQueue(10);
        assertTrue(vault.redeemRequest(r0).processed);
        assertTrue(vault.redeemRequest(r1).processed);
    }

    /// E-V-03: claim edge cases: unknown id, a stranger, twice; the receiver (not only the owner) may claim.
    function test_E_V03_claimRedeemEdges() public {
        vm.prank(lender);
        uint256 r = vault.requestRedeem(1_000e12, bob);
        vault.processQueue(0); // a no-op
        assertFalse(vault.redeemRequest(r).processed);
        vault.processQueue(1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.RequestNotFound.selector, r + 1));
        vault.claimRedeem(r + 1);
        vm.prank(carl);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NotRequestOwner.selector, r));
        vault.claimRedeem(r);
        vm.prank(bob);
        assertGt(vault.claimRedeem(r), 0);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.RequestAlreadyClaimed.selector, r));
        vault.claimRedeem(r);
    }

    /// E-V-04 (QA-11, Low; fixed S5, ADR-0117): the vault's market list is capped at 32 (`MAX_QUEUE`) while the market
    ///         lists up to 64. Regression: at 32 the 33rd market is refused, and `disable` of an empty market frees
    ///         the slot for it (before the fix the list was append-only and a cap of 0 kept the slot).
    function test_E_V04_QA11_disableFreesASlotAt32() public {
        uint256 max = vault.MAX_QUEUE();
        bytes32 last;
        bytes32 empty;
        for (uint256 i = 3; i <= max; ++i) {
            MockERC20 t = new MockERC20("x", "x", 18);
            last = _list(address(t), keccak256(abi.encode("asset", i)));
            if (i < max) {
                vm.prank(timelock);
                vault.setCap(last, 1);
                empty = last;
            }
        }
        assertEq(vault.enabledMarkets().length, max);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.QueueTooLong.selector, max + 1, max));
        vault.setCap(last, 1);
        vm.prank(timelock);
        vault.disable(empty);
        vm.prank(timelock);
        vault.setCap(last, 1);
        assertEq(vault.enabledMarkets().length, max);
        assertEq(vault.enabledMarkets()[max - 1], last);
    }

    function _emptyMarketInQueues() internal returns (bytes32 id) {
        MockERC20 t = new MockERC20("x", "x", 18);
        id = _list(address(t), keccak256("empty"));
        vm.prank(timelock);
        vault.setCap(id, 1_000e6);
        bytes32[] memory q = new bytes32[](4);
        (q[0], q[1], q[2], q[3]) = (idAAPL, id, idTSLA, idNVDA); // in the middle of both queues
        vm.startPrank(allocator);
        vault.setSupplyQueue(q);
        vault.setWithdrawQueue(q);
        vm.stopPrank();
    }

    function _assertQueue(bytes32[] memory got, bytes32 a, bytes32 b, bytes32 c) internal pure {
        assertEq(got.length, 3);
        (bytes32 x, bytes32 y, bytes32 z) = (got[0], got[1], got[2]);
        assertTrue(x == a && y == b && z == c, "queue order kept");
    }

    /// E-V-05 (QA-11): `disable` of a market with 0 supplied, while it sits in the middle of both queues: it leaves
    ///         the enabled list and both queues (the others keep their order), its cap goes to 0, totalAssets and the
    ///         share price do not move, deposits skip it, allocate and a queue naming it revert, and `setCap`
    ///         enables it again.
    function test_E_V05_QA11_disableEmptyMarketInBothQueues() public {
        bytes32 id = _emptyMarketInQueues();
        uint256 ta = vault.totalAssets();
        uint256 px = vault.convertToAssets(1e18);
        vm.expectEmit(true, false, false, false, address(vault));
        emit MarketDisabled(id);
        vm.prank(timelock);
        vault.disable(id);
        assertEq(vault.cap(id), 0);
        assertEq(vault.enabledMarkets().length, 3);
        _assertQueue(vault.supplyQueue(), idAAPL, idTSLA, idNVDA);
        _assertQueue(vault.withdrawQueue(), idAAPL, idTSLA, idNVDA);
        assertEq(vault.totalAssets(), ta);
        assertEq(vault.convertToAssets(1e18), px);
        _deposit(bob, 10_000e6);
        assertEq(market.marketState(id).totalSupplyAssets, 0, "deposits skip it");
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownMarket.selector, id));
        vault.allocate(id, 1);
        bytes32[] memory q = new bytes32[](1);
        q[0] = id;
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownMarket.selector, id));
        vault.setWithdrawQueue(q);
        vm.prank(timelock);
        vault.setCap(id, 5e6);
        assertEq(vault.enabledMarkets().length, 4);
        vm.startPrank(allocator);
        vault.deallocate(idAAPL, 5e6); // the fixture keeps no idle cash
        vault.allocate(id, 5e6);
        vm.stopPrank();
        assertEq(vault.totalAssets(), ta + 10_000e6);
    }

    /// E-V-06 (QA-11): dust. One wei supplied makes `disable` revert `MarketNotEmpty` (a disabled market with money
    ///         in it would drop that money from totalAssets); once the allocator pulls it out, `disable` goes through.
    function test_E_V06_QA11_disableRefusesDustSupplied() public {
        bytes32 id = _emptyMarketInQueues();
        vm.startPrank(allocator);
        vault.deallocate(idAAPL, 1); // the fixture keeps no idle cash
        vault.allocate(id, 1);
        vm.stopPrank();
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.MarketNotEmpty.selector, id, 1));
        vault.disable(id);
        vm.prank(allocator);
        vault.deallocate(id, 1);
        vm.prank(timelock);
        vault.disable(id);
        assertEq(vault.cap(id), 0);
    }

    /// E-V-07 (QA-11): only the timelock may disable; an unknown or already disabled market reverts `UnknownMarket`;
    ///         a market with real supply (NVDA) is refused with its full amount.
    function test_E_V07_QA11_disableAccessAndUnknown() public {
        bytes32 id = _emptyMarketInQueues();
        vm.prank(allocator);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        vault.disable(id);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownMarket.selector, keccak256("nope")));
        vault.disable(keccak256("nope"));
        uint256 s = market.marketState(idNVDA).totalSupplyAssets;
        assertGt(s, 0);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.MarketNotEmpty.selector, idNVDA, s));
        vault.disable(idNVDA);
        vm.prank(timelock);
        vault.disable(id);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownMarket.selector, id));
        vault.disable(id);
    }

    event MarketDisabled(bytes32 indexed id);
}
