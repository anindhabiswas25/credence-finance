// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClockFixture} from "../utils/ClockFixture.sol";
import {
    ClockState,
    ClockData,
    ClosureType,
    MarketKind,
    FeedHealth,
    OracleConfig,
    ReportKind,
    FeedMarketStatus
} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {CredencePriceFeed} from "../../src/oracle/CredencePriceFeed.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {MockAssetClock} from "../mocks/MockAssetClock.sol";
import {MockProbeToken} from "../mocks/MockProbeToken.sol";
import {MockTwapSource} from "../mocks/MockTwapSource.sol";
import {CalendarStore} from "../../src/clock/CalendarStore.sol";
import {Session} from "../../src/libraries/Types.sol";

contract OracleAdapterTest is ClockFixture {
    OracleAdapter ad;
    MockAssetClock mc;
    MockProbeToken probe;
    CredencePriceFeed navFeed;
    bytes32 constant TBILL = keccak256("TBILL:USBANK");
    uint40 T0 = 1_800_000_000;

    function setUp() public {
        vm.warp(T0);
        _makeCommittee();
        feedA = new CredencePriceFeed(timelock, signers, 2);
        feedB = new CredencePriceFeed(timelock, signers, 2);
        navFeed = new CredencePriceFeed(timelock, signers, 2);
        dex = new MockTwapSource();
        probe = new MockProbeToken();
        mc = new MockAssetClock();
        ad = new OracleAdapter(timelock);
        ad.setClock(address(mc));
        oracle = ad; // fixture helpers
        vm.startPrank(timelock);
        ad.setAssetConfig(
            NVDA, address(feedA), address(feedB), address(dex), address(probe), MarketKind.EQUITY, 250_000e18
        );
        ad.setAssetConfig(TBILL, address(navFeed), address(0), address(0), address(probe), MarketKind.NAV, 0);
        vm.stopPrank();
    }

    function _both(uint256 p1, uint256 p2, uint8 st) internal {
        _live(feedA, NVDA, p1, st);
        _live(feedB, NVDA, p2, st);
    }

    function _setClock(
        ClockState s,
        ClockState cal,
        uint128 ref,
        uint128 openP,
        ClosureType t,
        uint40 closeAt
    ) internal {
        mc.set(s, cal);
        ClockData memory d;
        d.state = s;
        d.refPrice = ref;
        d.openPrint = openP;
        d.closureType = t;
        d.closeAt = closeAt;
        mc.setData(d);
    }

    function _nav(uint256 nav, uint40 at) internal {
        _submit(navFeed, _report(navFeed, TBILL, ReportKind.NAV, nav, at, 0, FeedMarketStatus.CLOSED));
    }

    // ───────────── wiring / governance ─────────────

    function test_wiring() public {
        OracleAdapter fresh = new OracleAdapter(timelock);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new OracleAdapter(address(0));
        vm.prank(makeAddr("x"));
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        fresh.setClock(address(mc));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        fresh.setClock(address(0));
        fresh.setClock(address(mc));
        vm.expectRevert(ICredenceErrors.AlreadyWired.selector);
        fresh.setClock(address(mc));
        assertEq(fresh.clock(), address(mc));
        assertEq(fresh.timelock(), timelock);
    }

    function test_setAssetConfig() public {
        bytes32 X = keccak256("X:XNAS");
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        ad.setAssetConfig(X, address(feedA), address(feedB), address(0), address(probe), MarketKind.EQUITY, 0);
        vm.startPrank(timelock);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        ad.setAssetConfig(X, address(0), address(feedB), address(0), address(probe), MarketKind.EQUITY, 0);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        ad.setAssetConfig(X, address(feedA), address(feedB), address(0), address(0), MarketKind.EQUITY, 0);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector); // equity needs a secondary
        ad.setAssetConfig(X, address(feedA), address(0), address(0), address(probe), MarketKind.EQUITY, 0);
        probe.set(0, false, false);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        ad.setAssetConfig(X, address(feedA), address(feedB), address(0), address(probe), MarketKind.EQUITY, 0);
        probe.set(2e18, false, false);
        ad.setAssetConfig(X, address(feedA), address(feedB), address(0), address(probe), MarketKind.EQUITY, 0);
        assertEq(ad.sharesPerToken(X), 2e18);
        // re-pointing sources keeps the cached ratio, even if the token's changed
        probe.set(5e18, false, false);
        ad.setAssetConfig(
            X, address(feedB), address(feedA), address(dex), address(probe), MarketKind.EQUITY, 1
        );
        OracleConfig memory c = ad.config(X);
        assertEq(c.primary, address(feedB));
        assertEq(c.sharesPerToken, 2e18);
        assertEq(c.minDepth, 1);
        // kind or token cannot change
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        ad.setAssetConfig(X, address(feedA), address(feedB), address(0), address(probe), MarketKind.NAV, 0);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        ad.setAssetConfig(X, address(feedA), address(feedB), address(0), address(dex), MarketKind.EQUITY, 0);
        vm.stopPrank();
    }

    function test_setSharesPerToken() public {
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        ad.setSharesPerToken(NVDA, 2e18);
        vm.startPrank(address(mc));
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.SharesPerTokenChangeTooLarge.selector, 1e18, 0)
        );
        ad.setSharesPerToken(NVDA, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.SharesPerTokenChangeTooLarge.selector, 1e18, 11e18)
        );
        ad.setSharesPerToken(NVDA, 11e18);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.SharesPerTokenChangeTooLarge.selector, 1e18, 0.09e18)
        );
        ad.setSharesPerToken(NVDA, 0.09e18);
        ad.setSharesPerToken(NVDA, 10e18);
        assertEq(ad.sharesPerToken(NVDA), 10e18);
        ad.setSharesPerToken(NVDA, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NoPrice.selector, bytes32("nope")));
        ad.setSharesPerToken(bytes32("nope"), 1e18);
        vm.stopPrank();
    }

    function test_unlisted() public {
        bytes32 Z = bytes32("nope");
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NoPrice.selector, Z));
        ad.valuationPrice(Z);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NoPrice.selector, Z));
        ad.livePrice(Z);
        assertFalse(ad.config(Z).listed);
    }

    // ───────────── valuation by state (F-3.2) ─────────────

    function test_valuationRegular() public {
        _setClock(ClockState.REGULAR, ClockState.REGULAR, 0, 0, ClosureType.NONE, 0);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NoPrice.selector, NVDA));
        ad.valuationPrice(NVDA);
        _both(100e18, 101e18, 2); // 1% apart: primary
        assertEq(ad.valuationPrice(NVDA), 100e18);
        _both(100e18, 98e18, 2); // 2% apart: the lower one
        assertEq(ad.livePrice(NVDA), 98e18);
        _both(100e18, 110e18, 2);
        assertEq(ad.livePrice(NVDA), 100e18);
        // sharesPerToken is applied
        vm.prank(address(mc));
        ad.setSharesPerToken(NVDA, 2e18);
        assertEq(ad.livePrice(NVDA), 200e18);
    }

    function test_livePriceWithoutSecondary() public {
        _live(feedA, NVDA, 100e18, 2);
        assertEq(ad.livePrice(NVDA), 100e18);
    }

    function test_valuationExtended() public {
        _setClock(ClockState.EXTENDED, ClockState.EXTENDED, 0, 0, ClosureType.OVERNIGHT, T0);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NoReferencePrice.selector, NVDA));
        ad.valuationPrice(NVDA);
        _setClock(ClockState.EXTENDED, ClockState.EXTENDED, 180e18, 0, ClosureType.OVERNIGHT, T0);
        assertEq(ad.valuationPrice(NVDA), 180e18); // no prints at all → ref
        _live(feedA, NVDA, 170e18, FeedMarketStatus.POST);
        assertEq(ad.valuationPrice(NVDA), 170e18); // no 30-min TWAP yet → min(ref, latest)
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        _live(feedA, NVDA, 190e18, FeedMarketStatus.POST);
        // TWAP over 30 min is ~170 (the 190 print is 0 s old)
        assertEq(ad.valuationPrice(NVDA), 170e18);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        assertEq(ad.valuationPrice(NVDA), 180e18, "a TWAP above the close never raises V");
    }

    function test_valuationClosedHaltedCorp() public {
        _setClock(ClockState.CLOSED, ClockState.CLOSED, 180e18, 0, ClosureType.WEEKEND, T0);
        assertEq(ad.valuationPrice(NVDA), 180e18);
        dex.set(170e18, true, 300_000e18);
        assertEq(ad.valuationPrice(NVDA), 170e18);
        dex.set(170e18, true, 100_000e18); // shallow: ignored
        assertEq(ad.valuationPrice(NVDA), 180e18);
        dex.set(190e18, true, 300_000e18);
        assertEq(ad.valuationPrice(NVDA), 180e18);
        _setClock(ClockState.HALTED, ClockState.REGULAR, 180e18, 0, ClosureType.HALT, T0);
        dex.set(150e18, true, 300_000e18);
        assertEq(ad.valuationPrice(NVDA), 150e18);
        _setClock(ClockState.CORP_ACTION, ClockState.REGULAR, 180e18, 0, ClosureType.CORP_ACTION, T0);
        assertEq(ad.valuationPrice(NVDA), 180e18);
    }

    function test_valuationReopen() public {
        _setClock(ClockState.REOPEN, ClockState.REGULAR, 180e18, 0, ClosureType.WEEKEND, T0);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NoPrice.selector, NVDA));
        ad.valuationPrice(NVDA);
        _setClock(ClockState.REOPEN, ClockState.REGULAR, 180e18, 175e18, ClosureType.WEEKEND, T0);
        assertEq(ad.valuationPrice(NVDA), 175e18);
    }

    function test_navValuation() public {
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NoPrice.selector, TBILL));
        ad.valuationPrice(TBILL);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NoPrice.selector, TBILL));
        ad.livePrice(TBILL);
        _nav(1.02e18, T0);
        assertEq(ad.valuationPrice(TBILL), 1.02e18);
        assertEq(ad.livePrice(TBILL), 1.02e18);
        (uint256 p, uint40 t) = ad.lastRegularClose(TBILL);
        assertEq(p, 1.02e18);
        assertEq(t, T0);
        (p, t) = ad.haltReferencePrice(TBILL);
        assertEq(p, 1.02e18);
        assertFalse(ad.stressFlag(TBILL));
    }

    // ───────────── references ─────────────

    function test_lastRegularClose() public {
        uint40 open = T0 - 6 hours;
        _live(feedA, NVDA, 181e18, FeedMarketStatus.REGULAR);
        (uint256 p, uint40 t) = ad.lastRegularClose(NVDA);
        assertEq(p, 181e18); // no official close yet
        assertEq(t, T0);
        _closePrint(feedA, NVDA, 182e18, open, T0);
        (p, t) = ad.lastRegularClose(NVDA);
        assertEq(p, 182e18); // official close at the same second wins
        vm.warp(T0 + 1 days);
        _live(feedA, NVDA, 190e18, FeedMarketStatus.REGULAR);
        (p,) = ad.lastRegularClose(NVDA);
        assertEq(p, 190e18); // a newer regular print than the stored close
    }

    function test_haltReference() public {
        _live(feedA, NVDA, 181e18, FeedMarketStatus.REGULAR);
        vm.warp(T0 + 60);
        _live(feedA, NVDA, 150e18, FeedMarketStatus.HALTED);
        _live(feedB, NVDA, 160e18, FeedMarketStatus.REGULAR);
        (uint256 p, uint40 t) = ad.haltReferencePrice(NVDA);
        assertEq(p, 150e18);
        assertEq(t, T0 + 60);
        _live(feedB, NVDA, 140e18, FeedMarketStatus.REGULAR);
        (p,) = ad.haltReferencePrice(NVDA);
        assertEq(p, 140e18);
    }

    // ───────────── open print (§8.3.2) ─────────────

    function test_openPrintScheduled() public {
        uint40 reopenAt = T0;
        _setClock(ClockState.CLOSED, ClockState.REGULAR, 180e18, 0, ClosureType.WEEKEND, T0 - 3 days);
        (bool ok,,) = ad.openPrint(NVDA, reopenAt, 0);
        assertFalse(ok);
        _openPrint(feedA, NVDA, 175e18, reopenAt);
        (ok,,) = ad.openPrint(NVDA, reopenAt, 0);
        assertFalse(ok, "secondary missing: wait");
        _openPrint(feedB, NVDA, 180e18, reopenAt); // 2.9% apart: wait
        (ok,,) = ad.openPrint(NVDA, reopenAt, 0);
        assertFalse(ok);
        _openPrint(feedB, NVDA, 176e18, reopenAt);
        (bool ok2, uint256 p, bool fb) = ad.openPrint(NVDA, reopenAt, 0);
        assertTrue(ok2);
        assertEq(p, 175e18);
        assertFalse(fb);
    }

    function test_openPrintFallback() public {
        uint40 reopenAt = T0;
        _setClock(ClockState.CLOSED, ClockState.REGULAR, 180e18, 0, ClosureType.WEEKEND, T0 - 3 days);
        _both(170e18, 171e18, 2);
        vm.warp(reopenAt + 10 minutes);
        _both(172e18, 172e18, 2);
        vm.warp(reopenAt + 15 minutes - 1);
        (bool ok,,) = ad.openPrint(NVDA, reopenAt, 0);
        assertFalse(ok, "wait 15 min");
        vm.warp(reopenAt + 15 minutes);
        (bool ok2, uint256 p, bool fb) = ad.openPrint(NVDA, reopenAt, 0);
        assertTrue(ok2);
        assertTrue(fb);
        assertEq(p, 172e18);
        (ok,,) = ad.openPrint(NVDA, reopenAt, 5 minutes); // the phase extension delays the fallback
        assertFalse(ok);
        _both(172e18, 190e18, 2); // TWAPs disagree
        vm.warp(reopenAt + 21 minutes);
        (ok,,) = ad.openPrint(NVDA, reopenAt, 0);
        assertFalse(ok);
    }

    function test_openPrintAfterHalt() public {
        _setClock(ClockState.HALTED, ClockState.REGULAR, 180e18, 0, ClosureType.HALT, T0);
        (bool ok,,) = ad.openPrint(NVDA, 0, 0);
        assertFalse(ok);
        vm.warp(T0 + 10);
        _both(150e18, 151e18, FeedMarketStatus.REGULAR);
        (bool ok2, uint256 p,) = ad.openPrint(NVDA, 0, 0);
        assertTrue(ok2);
        assertEq(p, 150e18);
        _both(150e18, 160e18, FeedMarketStatus.REGULAR); // disagree
        (ok,,) = ad.openPrint(NVDA, 0, 0);
        assertFalse(ok);
        _both(150e18, 150e18, FeedMarketStatus.POST); // not a regular-session print
        (ok,,) = ad.openPrint(NVDA, 0, 0);
        assertFalse(ok);
        vm.warp(T0 + 200);
        (ok,,) = ad.openPrint(NVDA, 0, 0); // stale
        assertFalse(ok);
        _setClock(ClockState.CORP_ACTION, ClockState.REGULAR, 180e18, 0, ClosureType.CORP_ACTION, T0);
        _both(150e18, 150e18, FeedMarketStatus.REGULAR);
        (ok2, p,) = ad.openPrint(NVDA, 0, 0);
        assertTrue(ok2);
        // prints from before the closure started do not count
        _setClock(
            ClockState.HALTED,
            ClockState.REGULAR,
            180e18,
            0,
            ClosureType.HALT,
            uint40(vm.getBlockTimestamp()) + 1
        );
        (ok,,) = ad.openPrint(NVDA, 0, 0);
        assertFalse(ok);
    }

    function test_openPrintNav() public {
        _usbank();
        Session memory fri = sessions[1]; // Fri 2026-10-02
        Session memory mon = sessions[2]; // Mon 2026-10-05
        vm.warp(fri.close + 1 hours);
        _setClock(ClockState.CLOSED, ClockState.CLOSED, 1e18, 0, ClosureType.WEEKEND, fri.close);
        (bool ok,,) = ad.openPrint(TBILL, 0, 0);
        assertFalse(ok, "no NAV");
        _nav(1e18, fri.close - 1);
        (ok,,) = ad.openPrint(TBILL, 0, 0);
        assertFalse(ok, "NAV from before the closure");
        _nav(1.001e18, fri.close + 30 minutes);
        vm.warp(mon.open + 1 hours); // Monday morning, ~64 h after the NAV: still fresh (R-23)
        (bool ok2, uint256 p,) = ad.openPrint(TBILL, 0, 0);
        assertTrue(ok2);
        assertEq(p, 1.001e18);
        vm.warp(mon.close + 6 hours + 1); // Monday's strike missed
        (ok,,) = ad.openPrint(TBILL, 0, 0);
        assertFalse(ok, "stale: a strike was missed");
        _nav(0.99e18, uint40(vm.getBlockTimestamp())); // −1.1% in one step
        (ok,,) = ad.openPrint(TBILL, 0, 0);
        assertFalse(ok, "invalid drop");
    }

    // ───────────── feed health ─────────────

    function test_feedHealthEquity() public {
        // calendar CLOSED: only halts / freezes count
        _setClock(ClockState.CLOSED, ClockState.CLOSED, 0, 0, ClosureType.NONE, 0);
        FeedHealth memory h = ad.feedHealth(NVDA);
        assertFalse(h.stale || h.disagreement || h.statusClosed || h.statusHalted || h.issuerFrozen);

        _setClock(ClockState.REGULAR, ClockState.REGULAR, 0, 0, ClosureType.NONE, 0);
        h = ad.feedHealth(NVDA);
        assertTrue(h.stale, "no print in REGULAR");
        assertTrue(h.disagreement);
        _both(100e18, 101e18, 2);
        h = ad.feedHealth(NVDA);
        assertFalse(h.stale || h.disagreement || h.severeDisagreement);
        _both(100e18, 102e18, 2);
        h = ad.feedHealth(NVDA);
        assertTrue(h.disagreement);
        assertFalse(h.severeDisagreement);
        _both(100e18, 106e18, 2);
        assertTrue(ad.feedHealth(NVDA).severeDisagreement);
        vm.warp(vm.getBlockTimestamp() + 61);
        h = ad.feedHealth(NVDA);
        assertTrue(h.stale, "60 s in REGULAR");
        _setClock(ClockState.EXTENDED, ClockState.EXTENDED, 0, 0, ClosureType.NONE, 0);
        assertFalse(ad.feedHealth(NVDA).stale, "300 s in EXTENDED");
        vm.warp(vm.getBlockTimestamp() + 240);
        assertTrue(ad.feedHealth(NVDA).stale);

        _setClock(ClockState.REGULAR, ClockState.REGULAR, 0, 0, ClosureType.NONE, 0);
        _live(feedA, NVDA, 100e18, FeedMarketStatus.CLOSED);
        assertTrue(ad.feedHealth(NVDA).statusClosed);
        _status(feedB, NVDA, FeedMarketStatus.HALTED);
        assertTrue(ad.feedHealth(NVDA).statusHalted);
        probe.set(1e18, true, false);
        assertTrue(ad.feedHealth(NVDA).issuerFrozen);
        probe.setReverts(true, false);
        assertTrue(ad.feedHealth(NVDA).issuerFrozen, "a failing probe fails closed");
    }

    // ───────────── R-23: NAV freshness in USBANK strikes (fixture: 2026-10-01 → 11-25) ─────────────

    function _usbank() internal {
        _loadCalendarFixture("test/fixtures/USBANK-20261001-fixture.json");
        CalendarStore cal = new CalendarStore(timelock);
        vm.prank(timelock);
        cal.appendSessions(USBANK, sessions);
        mc.setCalendar(address(cal), USBANK);
    }

    function _navHealth() internal view returns (bool stale, bool invalid) {
        FeedHealth memory h = ad.feedHealth(TBILL);
        return (h.stale, h.navInvalid);
    }

    function test_navNormalWeekend() public {
        _usbank();
        Session memory fri = sessions[1]; // Fri 2026-10-02, strike 17:00 ET
        Session memory mon = sessions[2]; // Mon 2026-10-05
        vm.warp(fri.close + 20 minutes);
        _nav(1e18, fri.close + 15 minutes);
        (bool stale, bool invalid) = _navHealth();
        assertFalse(stale || invalid, "Friday NAV");
        vm.warp(mon.open + 4 hours); // Monday 13:00 ET: ~68 h old, older than the old 50 h rule
        (stale, invalid) = _navHealth();
        assertFalse(stale || invalid, "a weekend never makes a NAV stale");
        vm.warp(mon.close + 6 hours); // Monday's strike is in its grace period
        (stale, invalid) = _navHealth();
        assertFalse(stale || invalid, "grace");
        vm.warp(mon.close + 6 hours + 1);
        (stale, invalid) = _navHealth();
        assertTrue(stale, "Monday's strike missed");
        assertFalse(invalid);
        _nav(1.0001e18, uint40(vm.getBlockTimestamp()));
        (stale, invalid) = _navHealth();
        assertFalse(stale || invalid, "late Monday NAV");
    }

    function test_navHolidayWeekend() public {
        _usbank();
        Session memory fri = sessions[6]; // Fri 2026-10-09
        Session memory tue = sessions[7]; // Tue 2026-10-13 (Mon 10-12 is a bank holiday)
        assertEq(tue.open - fri.close, 3 days + 16 hours, "3-day weekend in the fixture");
        vm.warp(fri.close + 1 hours);
        _nav(1e18, fri.close + 30 minutes);
        vm.warp(fri.close + 3 days + 2 hours); // Monday 19:00 ET (holiday): the old rule would have halted
        (bool stale, bool invalid) = _navHealth();
        assertFalse(stale || invalid, "holiday Monday");
        vm.warp(tue.open + 1 hours); // ~89 h old
        (stale, invalid) = _navHealth();
        assertFalse(stale || invalid, "Tuesday morning");
        vm.warp(tue.close + 6 hours + 1);
        (stale, invalid) = _navHealth();
        assertTrue(stale && !invalid, "Tuesday's strike missed");
    }

    function test_navMissedSingleStrike() public {
        _usbank();
        Session memory thu = sessions[0]; // Thu 2026-10-01
        Session memory fri = sessions[1];
        Session memory mon = sessions[2];
        vm.warp(thu.close + 1 hours);
        _nav(1e18, thu.close + 30 minutes);
        vm.warp(fri.close + 6 hours + 1);
        (bool stale, bool invalid) = _navHealth();
        assertTrue(stale, "Friday's strike missed -> stale (clock: CLOSED)");
        assertFalse(invalid);
        vm.warp(mon.close + 6 hours); // through the weekend, Monday in grace: still one miss
        (stale, invalid) = _navHealth();
        assertTrue(stale && !invalid, "one miss");
    }

    function test_navMissedDoubleStrike() public {
        _usbank();
        Session memory thu = sessions[0];
        Session memory mon = sessions[2];
        vm.warp(thu.close + 1 hours);
        _nav(1e18, thu.close + 30 minutes);
        vm.warp(mon.close + 6 hours + 1); // Friday and Monday strikes missed
        (bool stale, bool invalid) = _navHealth();
        assertTrue(stale && invalid, "two misses -> invalid (clock: HALTED)");
        _nav(1.0001e18, uint40(vm.getBlockTimestamp()));
        (stale, invalid) = _navHealth();
        assertFalse(stale || invalid, "a new NAV clears it");
    }

    function test_feedHealthNav() public {
        _usbank();
        vm.warp(sessions[3].close + 1 hours);
        FeedHealth memory h = ad.feedHealth(TBILL);
        assertTrue(h.navInvalid && h.stale, "no NAV");
        _nav(1e18, uint40(vm.getBlockTimestamp()));
        h = ad.feedHealth(TBILL);
        assertFalse(h.navInvalid || h.stale || h.issuerFrozen);
        vm.warp(vm.getBlockTimestamp() + 1);
        _nav(0.996e18, uint40(vm.getBlockTimestamp())); // −0.4%: fine
        assertFalse(ad.feedHealth(TBILL).navInvalid);
        vm.warp(vm.getBlockTimestamp() + 1);
        _nav(0.99e18, uint40(vm.getBlockTimestamp())); // −0.6%
        assertTrue(ad.feedHealth(TBILL).navInvalid);
        probe.set(1e18, false, true);
        assertTrue(ad.feedHealth(TBILL).issuerFrozen, "redemptions gated");
        probe.set(1e18, true, false);
        assertTrue(ad.feedHealth(TBILL).issuerFrozen, "frozen");
        probe.set(1e18, false, false);
        probe.setReverts(false, true);
        assertTrue(ad.feedHealth(TBILL).issuerFrozen, "failing probe");
    }

    // ───────────── DEX, stress ─────────────

    function test_dexAndStress() public {
        (uint256 p, bool usable) = ad.dexTwap(NVDA);
        assertFalse(usable);
        assertEq(p, 0);
        dex.set(170e18, false, 1e30);
        (, usable) = ad.dexTwap(NVDA);
        assertFalse(usable, "twap not ok");
        dex.set(170e18, true, 1e30);
        (p, usable) = ad.dexTwap(NVDA);
        assertTrue(usable);
        assertEq(p, 170e18);
        dex.setReverts(true, false);
        (, usable) = ad.dexTwap(NVDA);
        assertFalse(usable);
        dex.setReverts(false, true);
        (, usable) = ad.dexTwap(NVDA);
        assertFalse(usable);
        dex.setReverts(false, false);

        _setClock(ClockState.REGULAR, ClockState.REGULAR, 200e18, 0, ClosureType.NONE, 0);
        assertFalse(ad.stressFlag(NVDA), "not closed");
        _setClock(ClockState.CLOSED, ClockState.CLOSED, 200e18, 0, ClosureType.WEEKEND, 0);
        assertTrue(ad.stressFlag(NVDA), "170 < 90% of 200");
        dex.set(181e18, true, 1e30);
        assertFalse(ad.stressFlag(NVDA));
        dex.set(100e18, true, 1); // shallow
        assertFalse(ad.stressFlag(NVDA));
        _setClock(ClockState.HALTED, ClockState.REGULAR, 0, 0, ClosureType.HALT, 0);
        dex.set(1e18, true, 1e30);
        assertFalse(ad.stressFlag(NVDA), "no reference");
    }

    // ───────────── INV-ORA-01 (unit fuzz) ─────────────

    /// @dev Whatever the feeds and the DEX print, off-hours valuation never exceeds the reference close.
    function testFuzz_offHoursNeverAboveRef(
        uint8 s,
        uint128 ref,
        uint128 live,
        uint128 twapPx,
        bool deep,
        uint16 ageMin
    ) public {
        ClockState st = [ClockState.EXTENDED, ClockState.CLOSED, ClockState.HALTED][s % 3];
        ref = uint128(bound(ref, 1, 1e30));
        _setClock(st, st == ClockState.HALTED ? ClockState.REGULAR : st, ref, 0, ClosureType.WEEKEND, T0);
        _live(feedA, NVDA, bound(live, 1, 1e30), FeedMarketStatus.POST);
        vm.warp(vm.getBlockTimestamp() + bound(ageMin, 0, 120) * 1 minutes);
        dex.set(bound(twapPx, 1, 1e30), true, deep ? 1e30 : 0);
        assertLe(ad.valuationPrice(NVDA), ref);
    }
}
