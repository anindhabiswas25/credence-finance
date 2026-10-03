// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClockFixture} from "../../utils/ClockFixture.sol";
import {
    ClockState,
    ClockData,
    MarketKind,
    FeedHealth,
    ReportKind,
    FeedMarketStatus,
    Report
} from "../../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../../src/libraries/Errors.sol";
import {CredencePriceFeed} from "../../../src/oracle/CredencePriceFeed.sol";
import {OracleAdapter} from "../../../src/oracle/OracleAdapter.sol";
import {MockAssetClock} from "../../mocks/MockAssetClock.sol";
import {MockProbeToken} from "../../mocks/MockProbeToken.sol";
import {MockTwapSource} from "../../mocks/MockTwapSource.sol";

/// @title Oracle edge cases (matrix rows E-O-*, `docs/qa/edge-cases.md`): the exact thresholds the relayer's
///        behaviour maps onto (1.5 % / 5 % disagreement, 60 s / 300 s staleness, 5 s future skew, the seq step) and
///        one vendor down.
contract OracleEdgesTest is ClockFixture {
    OracleAdapter internal ad;
    MockAssetClock internal mc;
    uint40 internal constant T0 = 1_800_000_000;

    function setUp() public {
        vm.warp(T0);
        _makeCommittee();
        feedA = new CredencePriceFeed(timelock, signers, 2);
        feedB = new CredencePriceFeed(timelock, signers, 2);
        dex = new MockTwapSource();
        MockProbeToken probe = new MockProbeToken();
        mc = new MockAssetClock();
        ad = new OracleAdapter(timelock);
        ad.setClock(address(mc));
        oracle = ad;
        vm.prank(timelock);
        ad.setAssetConfig(
            NVDA, address(feedA), address(feedB), address(dex), address(probe), MarketKind.EQUITY, 250_000e18
        );
        _cal(ClockState.REGULAR);
    }

    function _cal(ClockState s) internal {
        mc.set(s, s);
        ClockData memory d;
        d.state = s;
        mc.setData(d);
    }

    function _both(uint256 p1, uint256 p2) internal {
        _live(feedA, NVDA, p1, FeedMarketStatus.REGULAR);
        _live(feedB, NVDA, p2, FeedMarketStatus.REGULAR);
    }

    function _h() internal view returns (FeedHealth memory) {
        return ad.feedHealth(NVDA);
    }

    function _raw(uint64 seq, uint256 price, uint40 at) internal pure returns (Report memory) {
        return Report({
            assetId: NVDA,
            kind: ReportKind.LIVE,
            price: uint128(price),
            observedAt: at,
            sessionDate: 0,
            marketStatus: FeedMarketStatus.REGULAR,
            seq: seq
        });
    }

    /// E-O-01: disagreement exactly 1.5 % is still agreement; 1 wei more pauses borrowing. Exactly 5 % is not
    ///         severe; 1 wei more is.
    function test_E_O01_disagreementThresholdsAreExact() public {
        _both(100e18, 101.5e18);
        assertFalse(_h().disagreement, "exactly 1.5 %");
        _both(100e18, 101.5e18 + 1);
        assertTrue(_h().disagreement, "1.5 % + 1 wei");
        assertFalse(_h().severeDisagreement);
        _both(100e18, 105e18);
        assertFalse(_h().severeDisagreement, "exactly 5 %");
        _both(100e18, 105e18 + 1);
        assertTrue(_h().severeDisagreement, "5 % + 1 wei");
        _both(105e18 + 1, 100e18);
        assertTrue(_h().severeDisagreement, "symmetric: measured on the lower price");
    }

    /// E-O-02: a print exactly 60 s old is fresh in REGULAR, 61 s is stale; 300 s / 301 s in EXTENDED.
    function test_E_O02_stalenessBoundaries() public {
        _both(100e18, 100e18);
        vm.warp(T0 + 60);
        assertFalse(_h().stale, "60 s");
        vm.warp(T0 + 61);
        assertTrue(_h().stale, "61 s");
        _cal(ClockState.EXTENDED);
        vm.warp(T0 + 300);
        assertFalse(_h().stale, "300 s");
        vm.warp(T0 + 301);
        assertTrue(_h().stale, "301 s");
        _cal(ClockState.CLOSED);
        assertFalse(_h().stale, "no staleness while the calendar is closed");
    }

    /// E-O-03: one vendor down. Secondary silent → not stale, but no cross-check → `disagreement` (borrowing paused,
    ///         the asset keeps running). Primary silent → `stale` (the clock HALTs, fail closed).
    function test_E_O03_oneVendorDown() public {
        _live(feedA, NVDA, 100e18, FeedMarketStatus.REGULAR);
        FeedHealth memory h = _h();
        assertFalse(h.stale);
        assertTrue(h.disagreement);
        vm.warp(T0 + 61);
        _live(feedB, NVDA, 100e18, FeedMarketStatus.REGULAR);
        h = _h();
        assertTrue(h.stale, "primary silent");
        assertTrue(h.disagreement);
    }

    /// E-O-04: observedAt = now + 5 s is accepted, now + 6 s is `ReportFromFuture`; a zero price is `ZeroPrice`;
    ///         a replayed seq is `StaleReport`; a seq step of exactly 2^32 is accepted, 2^32 + 1 is not (QA-08).
    function test_E_O04_reportValidityEdges() public {
        _submit(feedA, _raw(1, 100e18, T0 + 5));
        Report[] memory rs = new Report[](1);
        rs[0] = _raw(2, 100e18, T0 + 6);
        bytes[] memory sigs = _sign(feedA, rs, 2);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.ReportFromFuture.selector, T0 + 6, T0));
        feedA.submit(rs, sigs);
        rs[0] = _raw(2, 0, T0);
        sigs = _sign(feedA, rs, 2);
        vm.expectRevert(ICredenceErrors.ZeroPrice.selector);
        feedA.submit(rs, sigs);
        rs[0] = _raw(1, 100e18, T0);
        sigs = _sign(feedA, rs, 2);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.StaleReport.selector, NVDA, 1, 1));
        feedA.submit(rs, sigs);
        uint64 step = feedA.MAX_SEQ_STEP();
        rs[0] = _raw(1 + step + 1, 100e18, T0);
        sigs = _sign(feedA, rs, 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICredenceErrors.SeqStepTooLarge.selector, NVDA, uint64(1 + step + 1), uint64(1)
            )
        );
        feedA.submit(rs, sigs);
        _submit(feedA, _raw(1 + step, 100e18, T0));
    }

    /// E-O-05: an outlier print (one vendor × 10) is severe disagreement, not a price: the valuation does not jump to
    ///         it while the other vendor is sane.
    function test_E_O05_outlierIsFlaggedNotUsed() public {
        _both(100e18, 100e18);
        uint256 before = ad.valuationPrice(NVDA);
        _live(feedB, NVDA, 1_000e18, FeedMarketStatus.REGULAR);
        assertTrue(_h().severeDisagreement);
        assertEq(ad.valuationPrice(NVDA), before, "the primary's price stands");
    }
}
