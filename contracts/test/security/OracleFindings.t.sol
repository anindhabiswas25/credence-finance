// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClockFixture} from "../utils/ClockFixture.sol";
import {Report, ReportKind, FeedMarketStatus} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {CredencePriceFeed} from "../../src/oracle/CredencePriceFeed.sol";

/// @title Price-feed findings (QA-sec S4; triage QA-08, offchain-review OFF-01).
/// @notice The relayer's nodes check a proposed report's price, status and session against their own view, but not its
///         `seq`, which the aggregator assigns; the feed accepts any `seq` above the stored one. One signed report with
///         `seq = type(uint64).max` therefore ends the asset's feed for good: every later report is `StaleReport`, the
///         feed goes stale, and the clock fails closed (CLOSED / HALTED) until the timelock swaps the price source.
contract OracleFindingsTest is ClockFixture {
    CredencePriceFeed internal feed;
    bytes32 internal constant A = keccak256("NVDA:XNAS");

    function setUp() public {
        _makeCommittee();
        feed = new CredencePriceFeed(timelock, signers, 2);
        vm.warp(1_800_000_000);
    }

    function _one(Report memory r) internal pure returns (Report[] memory rs) {
        rs = new Report[](1);
        rs[0] = r;
    }

    function _live(uint256 price, uint64 seq) internal returns (Report[] memory rs) {
        Report memory r = _report(
            feed, A, ReportKind.LIVE, price, uint40(vm.getBlockTimestamp()), 0, FeedMarketStatus.REGULAR
        );
        r.seq = seq;
        rs = _one(r);
    }

    /// @notice Regression of QA-08 (Medium, fixed 61761b9 + BE-backend OFF-01). A report must not be able to jump `seq` so far
    ///         that the feed can never advance again: bound the step on-chain (e.g. seq ≤ stored + 2^32) and have
    ///         every node refuse a seq outside [chain seq + 1, chain seq + window].
    function test_QA08_aSeqJumpCannotEndTheFeed() public {
        Report[] memory rs = _live(100e18, type(uint64).max);
        bytes[] memory sigs = _sign(feed, rs, 2);
        try feed.submit(rs, sigs) {} catch {}
        vm.warp(vm.getBlockTimestamp() + 1);
        Report[] memory next = _live(101e18, 2);
        feed.submit(next, _sign(feed, next, 2));
        (uint256 p,,) = feed.latest(A);
        assertEq(p, 101e18, "the feed still advances");
    }
}
