// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SigmaUpdate, RiskParams} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {SigmaOracle} from "../../src/oracle/SigmaOracle.sol";
import {MockRiskEngine} from "../mocks/MockRiskEngine.sol";

/// @notice SigmaOracle (§8.10, R-15): 2-of-3 EIP-712 committee, asOfDay strictly increasing, the only σ writer.
contract SigmaOracleTest is Test {
    address timelock = makeAddr("timelock");
    SigmaOracle so;
    MockRiskEngine engine;
    uint256[3] keys;
    address[] signers;
    bytes32 constant NVDA = keccak256("NVDA:XNAS");

    function setUp() public {
        uint256[3] memory k = [uint256(0xA11CE), uint256(0xB0B), uint256(0xC4A11)];
        // ascending by address
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (vm.addr(k[j]) < vm.addr(k[i])) (k[i], k[j]) = (k[j], k[i]);
            }
        }
        keys = k;
        for (uint256 i; i < 3; ++i) {
            signers.push(vm.addr(k[i]));
        }
        so = new SigmaOracle(timelock, signers, 2);
        engine = new MockRiskEngine(timelock, address(so));
        so.initializeWiring(address(engine));
    }

    function _u(uint256 sigma, uint32 day) internal pure returns (SigmaUpdate memory) {
        return SigmaUpdate({assetId: NVDA, closureType: 2, sigma: sigma, asOfDay: day, nonce: 7});
    }

    function _sign(SigmaUpdate memory u, uint256[] memory idx) internal view returns (bytes[] memory sigs) {
        bytes32 d = so.hashUpdate(u);
        sigs = new bytes[](idx.length);
        for (uint256 i; i < idx.length; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[idx[i]], d);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    function _two() internal pure returns (uint256[] memory i) {
        i = new uint256[](2);
        (i[0], i[1]) = (0, 2);
    }

    function test_digestIsEip712() public view {
        SigmaUpdate memory u = _u(0.04e18, 20_000);
        bytes32 structHash =
            keccak256(abi.encode(so.SIGMA_TYPEHASH(), u.assetId, u.closureType, u.sigma, u.asOfDay, u.nonce));
        assertEq(so.hashUpdate(u), keccak256(abi.encodePacked("\x19\x01", so.domainSeparator(), structHash)));
        assertEq(
            so.SIGMA_TYPEHASH(),
            keccak256(
                "SigmaUpdate(bytes32 assetId,uint8 closureType,uint256 sigma,uint32 asOfDay,uint64 nonce)"
            )
        );
        (address[] memory c, uint8 t) = so.committee();
        assertEq(c.length, 3);
        assertEq(t, 2);
        assertEq(so.engine(), address(engine));
    }

    function test_submitWritesSigmaAndIsMonotonic() public {
        SigmaUpdate memory u = _u(0.04e18, 20_000);
        so.submit(u, _sign(u, _two()));
        assertEq(engine.sigma(NVDA, 2), 0.04e18);
        assertEq(so.lastAsOfDay(NVDA, 2), 20_000);
        bytes[] memory sigs = _sign(u, _two());
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.SigmaNotNewer.selector, 20_000, 20_000));
        so.submit(u, sigs); // replay
        SigmaUpdate memory v = _u(0.05e18, 20_001);
        so.submit(v, _sign(v, _two()));
        assertEq(engine.sigma(NVDA, 2), 0.05e18);
    }

    function test_signatureRules() public {
        SigmaUpdate memory u = _u(0.04e18, 1);
        uint256[] memory one = new uint256[](1);
        bytes[] memory s1 = _sign(u, one);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NotEnoughSigners.selector, 1, 2));
        so.submit(u, s1);
        uint256[] memory rev = new uint256[](2);
        (rev[0], rev[1]) = (2, 0);
        bytes[] memory s2 = _sign(u, rev);
        vm.expectRevert(ICredenceErrors.SignersNotSorted.selector);
        so.submit(u, s2);
        bytes[] memory s3 = _sign(u, _two());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, so.hashUpdate(u));
        address stranger = vm.addr(0xDEAD);
        s3[0] = abi.encodePacked(r, s, v);
        if (stranger < signers[2]) {
            vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownSigner.selector, stranger));
        } else {
            vm.expectRevert();
        }
        so.submit(u, s3);
        bytes[] memory bad = new bytes[](2);
        bad[0] = hex"1234";
        vm.expectRevert(ICredenceErrors.InvalidSignature.selector);
        so.submit(u, bad);
    }

    function test_committeeAndWiring() public {
        address[] memory two = new address[](2);
        (two[0], two[1]) = (signers[0], signers[1]);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        so.setCommittee(two, 1);
        vm.startPrank(timelock);
        so.setCommittee(two, 1);
        (address[] memory c, uint8 t) = so.committee();
        assertEq(c.length, 2);
        assertEq(t, 1);
        assertFalse(so.isSigner(signers[2]));
        vm.expectRevert(ICredenceErrors.InvalidCommittee.selector);
        so.setCommittee(two, 3);
        (two[0], two[1]) = (signers[1], signers[0]);
        vm.expectRevert(ICredenceErrors.InvalidCommittee.selector);
        so.setCommittee(two, 1); // not ascending
        vm.stopPrank();

        vm.expectRevert(ICredenceErrors.AlreadyWired.selector);
        so.initializeWiring(address(engine));
        SigmaOracle fresh = new SigmaOracle(timelock, signers, 2);
        SigmaUpdate memory u = _u(1, 1);
        bytes[] memory none = new bytes[](0);
        vm.expectRevert(ICredenceErrors.NotWired.selector);
        fresh.submit(u, none);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        fresh.initializeWiring(address(0));
        vm.prank(timelock);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        fresh.initializeWiring(address(engine));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new SigmaOracle(address(0), signers, 2);
        assertEq(fresh.timelock(), timelock);
    }
}
