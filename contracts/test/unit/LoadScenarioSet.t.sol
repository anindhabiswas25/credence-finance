// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LoadScenarioSet} from "../../script/LoadScenarioSet.s.sol";
import {IRiskEngine} from "../../src/interfaces/IRiskEngine.sol";
import {RiskParams} from "../../src/libraries/Types.sol";
import {MockRiskEngine} from "../mocks/MockRiskEngine.sol";

/// @notice The example risk bundle (contracts/test/fixtures/risk, built by `risk-cli build-set/build-joint`) loads,
///         and every hash the engine stores equals the one risk-core wrote into the file (Rust == Solidity hashing).
contract LoadScenarioSetTest is Test {
    string internal constant DIR = "test/fixtures/risk";
    string internal constant BUNDLE = "test/fixtures/risk/example-bundle.json";
    bytes32 internal constant NVDA = keccak256("NVDA:XNAS");
    bytes32 internal constant AAPL = keccak256("AAPL:XNAS");

    LoadScenarioSet internal loader;
    MockRiskEngine internal engine;

    function setUp() public {
        loader = new LoadScenarioSet();
        // the loader contract is the caller of the engine in-test, so it is both timelock and σ oracle
        engine = new MockRiskEngine(address(loader), address(loader));
    }

    function test_loadsAndVerifiesExampleBundle() public {
        loader.load(IRiskEngine(address(engine)), BUNDLE, DIR, address(loader));
        loader.verify(IRiskEngine(address(engine)), BUNDLE, DIR);

        // values straight from the files that risk-core wrote
        assertEq(
            engine.scenarioHash(NVDA, 2), 0xdba636a4e91124b94b147e6db290603769636de2331e87f86a453071b50b13d9
        );
        assertEq(engine.setLength(keccak256(abi.encodePacked(NVDA, uint8(2)))), 1000);
        assertEq(engine.jointHash(NVDA), 0xeb29fd7416935eaed593e06e349f633cfc9bfce3ca3144440da8cf23bfc32eea);
        assertEq(engine.jointHash(AAPL), 0x9630d20b40c8132a559ce804061cbc7d4a36db97a69b7d38051c6ecad41ea048);
        RiskParams memory p = engine.params();
        assertEq(p.alpha, 1e15);
        assertEq(p.kStress, 256);
        assertEq(p.minPremium, 500_000);
        assertEq(engine.sigmaFloor(NVDA, 2), 0.02e18);
        assertEq(engine.sigma(NVDA, 2), 0.04e18);
    }

    function test_skipsSigmasWhenNotTheOracle() public {
        MockRiskEngine e = new MockRiskEngine(address(loader), address(0xBEEF));
        loader.load(IRiskEngine(address(e)), BUNDLE, DIR, address(loader));
        assertEq(e.sigma(NVDA, 2), 0);
        assertEq(e.sigmaFloor(NVDA, 2), 0.02e18);
    }

    function test_verifyCatchesAnEngineThatDiffers() public {
        loader.load(IRiskEngine(address(engine)), BUNDLE, DIR, address(loader));
        uint256[] memory other = new uint256[](63);
        vm.prank(address(loader));
        engine.setScenarioSet(NVDA, 2, other, 1000);
        vm.expectRevert();
        loader.verify(IRiskEngine(address(engine)), BUNDLE, DIR);
    }
}
