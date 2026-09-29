// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {RiskFixture} from "../utils/RiskFixture.sol";
import {CoverRequest, ClosureType, BellStatus} from "../../src/libraries/Types.sol";
import {IUnderwriterPoolEvents} from "../../src/libraries/Events.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";

/// @notice J3 prototype (ADR-0114): inside `enforceBell` the pool caches the uncovered bound for the batch. Each
///         batched auto-cover must see u_after ≥ the full computation's (INV-POOL-02 never weakens) and equal to it up
///         to rounding, however many covers the batch writes across markets.
contract BellBatchTest is RiskFixture {
    address[] nv;
    address[] ts;

    function setUp() public {
        setUpRisk();
        _underwrite(uw1, 500_000e6);
        engine.setQuote(10e6, 0, 0);
        for (uint256 i; i < 6; ++i) {
            address b = makeAddr(string(abi.encodePacked("nv", vm.toString(i))));
            _position(b, idNVDA, tNVDA, 100e18 + i * 7e18, (13_300e6 + i * 931e6));
            nv.push(b);
            address c = makeAddr(string(abi.encodePacked("ts", vm.toString(i))));
            _position(c, idTSLA, tTSLA, 60e18 + i * 3e18, (11_100e6 + i * 555e6));
            ts.push(c);
        }
        // an uncovered bystander in AAPL keeps a non-zero uncovered bound in a third market
        _position(makeAddr("aaplHolder"), idAAPL, tAAPL, 1_000e18, 140_000e6);
        engine.setSafeLtv(NVDA, uint8(ClosureType.OVERNIGHT), 0.7e18);
        engine.setSafeLtv(TSLA, uint8(ClosureType.OVERNIGHT), 0.7e18);
        engine.setSafeLtv(AAPL, uint8(ClosureType.OVERNIGHT), 0.72e18);
        vm.warp(_closeAt(0, 0) - 10 minutes); // after Monday's Bell deadline
        (BellStatus st,,,) = market.bellStatus(idNVDA, nv[0]);
        assertEq(uint8(st), uint8(BellStatus.NEEDS_ACTION));
    }

    function _req(bytes32 id, bytes32 asset, address b) internal view returns (CoverRequest memory r) {
        r.marketId = id;
        r.assetId = asset;
        r.borrower = b;
        r.closureType = uint8(ClosureType.OVERNIGHT);
        r.closureDays = 1;
        r.closureId = _clockData(asset).closureId + 1;
        r.epochId = _clockData(asset).sessionCursor;
        r.collateralValue = uint256(market.position(id, b).collateral) * orc.valuationPrice(asset) / 1e30;
        r.debtProjected = market.projectedDebt(id, b);
    }

    /// @dev CoverWritten data = (epochId, assetId, premium, uAfter, worstLoss): uAfter is word 3.
    function _u(bytes memory data) internal pure returns (uint256 u) {
        assembly {
            u := mload(add(data, 128))
        }
    }

    function _uAfters() internal returns (uint256[] memory us) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IUnderwriterPoolEvents.CoverWritten.selector) ++n;
        }
        us = new uint256[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IUnderwriterPoolEvents.CoverWritten.selector) {
                us[n++] = _u(logs[i].data);
            }
        }
    }

    /// @dev One borrower at a time: the full computation (previewCover, no batch) right before each single-borrower
    ///      batch; then the same sequence as two 6-borrower batches must reproduce every u_after.
    function test_batchedCoversMatchTheFullComputation() public {
        uint256 snap = vm.snapshotState();
        uint256[] memory full = new uint256[](12);
        for (uint256 i; i < 12; ++i) {
            (uint256 uPreview, uint256 uEvent) = _single(i);
            assertGe(uEvent, uPreview, "never below the full computation (INV-POOL-02)");
            assertApproxEqAbs(uEvent, uPreview, 1e6, "equal up to rounding");
            full[i] = uPreview;
        }
        vm.revertToState(snap);
        vm.recordLogs();
        vm.startPrank(keeper);
        market.enforceBell(idNVDA, nv);
        market.enforceBell(idTSLA, ts);
        vm.stopPrank();
        uint256[] memory batched = _uAfters();
        assertEq(batched.length, 12);
        for (uint256 i; i < 12; ++i) {
            assertGe(batched[i], full[i], "batched u_after never below the full one");
            assertApproxEqAbs(batched[i], full[i], 1e6, "batched = full, up to rounding");
        }
    }

    function _single(uint256 i) internal returns (uint256 uPreview, uint256 uEvent) {
        bool n = i < 6;
        address b = n ? nv[i] : ts[i - 6];
        bytes32 id = n ? idNVDA : idTSLA;
        (, uPreview) = up.previewCover(_req(id, n ? NVDA : TSLA, b));
        address[] memory one = new address[](1);
        one[0] = b;
        vm.recordLogs();
        vm.prank(keeper);
        market.enforceBell(id, one);
        uint256[] memory u1 = _uAfters();
        assertEq(u1.length, 1, "auto-covered");
        uEvent = u1[0];
    }

    function test_batchHooksAreMarketOnly() public {
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        up.beginBellBatch();
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        up.endBellBatch();
    }
}
