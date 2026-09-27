// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClockFixture} from "../utils/ClockFixture.sol";
import {Report, ReportKind, FeedMarketStatus} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {IPriceFeedEvents} from "../../src/libraries/Events.sol";
import {CredencePriceFeed} from "../../src/oracle/CredencePriceFeed.sol";

contract CredencePriceFeedTest is ClockFixture, IPriceFeedEvents {
    CredencePriceFeed feed;
    bytes32 constant A = keccak256("NVDA:XNAS");
    bytes32 constant B = keccak256("AAPL:XNAS");

    function setUp() public {
        _makeCommittee();
        feed = new CredencePriceFeed(timelock, signers, 2);
        vm.warp(1_800_000_000);
    }

    function _one(Report memory r) internal pure returns (Report[] memory rs) {
        rs = new Report[](1);
        rs[0] = r;
    }

    function _live(uint256 price, uint40 at) internal returns (Report memory) {
        return _report(feed, A, ReportKind.LIVE, price, at, 0, FeedMarketStatus.REGULAR);
    }

    // ───────────── committee ─────────────

    function test_constructorAndCommittee() public {
        (address[] memory s, uint8 t) = feed.committee();
        assertEq(s.length, 3);
        assertEq(t, 2);
        assertTrue(feed.isSigner(signers[0]));
        assertEq(feed.timelock(), timelock);
        assertEq(feed.RING_SIZE(), 96);
        assertEq(feed.MAX_FUTURE_SKEW(), 5);
        assertEq(feed.REPORTS_TYPEHASH(), keccak256("Reports(bytes32 reportsHash)"));

        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new CredencePriceFeed(address(0), signers, 2);
        vm.expectRevert(ICredenceErrors.InvalidCommittee.selector);
        new CredencePriceFeed(timelock, signers, 0);
        vm.expectRevert(ICredenceErrors.InvalidCommittee.selector);
        new CredencePriceFeed(timelock, signers, 4);
        vm.expectRevert(ICredenceErrors.InvalidCommittee.selector);
        new CredencePriceFeed(timelock, new address[](0), 1);
        address[] memory unsorted = new address[](2);
        unsorted[0] = signers[1];
        unsorted[1] = signers[0];
        vm.expectRevert(ICredenceErrors.InvalidCommittee.selector);
        new CredencePriceFeed(timelock, unsorted, 1);
        address[] memory zero = new address[](1);
        vm.expectRevert(ICredenceErrors.InvalidCommittee.selector);
        new CredencePriceFeed(timelock, zero, 1);
    }

    function test_setCommittee() public {
        address[] memory next = new address[](1);
        next[0] = signers[2];
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        feed.setCommittee(next, 1);
        vm.expectEmit(false, false, false, true);
        emit CommitteeChanged(next, 1);
        vm.prank(timelock);
        feed.setCommittee(next, 1);
        assertFalse(feed.isSigner(signers[0]));
        assertTrue(feed.isSigner(signers[2]));
        // the old members can no longer sign
        Report[] memory rs = _one(_live(100e18, uint40(vm.getBlockTimestamp())));
        bytes[] memory sigs = _sign(feed, rs, 1); // signerKeys[0] only
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownSigner.selector, signers[0]));
        feed.submit(rs, sigs);
    }

    // ───────────── signatures ─────────────

    function test_submit2of3and3of3() public {
        Report[] memory rs = _one(_live(100e18, uint40(vm.getBlockTimestamp())));
        vm.expectEmit(true, false, false, true);
        emit ReportAccepted(A, ReportKind.LIVE, 100e18, uint40(vm.getBlockTimestamp()), 1);
        feed.submit(rs, _sign(feed, rs, 2));
        rs = _one(_live(101e18, uint40(vm.getBlockTimestamp())));
        feed.submit(rs, _sign(feed, rs, 3));
        (uint256 p,,) = feed.latest(A);
        assertEq(p, 101e18);
        assertEq(feed.latestSeq(A), 2);
    }

    function test_rejects1of3() public {
        Report[] memory rs = _one(_live(100e18, uint40(vm.getBlockTimestamp())));
        bytes[] memory sigs = _sign(feed, rs, 1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NotEnoughSigners.selector, 1, 2));
        feed.submit(rs, sigs);
    }

    function test_rejectsUnsortedAndDuplicate() public {
        Report[] memory rs = _one(_live(100e18, uint40(vm.getBlockTimestamp())));
        bytes[] memory sigs = _sign(feed, rs, 2);
        bytes[] memory swapped = new bytes[](2);
        swapped[0] = sigs[1];
        swapped[1] = sigs[0];
        vm.expectRevert(ICredenceErrors.SignersNotSorted.selector);
        feed.submit(rs, swapped);
        bytes[] memory dup = new bytes[](2);
        dup[0] = sigs[0];
        dup[1] = sigs[0];
        vm.expectRevert(ICredenceErrors.SignersNotSorted.selector);
        feed.submit(rs, dup);
    }

    function test_rejectsWrongDomainAndGarbage() public {
        CredencePriceFeed other = new CredencePriceFeed(timelock, signers, 2);
        Report[] memory rs = _one(_live(100e18, uint40(vm.getBlockTimestamp())));
        assertTrue(other.hashReports(rs) != feed.hashReports(rs), "domain binds verifyingContract");
        bytes[] memory sigs = _sign(other, rs, 2); // signed for another feed
        vm.expectRevert(); // recovers unrelated addresses: UnknownSigner or SignersNotSorted
        feed.submit(rs, sigs);
        bytes[] memory junk = new bytes[](2);
        junk[0] = hex"01";
        junk[1] = hex"02";
        vm.expectRevert(ICredenceErrors.InvalidSignature.selector);
        feed.submit(rs, junk);
        // a non-member key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, feed.hashReports(rs));
        bytes[] memory outsider = new bytes[](1);
        outsider[0] = abi.encodePacked(r, s, v);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownSigner.selector, vm.addr(0xBAD)));
        feed.submit(rs, outsider);
    }

    function test_digestMatchesSpec() public view {
        Report[] memory rs = new Report[](2);
        rs[0] = Report(A, 0, 1e18, 10, 20, 2, 1);
        rs[1] = Report(B, 3, 2e18, 11, 21, 0, 7);
        bytes32 structHash =
            keccak256(abi.encode(keccak256("Reports(bytes32 reportsHash)"), keccak256(abi.encode(rs))));
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("CredencePriceFeed"),
                keccak256("1"),
                block.chainid,
                address(feed)
            )
        );
        assertEq(feed.domainSeparator(), domain);
        assertEq(feed.hashReports(rs), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    // ───────────── validity rules ─────────────

    function _submitExpect(Report memory r, bytes memory err) internal {
        Report[] memory rs = _one(r);
        bytes[] memory sigs = _sign(feed, rs, 2);
        vm.expectRevert(err);
        feed.submit(rs, sigs);
    }

    function test_validityRules() public {
        uint40 t = uint40(vm.getBlockTimestamp());
        Report[] memory empty = new Report[](0);
        vm.expectRevert(ICredenceErrors.EmptyReports.selector);
        feed.submit(empty, new bytes[](0));

        _submitExpect(
            Report(A, 5, 1e18, t, 0, 2, 1),
            abi.encodeWithSelector(ICredenceErrors.InvalidReportKind.selector, 5)
        );
        _submitExpect(
            Report(A, 0, 1e18, t, 0, 6, 1),
            abi.encodeWithSelector(ICredenceErrors.InvalidMarketStatus.selector, 6)
        );
        _submitExpect(
            Report(A, 0, 1e18, t + 6, 0, 2, 1),
            abi.encodeWithSelector(ICredenceErrors.ReportFromFuture.selector, t + 6, vm.getBlockTimestamp())
        );
        _submitExpect(Report(A, 0, 0, t, 0, 2, 1), abi.encodeWithSelector(ICredenceErrors.ZeroPrice.selector));

        // 5 s skew allowed
        Report[] memory ok = _one(Report(A, 0, 1e18, t + 5, 0, 2, 3));
        feed.submit(ok, _sign(feed, ok, 2));
        // replay / older seq
        _submitExpect(
            Report(A, 0, 1e18, t + 5, 0, 2, 3),
            abi.encodeWithSelector(ICredenceErrors.StaleReport.selector, A, 3, 3)
        );
        _submitExpect(
            Report(A, 0, 1e18, t + 5, 0, 2, 2),
            abi.encodeWithSelector(ICredenceErrors.StaleReport.selector, A, 2, 3)
        );
        // one bad report reverts the whole batch
        Report[] memory batch = new Report[](2);
        batch[0] = Report(B, 0, 5e18, t, 0, 2, 1);
        batch[1] = Report(A, 0, 1e18, t, 0, 2, 1); // stale
        bytes[] memory sigs = _sign(feed, batch, 2);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.StaleReport.selector, A, 1, 3));
        feed.submit(batch, sigs);
        (uint256 pb,,) = feed.latest(B);
        assertEq(pb, 0);
    }

    function test_statusMayCarryZeroPrice() public {
        _submit(
            feed,
            _report(
                feed, A, ReportKind.LIVE, 100e18, uint40(vm.getBlockTimestamp()), 0, FeedMarketStatus.REGULAR
            )
        );
        _submit(
            feed,
            _report(feed, A, ReportKind.STATUS, 0, uint40(vm.getBlockTimestamp()), 0, FeedMarketStatus.HALTED)
        );
        (uint256 p,, uint8 st) = feed.latest(A);
        assertEq(p, 100e18); // STATUS does not touch the price
        assertEq(st, FeedMarketStatus.HALTED);
    }

    // ───────────── kinds ─────────────

    function test_liveOrderingAndRegular() public {
        uint40 t = uint40(vm.getBlockTimestamp());
        _submit(feed, _report(feed, A, ReportKind.LIVE, 100e18, t, 0, FeedMarketStatus.REGULAR));
        _submit(feed, _report(feed, A, ReportKind.LIVE, 101e18, t + 1, 0, FeedMarketStatus.POST));
        // out of order: seq advances, price ignored
        _submit(feed, _report(feed, A, ReportKind.LIVE, 50e18, t, 0, FeedMarketStatus.REGULAR));
        (uint256 p, uint40 at, uint8 st) = feed.latest(A);
        assertEq(p, 101e18);
        assertEq(at, t + 1);
        assertEq(st, FeedMarketStatus.POST);
        assertEq(feed.latestSeq(A), 3);
        (uint256 rp, uint40 rt) = feed.lastRegular(A);
        assertEq(rp, 100e18); // POST prints are not regular-session prints
        assertEq(rt, t);
        // same timestamp: later report replaces the ring entry
        _submit(feed, _report(feed, A, ReportKind.LIVE, 102e18, t + 1, 0, FeedMarketStatus.POST));
        assertEq(feed.observationCount(A), 2);
        (uint256 op,) = feed.observation(A, 0);
        assertEq(op, 102e18);
        (op,) = feed.observation(A, 5);
        assertEq(op, 0);
    }

    function test_openClose() public {
        uint40 open = uint40(vm.getBlockTimestamp()) - 1 hours;
        _submit(
            feed, _report(feed, A, ReportKind.OPEN, 99e18, open + 1, open / 1 days, FeedMarketStatus.REGULAR)
        );
        (uint256 p, uint40 at, bool ok) = feed.officialOpen(A, open);
        assertEq(p, 99e18);
        assertEq(at, open + 1);
        assertTrue(ok);
        // an open print more than 60 s before the scheduled open is not this session's
        (,, ok) = feed.officialOpen(A, open + 62);
        assertFalse(ok);
        (,, ok) = feed.officialOpen(A, open + 2 days);
        assertFalse(ok);

        vm.warp(open + 8 hours);
        _submit(feed, _report(feed, A, ReportKind.CLOSE, 98e18, open + 6 hours, 200, FeedMarketStatus.POST));
        _submit(feed, _report(feed, A, ReportKind.CLOSE, 97e18, open + 7 hours, 199, FeedMarketStatus.POST)); // older session
        (uint256 cp, uint40 ct, uint40 cs) = feed.officialClose(A);
        assertEq(cp, 98e18);
        assertEq(ct, open + 6 hours);
        assertEq(cs, 200);
    }

    function test_navHistory() public {
        uint40 t = uint40(vm.getBlockTimestamp());
        _submit(feed, _report(feed, A, ReportKind.NAV, 1e18, t - 100, 0, FeedMarketStatus.CLOSED));
        _submit(feed, _report(feed, A, ReportKind.NAV, 1.0001e18, t, 0, FeedMarketStatus.CLOSED));
        _submit(feed, _report(feed, A, ReportKind.NAV, 2e18, t - 50, 0, FeedMarketStatus.CLOSED)); // older: ignored
        (uint256 nav, uint40 at, uint256 prev, uint40 prevAt) = feed.latestNav(A);
        assertEq(nav, 1.0001e18);
        assertEq(at, t);
        assertEq(prev, 1e18);
        assertEq(prevAt, t - 100);
    }

    // ───────────── ring buffer + TWAP ─────────────

    function test_twapBasics() public {
        (uint256 p, bool ok) = feed.twap(A, 60);
        assertFalse(ok);
        assertEq(p, 0);
        uint40 t0 = uint40(vm.getBlockTimestamp());
        _submit(feed, _report(feed, A, ReportKind.LIVE, 100e18, t0, 0, FeedMarketStatus.REGULAR));
        vm.warp(t0 + 60);
        _submit(feed, _report(feed, A, ReportKind.LIVE, 200e18, t0 + 60, 0, FeedMarketStatus.REGULAR));
        vm.warp(t0 + 120);
        // [t0+60-? ...] 60 s window: 100% at 200
        (p, ok) = feed.twap(A, 60);
        assertTrue(ok);
        assertEq(p, 200e18);
        // 120 s window: half 100, half 200
        (p, ok) = feed.twap(A, 120);
        assertTrue(ok);
        assertEq(p, 150e18);
        // history does not reach back far enough
        (, ok) = feed.twap(A, 121);
        assertFalse(ok);
        // window 0 = latest
        (p, ok) = feed.twap(A, 0);
        assertEq(p, 200e18);
        assertTrue(ok);
        // window larger than the chain's age
        (, ok) = feed.twap(A, type(uint32).max);
        assertFalse(ok);
    }

    function test_twapFutureSkewClamped() public {
        uint40 t0 = uint40(vm.getBlockTimestamp());
        _submit(feed, _report(feed, A, ReportKind.LIVE, 100e18, t0 - 100, 0, FeedMarketStatus.REGULAR));
        _submit(feed, _report(feed, A, ReportKind.LIVE, 300e18, t0 + 5, 0, FeedMarketStatus.REGULAR));
        (uint256 p, bool ok) = feed.twap(A, 50);
        assertTrue(ok);
        assertEq(p, 100e18); // the future print holds for 0 s
    }

    function test_ringWraps() public {
        uint40 t0 = uint40(vm.getBlockTimestamp());
        for (uint256 i; i < 100; ++i) {
            vm.warp(t0 + i * 10);
            _submit(feed, _report(feed, A, ReportKind.LIVE, (i + 1) * 1e18, uint40(t0 + i * 10), 0, 2));
        }
        assertEq(feed.observationCount(A), 96);
        (uint256 p, uint40 at) = feed.observation(A, 0);
        assertEq(p, 100e18);
        assertEq(at, t0 + 990);
        (p,) = feed.observation(A, 95);
        assertEq(p, 5e18); // the 4 oldest were overwritten
        (, bool ok) = feed.twap(A, 950);
        assertTrue(ok);
        (, ok) = feed.twap(A, 951);
        assertFalse(ok);
    }

    /// @dev twap equals the time-weighted mean computed independently.
    function testFuzz_twapMatchesReference(uint16[8] memory gaps, uint64[8] memory prices, uint16 window)
        public
    {
        uint40 t = uint40(vm.getBlockTimestamp());
        uint256[8] memory ats;
        for (uint256 i; i < 8; ++i) {
            t += uint40(bound(gaps[i], 1, 600));
            ats[i] = t;
            vm.warp(t);
            _submit(feed, _report(feed, A, ReportKind.LIVE, bound(prices[i], 1, 1e30), t, 0, 2));
        }
        vm.warp(t + 30);
        uint256 w = bound(window, 1, vm.getBlockTimestamp() - ats[0]);
        (uint256 got, bool ok) = feed.twap(A, uint32(w));
        assertTrue(ok);
        uint256 start = vm.getBlockTimestamp() - w;
        uint256 acc;
        for (uint256 i; i < 8; ++i) {
            uint256 segStart = ats[i] > start ? ats[i] : start;
            uint256 segEnd = i == 7 ? vm.getBlockTimestamp() : ats[i + 1];
            if (segEnd > segStart) acc += bound(prices[i], 1, 1e30) * (segEnd - segStart);
        }
        assertEq(got, acc / w);
    }

    /// @dev seq is strictly increasing per asset; assets are independent.
    function testFuzz_seqMonotone(uint64 s1, uint64 s2) public {
        s1 = uint64(bound(s1, 1, type(uint64).max - 1));
        Report[] memory rs = _one(Report(A, 0, 1e18, uint40(vm.getBlockTimestamp()), 0, 2, s1));
        feed.submit(rs, _sign(feed, rs, 2));
        rs = _one(Report(A, 0, 1e18, uint40(vm.getBlockTimestamp()), 0, 2, s2));
        bytes[] memory sigs = _sign(feed, rs, 2);
        if (s2 <= s1) {
            vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.StaleReport.selector, A, s2, s1));
        }
        feed.submit(rs, sigs);
        // another asset starts from 0
        rs = _one(Report(B, 0, 1e18, uint40(vm.getBlockTimestamp()), 0, 2, 1));
        feed.submit(rs, _sign(feed, rs, 2));
        assertEq(feed.latestSeq(B), 1);
    }
}
