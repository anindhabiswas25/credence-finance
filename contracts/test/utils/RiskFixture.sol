// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CoreFixture} from "./CoreFixture.sol";
import {ClockState, ClosureType, ClockData} from "../../src/libraries/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev The lending core with the REAL UnderwriterPool and AuctionHouse (S3) on a weekday calendar starting Monday
///      2026-10-05 (EDT). The mocked engine carries a deterministic joint stress column per asset (K = 256, z from
///      −8σ to +2.2σ) and σ = 5% for every closure type, so capacity and clearing run the risk-core ports.
abstract contract RiskFixture is CoreFixture {
    uint40 internal constant MON = 1_791_158_400; // 2026-10-05 00:00 UTC
    address internal uw1 = makeAddr("underwriter1");
    address internal uw2 = makeAddr("underwriter2");
    address internal lender = makeAddr("lender");

    function _realRisk() internal pure override returns (bool) {
        return true;
    }

    function setUpRisk() internal {
        vm.warp(MON + 13 hours); // Mon 09:00 ET
        setUpCore();
        assertEq(calMonday, MON, "fixture Monday");
        _loadStress();
        _deposit(lender, 1_500_000e6);
        vm.startPrank(allocator);
        vault.deallocate(idAAPL, 1_000_000e6); // the supply queue put everything into AAPL
        vault.allocate(idNVDA, 500_000e6);
        vault.allocate(idTSLA, 500_000e6);
        vm.stopPrank();
        _day(0, 0);
    }

    function _loadStress() internal {
        uint256[] memory col = new uint256[](16);
        for (uint256 j; j < 256; ++j) {
            int16 z = int16(int256(-8000) + int256(j) * 40); // −8.000 … +2.200 σ
            col[j / 16] |= uint256(uint16(z)) << (16 * (j % 16));
        }
        vm.startPrank(timelock);
        for (uint256 i; i < 3; ++i) {
            bytes32 a = [NVDA, AAPL, TSLA][i];
            engine.setJointColumn(a, col);
            for (uint8 t = 1; t <= 3; ++t) {
                engine.updateSigma(a, t, 0.05e18);
            }
        }
        vm.stopPrank();
    }

    /// @dev Every asset in REGULAR in session (w, d) (the market sends the session index as the cover epoch); the
    ///      next close is that day's 16:00 ET, a WEEKEND closure on Friday.
    function _day(uint256 w, uint256 d) internal {
        bool fri = d == 4;
        for (uint256 i; i < 3; ++i) {
            bytes32 a = [NVDA, AAPL, TSLA][i];
            clk.setState(a, ClockState.REGULAR);
            clk.setNextClose(
                a, _closeAt(w, d), fri ? ClosureType.WEEKEND : ClosureType.OVERNIGHT, fri ? 3 : 1
            );
            clk.setCursor(a, uint32(_session(w, d)));
        }
    }

    /// @dev The closure of session `s` has started for every asset (CLOSED, REOPEN pending).
    function _closed(uint64 s, uint64 closureId) internal {
        for (uint256 i; i < 3; ++i) {
            bytes32 a = [NVDA, AAPL, TSLA][i];
            clk.setState(a, ClockState.CLOSED);
            clk.setReopen(a, closureId, s, true);
        }
    }

    /// @dev The open print of closure `closureId` arrived at `at` for every asset: REOPEN.
    function _reopen(uint64 s, uint64 closureId, uint40 at, uint128[3] memory prints) internal {
        for (uint256 i; i < 3; ++i) {
            bytes32 a = [NVDA, AAPL, TSLA][i];
            clk.setState(a, ClockState.REOPEN);
            clk.setReopen(a, closureId, s, true);
            clk.setOpenPrint(a, prints[i], at);
        }
    }

    function _underwrite(address who, uint256 assets) internal returns (uint256 shares) {
        usdc.mint(who, assets);
        vm.startPrank(who);
        usdc.approve(address(up), assets);
        shares = up.deposit(assets, who);
        vm.stopPrank();
    }

    function _position(address b, bytes32 id, MockERC20 token, uint256 q, uint256 debt) internal {
        _collateral(b, id, token, q);
        _borrow(b, id, debt);
    }

    function _cover(address b, bytes32 id, uint256 maxPremium) internal {
        usdc.mint(b, maxPremium);
        vm.startPrank(b);
        usdc.approve(address(market), maxPremium);
        market.buyCover(id, maxPremium, false);
        vm.stopPrank();
    }

    function _clockData(bytes32 a) internal view returns (ClockData memory) {
        return clk.closureInfo(a);
    }
}
