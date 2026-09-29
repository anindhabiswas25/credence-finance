// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";

/// @title §15.1 concentration limit, reviewed independently (QA-sec S4 item E; BE-chain 6da23ce, ADR-0112 pending).
/// @notice Property: within an epoch, one asset's worst covered loss (Σ over its policies of max_j L) never exceeds
///         maxAssetShare × u_max × J (35 % of the pool's replay capacity), whatever the order and size of the covers,
///         while cover on another asset stays available.
contract ConcentrationTest is RiskFixture {
    function setUp() public {
        setUpRisk();
        _underwrite(uw1, 500_000e6);
        // room for ten $130k loans in the NVDA market
        _deposit(lender, 2_000_000e6);
        vm.startPrank(allocator);
        vault.deallocate(idAAPL, 1_400_000e6);
        vault.allocate(idNVDA, 1_400_000e6);
        vm.stopPrank();
        engine.setQuote(250e6, 0, 0);
        vm.warp(_closeAt(0, 0) - 1 hours); // Monday's Bell window (epoch 0)
    }

    function _cap() internal view returns (uint256) {
        return up.nav() * 0.5e18 / 1e18 * up.maxAssetShare() / 1e18; // J × u_max × share
    }

    function _try(address b, bytes32 id) internal returns (bool ok, bytes4 err) {
        usdc.mint(b, 250e6);
        vm.startPrank(b);
        usdc.approve(address(market), 250e6);
        try market.buyCover(id, 250e6, false) {
            ok = true;
        } catch (bytes memory e) {
            err = bytes4(e);
        }
        vm.stopPrank();
    }

    function test_oneAssetIsCappedAndAnotherStaysOpen() public {
        assertEq(up.maxAssetShare(), 0.35e18);
        uint256 cap = _cap();
        uint256 covered;
        bool refused;
        for (uint256 i; i < 12 && !refused; ++i) {
            address b = makeAddr(string.concat("nvda", vm.toString(i)));
            _position(b, idNVDA, tNVDA, 1_000e18, 130_000e6);
            (bool ok, bytes4 err) = _try(b, idNVDA);
            if (ok) {
                ++covered;
                assertLe(up.worstCovered(0, NVDA), cap, "never above the cap after a write");
            } else {
                assertEq(
                    err, ICredenceErrors.ConcentrationExceeded.selector, "refused by the concentration limit"
                );
                refused = true;
            }
        }
        assertTrue(refused, "the limit binds before 12 positions");
        assertGt(covered, 0);
        // another asset still gets cover in the same epoch
        address t = makeAddr("tsla");
        _position(t, idTSLA, tTSLA, 400e18, 72_000e6);
        (bool okT,) = _try(t, idTSLA);
        assertTrue(okT, "cover on another asset stays open");
    }

    /// @dev Fuzzed position sizes: the cap holds after every accepted write. ~20M gas a case (six covers), so CI runs
    ///      1,000 cases rather than profile.ci's 10,000.
    /// forge-config: ci.fuzz.runs = 1000
    function testFuzz_capHolds(uint256[6] memory sizes) public {
        uint256 cap = _cap();
        for (uint256 i; i < 6; ++i) {
            uint256 q = bound(sizes[i], 10e18, 1_500e18);
            address b = makeAddr(string.concat("b", vm.toString(i)));
            _position(b, idNVDA, tNVDA, q, q * 180 * 72 / 100 / 1e12);
            (bool ok, bytes4 err) = _try(b, idNVDA);
            if (!ok) {
                assertTrue(
                    err == ICredenceErrors.ConcentrationExceeded.selector
                        || err == ICredenceErrors.CapacityExceeded.selector,
                    "only the risk limits refuse"
                );
            }
            assertLe(up.worstCovered(0, NVDA), cap);
        }
    }
}
