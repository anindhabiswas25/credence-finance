// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {RedStonePriceSource} from "../../src/oracle/RedStonePriceSource.sol";
import {FeedMarketStatus} from "../../src/libraries/Types.sol";

/// @notice RedStonePriceSource against real `redstone-primary-prod` packages recorded by BE-backend on 2026-09-28
///         (packages/feeds/test/fixtures, converted to on-chain payloads by contracts/script/redstone_fixture.py).
contract RedStonePriceSourceTest is Test {
    RedStonePriceSource src;
    address timelock = makeAddr("timelock");
    bytes32 constant NVDA = keccak256("NVDA:XNAS");
    bytes32 constant AAPL = keccak256("AAPL:XNAS");
    bytes nvdaPayload;
    bytes aaplPayload;
    uint256 nvdaTs;
    uint256 nvdaMedian;
    uint256 aaplMedian;

    function _signers() internal pure returns (address[] memory s) {
        s = new address[](5);
        s[0] = 0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774;
        s[1] = 0xdEB22f54738d54976C4c0fe5ce6d408E40d88499;
        s[2] = 0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202;
        s[3] = 0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE;
        s[4] = 0x9c5AE89C4Af6aA32cE58588DBaF90d18a855B6de;
    }

    function setUp() public {
        string memory j = vm.readFile("test/fixtures/redstone/primary-prod-20260928.json");
        nvdaPayload = vm.parseJsonBytes(j, ".NVDA.payload");
        aaplPayload = vm.parseJsonBytes(j, ".AAPL.payload");
        nvdaTs = vm.parseJsonUint(j, ".NVDA.timestampMs");
        nvdaMedian = vm.parseJsonUint(j, ".NVDA.median8");
        aaplMedian = vm.parseJsonUint(j, ".AAPL.median8");
        src = new RedStonePriceSource(timelock, _signers(), 3);
        vm.startPrank(timelock);
        src.setFeed(NVDA, bytes32("NVDA"));
        src.setFeed(AAPL, bytes32("AAPL"));
        vm.stopPrank();
        vm.warp(nvdaTs / 1000 + 30);
    }

    function _ids(bytes32 a) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = a;
    }

    function test_acceptsTheRecordedPackages() public {
        src.submit(nvdaPayload, _ids(NVDA));
        (uint256 p, uint40 at, uint8 st) = src.latest(NVDA);
        assertEq(p, nvdaMedian * 1e10, "median of 5 signers, 8 decimals -> WAD");
        assertEq(at, nvdaTs / 1000);
        assertEq(st, FeedMarketStatus.REGULAR);
        (uint256 rp, uint40 rat) = src.lastRegular(NVDA);
        assertEq(rp, p);
        assertEq(rat, at);
        (uint256 cp,, uint40 day) = src.officialClose(NVDA);
        assertEq(cp, p);
        assertEq(day, at / 1 days);
        (uint256 tp, bool ok) = src.twap(NVDA, 0);
        assertEq(tp, p);
        assertTrue(ok);
        (, ok) = src.twap(NVDA, 3600);
        assertFalse(ok, "no hour of history");
        // the first regular print of the day stands in for the open (ADR-0009 D1)
        (uint256 op,, bool oOk) = src.officialOpen(NVDA, uint40(at - 10 minutes));
        assertEq(op, p);
        assertTrue(oOk);
        (,, oOk) = src.officialOpen(NVDA, uint40(at - 2 hours));
        assertFalse(oOk, "more than 30 min after the open");
        src.submit(aaplPayload, _ids(AAPL));
        (p,,) = src.latest(AAPL);
        assertEq(p, aaplMedian * 1e10);
    }

    function test_freshnessWindow() public {
        vm.warp(nvdaTs / 1000 + 181);
        vm.expectRevert(
            abi.encodeWithSelector(
                RedStonePriceSource.StaleData.selector, NVDA, nvdaTs / 1000, nvdaTs / 1000 + 181
            )
        );
        src.submit(nvdaPayload, _ids(NVDA));
        vm.warp(nvdaTs / 1000 - 61);
        vm.expectRevert(
            abi.encodeWithSelector(
                RedStonePriceSource.StaleData.selector, NVDA, nvdaTs / 1000, nvdaTs / 1000 - 61
            )
        );
        src.submit(nvdaPayload, _ids(NVDA));
        vm.warp(nvdaTs / 1000 - 60);
        src.submit(nvdaPayload, _ids(NVDA)); // 60 s ahead is allowed
        vm.expectRevert(
            abi.encodeWithSelector(RedStonePriceSource.NotNewer.selector, NVDA, nvdaTs / 1000, nvdaTs / 1000)
        );
        src.submit(nvdaPayload, _ids(NVDA));
    }

    function test_thresholdAndAuthorisedSigners() public {
        // only two of the five recorded signers are authorised: 2 < 3
        address[] memory s = new address[](5);
        (s[0], s[1], s[2], s[3], s[4]) =
        (_signers()[0], _signers()[1], makeAddr("x"), makeAddr("y"), makeAddr("z"));
        vm.prank(timelock);
        src.setCommittee(s, 3);
        vm.expectRevert(abi.encodeWithSelector(RedStonePriceSource.NotEnoughSigners.selector, NVDA, 2, 3));
        src.submit(nvdaPayload, _ids(NVDA));
        vm.prank(timelock);
        src.setCommittee(s, 2);
        src.submit(nvdaPayload, _ids(NVDA));
        vm.prank(timelock);
        vm.expectRevert(RedStonePriceSource.InvalidCommittee.selector);
        src.setCommittee(s, 6);
        vm.expectRevert(RedStonePriceSource.Unauthorized.selector);
        src.setCommittee(s, 3);
    }

    function test_tamperedValuesLoseTheirSigner() public {
        bytes memory p = nvdaPayload;
        // each package is 77 + 65 bytes; flip the last value byte of packages 0, 1 and 2
        for (uint256 i; i < 3; ++i) {
            p[i * 142 + 63] = bytes1(uint8(p[i * 142 + 63]) ^ 0x01);
        }
        vm.expectRevert(abi.encodeWithSelector(RedStonePriceSource.NotEnoughSigners.selector, NVDA, 2, 3));
        src.submit(p, _ids(NVDA));
        // one tampered package still leaves 4 honest signers
        p = nvdaPayload;
        p[63] = bytes1(uint8(p[63]) ^ 0x01);
        vm.recordLogs();
        src.submit(p, _ids(NVDA));
        (,,, uint8 n) = abi.decode(vm.getRecordedLogs()[0].data, (uint256, uint40, uint8, uint8));
        assertEq(n, 4, "the tampered package's signer is dropped");
    }

    function test_eventCarriesTheSignerCount() public {
        vm.expectEmit(true, false, false, true);
        emit RedStonePriceSource.PriceAccepted(NVDA, nvdaMedian * 1e10, uint40(nvdaTs / 1000), 2, 5);
        src.submit(nvdaPayload, _ids(NVDA));
    }

    function test_malformedPayloads() public {
        bytes memory p = nvdaPayload;
        p[p.length - 1] = 0x01; // marker
        vm.expectRevert(abi.encodeWithSelector(RedStonePriceSource.BadPayload.selector, 1));
        src.submit(p, _ids(NVDA));
        vm.expectRevert(abi.encodeWithSelector(RedStonePriceSource.BadPayload.selector, 1));
        src.submit(hex"00", _ids(NVDA));
        // a payload for another feed has no NVDA value
        vm.expectRevert(abi.encodeWithSelector(RedStonePriceSource.NotEnoughSigners.selector, AAPL, 0, 3));
        src.submit(nvdaPayload, _ids(AAPL));
        vm.expectRevert(abi.encodeWithSelector(RedStonePriceSource.UnknownAsset.selector, bytes32("?")));
        src.submit(nvdaPayload, _ids(bytes32("?")));
        // a package count larger than the packages present
        p = nvdaPayload;
        uint256 at = p.length - 9 - 3 - 8 - 2; // count field (metadata "credence" is 8 bytes)
        p[at + 1] = 0x06;
        vm.expectPartialRevert(RedStonePriceSource.BadPayload.selector);
        src.submit(p, _ids(NVDA));
    }
}
