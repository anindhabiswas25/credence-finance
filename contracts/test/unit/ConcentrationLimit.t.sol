// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {IUnderwriterPoolEvents} from "../../src/libraries/Events.sol";

/// @notice §15.1 concentration limit (ADR-0112): one asset's worst covered loss in an epoch ≤ maxAssetShare × u_max × J,
///         enforced in `writeCover`, timelock parameter (0.35 at launch).
contract ConcentrationLimitTest is RiskFixture {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address uw = makeAddr("uw");

    function setUp() public {
        setUpRisk();
        _underwrite(uw, 500_000e6);
        engine.setQuote(250e6, 0, 0);
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        _position(bob, idNVDA, tNVDA, 1_000e18, 130_000e6);
        _position(carol, idTSLA, tTSLA, 720e18, 130_000e6);
        vm.warp(_closeAt(0, 0) - 1 hours); // Bell window of Monday's close
    }

    function _cap(uint256 share) internal view returns (uint256) {
        return up.nav() * (uint256(engine.params().uMax) * share) / 1e36;
    }

    function test_defaultIs35Percent() public view {
        assertEq(up.maxAssetShare(), 0.35e18);
    }

    function test_secondPolicyOnTheSameAssetAboveTheCap_reverts_otherAssetStillSells() public {
        _cover(alice, idNVDA, 250e6);
        uint256 w1 = up.worstCovered(0, NVDA);
        assertGt(w1, 1);
        // a cap between one and two NVDA policies (J × u_max × share = 1.5 × w1)
        uint256 j = up.nav();
        uint64 share = uint64(w1 * 3 * 1e36 / (2 * j * uint256(engine.params().uMax)));
        vm.prank(timelock);
        up.setMaxAssetShare(share);
        uint256 cap = _cap(share);
        assertGe(cap, w1);
        assertLt(cap, 2 * w1);

        usdc.mint(bob, 250e6);
        vm.startPrank(bob);
        usdc.approve(address(market), 250e6);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.ConcentrationExceeded.selector, NVDA, 2 * w1, cap)
        );
        market.buyCover(idNVDA, 250e6, false);
        vm.stopPrank();

        // TSLA is a different asset: its own worst loss is under the cap
        _cover(carol, idTSLA, 250e6);
        assertGt(up.worstCovered(0, TSLA), 1);
        assertEq(up.epoch(0).policies, 2);
    }

    function test_launchLimitBinds() public {
        // J ≈ $500,000: u_max × J = $250,000 of worst loss for the whole pool, 35 % of it ($87,500) for one asset.
        // Identical small NVDA policies are sold until the next one would take NVDA over the asset cap.
        _deposit(makeAddr("lender2"), 1_000_000e6);
        vm.startPrank(allocator);
        vault.deallocate(idAAPL, 1_000_000e6);
        vault.allocate(idNVDA, 1_000_000e6);
        vm.stopPrank();
        uint256 w;
        for (uint256 i; i < 80; ++i) {
            address b = makeAddr(string(abi.encodePacked("b", vm.toString(i))));
            _position(b, idNVDA, tNVDA, 100e18, 13_000e6);
            usdc.mint(b, 250e6);
            vm.startPrank(b);
            usdc.approve(address(market), 250e6);
            uint256 prior = up.worstCovered(0, NVDA);
            if (i > 0 && prior + w > _cap(0.35e18)) {
                // w grows by cents with interest, so the exact worstAfter is not asserted here
                vm.expectPartialRevert(ICredenceErrors.ConcentrationExceeded.selector);
                market.buyCover(idNVDA, 250e6, false);
                vm.stopPrank();
                assertGt(i, 20, "dozens of policies fit");
                assertLe(up.worstCovered(0, NVDA), _cap(0.35e18));
                assertLt(up.utilisation(0), 0.5e18, "capacity (u_max) was not what stopped it");
                return;
            }
            market.buyCover(idNVDA, 250e6, false);
            vm.stopPrank();
            if (i == 0) w = up.worstCovered(0, NVDA);
        }
        fail();
    }

    function test_setter_guards() public {
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        up.setMaxAssetShare(0.5e18);
        vm.startPrank(timelock);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        up.setMaxAssetShare(0);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        up.setMaxAssetShare(1e18 + 1);
        vm.expectEmit(false, false, false, true, address(up));
        emit IUnderwriterPoolEvents.ConcentrationLimitSet(1e18);
        up.setMaxAssetShare(1e18);
        vm.stopPrank();
        assertEq(up.maxAssetShare(), 1e18);
    }
}
