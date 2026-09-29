// SPDX-License-Identifier: BUSL-1.1
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

    /// E-V-04 (QA-11, Low): the vault's market list is append-only and capped at 32 (`MAX_QUEUE`) while the market
    ///         lists up to 64: the 33rd market can never be enabled, and no market ever leaves the list (a cap of 0
    ///         keeps its slot). Pins today's behaviour; the fix is a design call (REQUEST).
    function test_E_V04_QA11_vaultMarketListIsAppendOnlyAt32() public {
        uint256 max = vault.MAX_QUEUE();
        bytes32 last;
        for (uint256 i = 3; i <= max; ++i) {
            MockERC20 t = new MockERC20("x", "x", 18);
            last = _list(address(t), keccak256(abi.encode("asset", i)));
            if (i < max) {
                vm.prank(timelock);
                vault.setCap(last, 1);
            }
        }
        vm.prank(timelock);
        vault.setCap(idNVDA, 0); // "delisting" in the vault frees nothing
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.QueueTooLong.selector, max + 1, max));
        vault.setCap(last, 1);
    }
}
