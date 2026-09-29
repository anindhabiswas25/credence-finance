// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {Auction} from "../../src/libraries/Types.sol";
import {CredenceMarket} from "../../src/core/CredenceMarket.sol";

/// @title Gas-guarded try/catch (ADR-0109; §15.1 walkthrough, QA-sec S4 item E).
/// @notice A permissionless caller picks the gas limit. EIP-150 leaves 1/64 with the caller, so at the right limit only
///         the *inner* call runs out of gas and a plain try/catch would take its fail-closed branch. For the two sites
///         where that branch moves money or risk the wrong way, sweep the caller's gas limit across the whole range
///         where the transaction can still succeed and require: either the call reverts, or it did the full-gas thing.
///           - enforceBell → autoCover (market → pool): the fallback is a pre-close SALE instead of cover.
///           - settlePositions → _waterfall → pool.payShortfall: the fallback is the reserve, then the SENIOR vault.
contract GasGriefingTest is RiskFixture {
    address internal alice = makeAddr("alice");

    function setUp() public {
        setUpRisk();
        _underwrite(uw1, 500_000e6);
    }

    function _one(address b) internal pure returns (address[] memory bs) {
        bs = new address[](1);
        bs[0] = b;
    }

    /// @dev Calls `data` on the market with every gas limit from `lo` to `hi` in `steps` steps (state reverted after
    ///      each) and runs `ok()` after every call that succeeded. Returns how many succeeded.
    function _sweep(bytes memory data, uint256 lo, uint256 hi, uint256 steps, function() internal view ok)
        internal
        returns (uint256 successes)
    {
        for (uint256 i; i <= steps; ++i) {
            uint256 g = lo + (hi - lo) * i / steps;
            uint256 snap = vm.snapshotState();
            vm.prank(keeper);
            (bool success,) = address(market).call{gas: g}(data);
            if (success) {
                ++successes;
                ok();
            }
            vm.revertToState(snap);
        }
    }

    function _gasOf(bytes memory data) internal returns (uint256 used) {
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        uint256 g0 = gasleft();
        (bool success,) = address(market).call(data);
        used = g0 - gasleft();
        assertTrue(success, "the full-gas call succeeds");
        vm.revertToState(snap);
    }

    // ───────────── enforceBell → autoCover ─────────────

    function _covered() internal view {
        assertEq(market.position(idTSLA, alice).coverClosureId, 1, "succeeded, so it must have auto-covered");
        assertEq(market.position(idTSLA, alice).auctionId, 0, "never pushed into a pre-close sale by gas");
    }

    function test_enforceBell_gasCannotForceASale() public {
        _position(alice, idTSLA, tTSLA, 100e18, 18_000e6);
        engine.setSafeLtv(TSLA, 1, 0.6e18); // 72% needs action at the Bell
        vm.warp(_closeAt(0, 0) - 10 minutes);
        bytes memory data = abi.encodeCall(CredenceMarket.enforceBell, (idTSLA, _one(alice)));
        uint256 used = _gasOf(data);
        uint256 ok = _sweep(data, used / 4, used + used / 10, 300, _covered);
        assertGt(ok, 0, "the sweep reached the succeeding range");
    }

    // ───────────── settlePositions → payShortfall ─────────────

    uint256 internal seniorBefore;

    function _poolPaid() internal view {
        assertEq(
            market.marketState(idNVDA).totalSupplyAssets,
            seniorBefore,
            "succeeded, so the pool (not the senior vault) paid the shortfall"
        );
    }

    function test_settle_gasCannotPushAShortfallToSeniors() public {
        vm.warp(_openAt(0, 1) + 1 hours);
        _day(0, 1);
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        orc.setPrice(NVDA, 100e18); // value 100k < debt 130k: full close, short
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(alice));
        uint64 id = market.position(idNVDA, alice).auctionId;
        vm.warp(block.timestamp + 15);
        house.fixLots(id);
        Auction memory a = house.auction(id);
        vm.warp(a.deadlines[3]);
        house.clear(id); // no bid: the pool backstops at R = $97, proceeds 97k < debt
        seniorBefore = market.marketState(idNVDA).totalSupplyAssets;
        bytes memory data = abi.encodeCall(CredenceMarket.settlePositions, (id, _one(alice)));
        uint256 used = _gasOf(data);
        uint256 ok = _sweep(data, used / 4, used + used / 10, 300, _poolPaid);
        assertGt(ok, 0, "the sweep reached the succeeding range");
    }
}
