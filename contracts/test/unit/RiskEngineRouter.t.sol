// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {RiskParams} from "../../src/libraries/Types.sol";
import {IRiskEngine} from "../../src/interfaces/IRiskEngine.sol";
import {IRiskEngineEvents} from "../../src/libraries/Events.sol";
import {RiskEngineRouter} from "../../src/risk/RiskEngineRouter.sol";
import {MockPricingProgram, MockAuctionMathProgram} from "../mocks/MockStylusPrograms.sol";

/// @notice RiskEngineRouter (R-24, ADR-0108) against Solidity stand-ins of the two Stylus programs: wiring guards,
///         writer gating, σ / κ / u_max / K injection into the capacity math, forwarding of every argument, and the
///         re-emitted engine events. The real programs are covered by `make stylus-test` and `make devnode-integration`.
contract RiskEngineRouterTest is Test {
    address timelock = makeAddr("timelock");
    address sigmaOracle = makeAddr("sigmaOracle");
    RiskEngineRouter router;
    MockPricingProgram pricing;
    MockAuctionMathProgram math;
    bytes32 constant A = keccak256("NVDA:XNAS");

    function setUp() public {
        router = new RiskEngineRouter(timelock, sigmaOracle);
        pricing = new MockPricingProgram(address(router));
        math = new MockAuctionMathProgram(address(router));
        router.initializeWiring(address(pricing), address(math));
    }

    function test_constructorAndWiringGuards() public {
        vm.expectRevert(IRiskEngine.Unauthorized.selector);
        new RiskEngineRouter(address(0), sigmaOracle);
        vm.expectRevert(IRiskEngine.Unauthorized.selector);
        new RiskEngineRouter(timelock, address(0));
        // second wiring, or by someone else
        vm.expectRevert(IRiskEngine.Unauthorized.selector);
        router.initializeWiring(address(pricing), address(math));
        RiskEngineRouter r2 = new RiskEngineRouter(timelock, sigmaOracle);
        vm.prank(makeAddr("x"));
        vm.expectRevert(IRiskEngine.Unauthorized.selector);
        r2.initializeWiring(address(pricing), address(math));
        // programs must name the router as their writer
        vm.expectRevert(IRiskEngine.Unauthorized.selector);
        r2.initializeWiring(address(pricing), address(math)); // pricing's owner is `router`, not r2
        MockPricingProgram p2 = new MockPricingProgram(address(r2));
        p2.setOwners(address(r2), address(1));
        vm.expectRevert(IRiskEngine.Unauthorized.selector);
        r2.initializeWiring(address(p2), address(math));
        p2.setOwners(address(r2), address(r2));
        vm.expectRevert(IRiskEngine.Unauthorized.selector);
        r2.initializeWiring(address(p2), address(math)); // math's owner is `router`
        math.setOwner(address(r2));
        r2.initializeWiring(address(p2), address(math));
        assertEq(address(r2.pricing()), address(p2));
        assertEq(address(r2.auction()), address(math));
    }

    function test_setSigmaOracle() public {
        vm.expectRevert(IRiskEngine.Unauthorized.selector);
        router.setSigmaOracle(address(9));
        vm.startPrank(timelock);
        vm.expectRevert(IRiskEngine.Unauthorized.selector);
        router.setSigmaOracle(address(0));
        router.setSigmaOracle(address(9));
        vm.stopPrank();
        assertEq(router.sigmaOracle(), address(9));
    }

    function test_writersAreGatedAndReemit() public {
        uint256[] memory z = new uint256[](2);
        vm.expectRevert(IRiskEngine.Unauthorized.selector);
        router.setScenarioSet(A, 2, z, 32);
        vm.expectRevert(IRiskEngine.Unauthorized.selector);
        router.setJointColumn(A, z);
        vm.expectRevert(IRiskEngine.Unauthorized.selector);
        router.setSigmaFloor(A, 2, 1);
        RiskParams memory p = RiskParams(0.002e18, 0.04e18, 1e18, 0.15e18, 4e18, 0.975e18, 0.4e18, 1e6, 128);
        vm.expectRevert(IRiskEngine.Unauthorized.selector);
        router.setParams(p);
        vm.expectRevert(IRiskEngine.Unauthorized.selector);
        router.updateSigma(A, 2, 0.05e18);

        vm.startPrank(timelock);
        vm.expectEmit(address(router));
        emit IRiskEngineEvents.ScenarioSetUpdated(A, 2, keccak256(abi.encode(A, uint8(2))), 32);
        router.setScenarioSet(A, 2, z, 32);
        vm.expectEmit(address(router));
        emit IRiskEngineEvents.ParamsUpdated(p);
        router.setParams(p);
        vm.expectEmit(address(router));
        emit IRiskEngineEvents.JointColumnUpdated(A, keccak256(abi.encode("joint", A)));
        router.setJointColumn(A, z);
        vm.expectEmit(address(router));
        emit IRiskEngineEvents.SigmaFloorSet(A, 2, 7);
        router.setSigmaFloor(A, 2, 7);
        vm.stopPrank();
        vm.prank(sigmaOracle);
        vm.expectEmit(address(router));
        emit IRiskEngineEvents.SigmaUpdated(A, 2, 0.05e18);
        router.updateSigma(A, 2, 0.05e18);

        assertEq(pricing.setN(A, 2), 32);
        assertEq(math.jointK(A), 128, "K comes from the pricing program's params");
        assertEq(pricing.floorOf(A, 2), 7);
        assertEq(router.sigma(A, 2), 0.05e18);
        assertEq(router.sigmaAt(A, 2), 0.05e6);
        assertEq(router.params().kStress, 128);
        assertEq(router.scenarioHash(A, 2), keccak256(abi.encode(A, uint8(2))));
        assertEq(router.jointHash(A), keccak256(abi.encode("joint", A)));
    }

    function test_forwarding() public {
        vm.prank(sigmaOracle);
        router.updateSigma(A, 2, 0.05e18);
        assertEq(router.safeLtv(A, 2, 0.75e18, 3), 0.75e18 - 5);
        (uint8 st, uint256 c, uint256 d) = router.bellStatus(A, 2, 100, 70, 0.75e18, 0, false);
        assertEq(st, 2);
        (st,,) = router.bellStatus(A, 1, 100, 70, 0.75e18, 0, true);
        assertEq(st, 2);
        assertEq(c + d, 170);
        (uint256 prem, uint256 el, uint256 es) = router.quoteCover(A, 2, 3, 100, 70, 5);
        assertEq(prem, 8);
        assertEq(el + es, 170);
        // capacity math gets σ of the asset and κ / K from the pricing params
        uint256[] memory v = router.coverLossVector(A, 2, 100, 70);
        assertEq(v[0], 0.05e18);
        assertEq(v[1], 0.03e18);
        assertEq(v[2], 256);
        assertEq(v[3] + v[4], 170);
        bytes32[] memory assets = new bytes32[](1);
        assets[0] = A;
        uint8[] memory types = new uint8[](1);
        types[0] = 2;
        uint256[] memory one = new uint256[](1);
        (bool ok, uint256 u, uint256 w) =
            router.poolCapacity(new uint256[](2), new uint256[](3), assets, types, one, one, 9);
        assertTrue(ok);
        assertEq(u, 0.05e18 + 5 + 0.03e18 + 0.5e18, "sigmas + kappa + uMax forwarded");
        assertEq(w, 9 + 256);
        vm.expectRevert(abi.encodeWithSelector(IRiskEngine.MathError.selector, 3));
        router.poolCapacity(new uint256[](0), new uint256[](0), assets, new uint8[](0), one, one, 9);
        assertEq(router.liquidationLot(5, 7, 0, 0, 0, 0, 0, 18, 6), 12);
        assertEq(router.precloseLot(5, 7, 0, 0, 0, 0, 18, 6), 35);
        uint256[] memory q = new uint256[](2);
        (q[0], q[1]) = (3, 4);
        (uint256 pStar, uint256[] memory fills, uint256 qPool) = router.clear(q, q, new bytes32[](2), 11, 13);
        assertEq(pStar, 13);
        assertEq(fills[1], 4);
        assertEq(qPool, 11);
    }
}
