// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {console2} from "forge-std/Test.sol";
import {MarketState} from "../../src/libraries/Types.sol";
import {CoreFixture} from "../utils/CoreFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MarketHandler, Sys} from "./MarketHandler.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

/// @notice Lending-core invariants (Build Guide §8.4.4, §8.5, §14.2) at the default 256 runs × depth 128:
///         INV-MKT-01..03, INV-LIQ-01/02, INV-REPAY-01/02 (with the engine, oracle and clock reverting),
///         INV-WF-01, INV-COV-01, INV-SV-01, INV-DEBT-01, INV-GOV-01.
contract MarketInvariantsTest is CoreFixture {
    MarketHandler internal h;

    function setUp() public {
        vm.warp(1_790_000_000);
        setUpCore();
        _deposit(makeAddr("seed-lender"), 300_000e6);
        vm.startPrank(allocator);
        vault.deallocate(idAAPL, 200_000e6);
        vault.allocate(idNVDA, 100_000e6);
        vault.allocate(idTSLA, 100_000e6);
        vm.stopPrank();
        Sys memory sys = Sys({
            market: market,
            vault: vault,
            reserve: reserve,
            guardian: guardianC,
            usdc: usdc,
            tokens: [tNVDA, tAAPL, tTSLA],
            ids: [idNVDA, idAAPL, idTSLA],
            assets: [NVDA, AAPL, TSLA],
            clk: clk,
            orc: orc,
            engine: engine,
            pool: pool,
            ah: ah,
            timelock: timelock,
            safe: safe,
            allocator: allocator
        });
        h = new MarketHandler(sys);
        pool.setPremium(5e6, 0.1e18);
        usdc.mint(address(tips), 1_000_000e6);
        targetContract(address(h));
        // weight the lending lifecycle (each entry is one ticket in the draw), so every run reaches the Bell, cover,
        // liquidation and settlement paths, not only deposits and attacks
        bytes4[] memory w = new bytes4[](36);
        bytes4[12] memory heavy = [
            h.borrow.selector,
            h.borrow.selector,
            h.borrow.selector,
            h.advance.selector,
            h.advance.selector,
            h.shock.selector,
            h.buyCover.selector,
            h.enforceBell.selector,
            h.flag.selector,
            h.auction.selector,
            h.auction.selector,
            h.repay.selector
        ];
        bytes4[12] memory light = [
            h.deposit.selector,
            h.withdraw.selector,
            h.requestRedeem.selector,
            h.processQueue.selector,
            h.claimRedeem.selector,
            h.rebalance.selector,
            h.addCollateral.selector,
            h.withdrawCollateral.selector,
            h.claimFees.selector,
            h.fundBackstops.selector,
            h.guardianAct.selector,
            h.attack.selector
        ];
        for (uint256 i; i < 12; ++i) {
            w[i] = heavy[i];
            w[12 + i] = heavy[i];
            w[24 + i] = light[i];
        }
        bytes4[] memory rest = new bytes4[](4);
        (rest[0], rest[1], rest[2], rest[3]) =
        (h.recover.selector, h.repayWhileBroken.selector, h.setAutoCover.selector, h.shock.selector);
        bytes4[] memory all = new bytes4[](40);
        for (uint256 i; i < 36; ++i) {
            all[i] = w[i];
        }
        for (uint256 i; i < 4; ++i) {
            all[36 + i] = rest[i];
        }
        targetSelector(StdInvariant.FuzzSelector({addr: address(h), selectors: all}));
        excludeSender(address(market));
        excludeSender(address(vault));
    }

    function _ids() internal view returns (bytes32[3] memory) {
        return [idNVDA, idAAPL, idTSLA];
    }

    /// INV-MKT-01: loanToken.balanceOf(market) + Σ B ≥ Σ (S + F_pool + F_treasury)
    function invariant_MKT01_solvency() public view {
        uint256 lhs = usdc.balanceOf(address(market));
        uint256 rhs;
        bytes32[3] memory ids = _ids();
        for (uint256 i; i < 3; ++i) {
            MarketState memory st = market.marketState(ids[i]);
            lhs += st.totalBorrowAssets;
            rhs += uint256(st.totalSupplyAssets) + st.poolFeeAccrued + st.treasuryFeeAccrued;
        }
        assertGe(lhs, rhs);
    }

    /// INV-MKT-02: B ≤ S + F per market
    function invariant_MKT02_borrowsCovered() public view {
        bytes32[3] memory ids = _ids();
        for (uint256 i; i < 3; ++i) {
            MarketState memory st = market.marketState(ids[i]);
            assertLe(
                st.totalBorrowAssets,
                uint256(st.totalSupplyAssets) + st.poolFeeAccrued + st.treasuryFeeAccrued
            );
        }
    }

    /// INV-MKT-03: Σ position.collateral == totalCollateral, and the market holds at least that many tokens
    function invariant_MKT03_collateral() public view {
        bytes32[3] memory ids = _ids();
        MockERC20[3] memory toks = [tNVDA, tAAPL, tTSLA];
        address[4] memory bs = h.borrowerList();
        for (uint256 i; i < 3; ++i) {
            uint256 sum;
            for (uint256 j; j < 4; ++j) {
                sum += market.position(ids[i], bs[j]).collateral;
            }
            uint256 total = market.marketState(ids[i]).totalCollateral;
            assertEq(sum, total);
            assertGe(toks[i].balanceOf(address(market)), total);
        }
    }

    /// INV-DEBT-01: Σ debt ≈ totalBorrowAssets within one unit per position (each debt rounds up)
    function invariant_DEBT01_debtSums() public view {
        bytes32[3] memory ids = _ids();
        address[4] memory bs = h.borrowerList();
        for (uint256 i; i < 3; ++i) {
            uint256 sum;
            for (uint256 j; j < 4; ++j) {
                sum += market.debtOf(ids[i], bs[j]);
            }
            uint256 b = market.marketState(ids[i]).totalBorrowAssets;
            assertLe(b, sum + 5, "B <= sum debt + n");
            assertLe(sum, b + 5, "sum debt <= B + n");
        }
    }

    /// INV-LIQ-01 (no collateral leaves while shut) and INV-LIQ-02 (no EMERGENCY sale of a covered position)
    function invariant_LIQ01_noLiquidationWhileShut() public view {
        assertEq(h.ghostLiqViolations(), 0);
    }

    function invariant_REPAY_neverReverts() public view {
        assertEq(h.ghostRepayFailures(), 0);
    }

    function invariant_WF01_waterfallOrder() public view {
        assertEq(h.ghostWaterfallViolations(), 0);
    }

    function invariant_COV01_coverWindow() public view {
        assertEq(h.ghostCoverViolations(), 0);
    }

    function invariant_SV01_sharePriceFallsOnlyOnLoss() public view {
        assertEq(h.ghostSharePriceViolations(), 0);
    }

    function invariant_GOV01_onlyTimelockAndSafeGuardian() public view {
        assertEq(h.ghostGovViolations(), 0);
    }

    /// @dev Depth of each run (visible with -vv): borrows, covers, Bells, flags, settlements, senior losses.
    function afterInvariant() external view {
        console2.log(
            string.concat(
                "depth: borrows ",
                vm.toString(h.okBorrows()),
                ", covers ",
                vm.toString(h.okCovers()),
                ", bells ",
                vm.toString(h.okBells()),
                ", flags ",
                vm.toString(h.okFlags()),
                ", settles ",
                vm.toString(h.okSettles()),
                ", withdraws ",
                vm.toString(h.okWithdraws()),
                ", senior losses ",
                vm.toString(h.ghostSeniorLosses())
            )
        );
    }
}
