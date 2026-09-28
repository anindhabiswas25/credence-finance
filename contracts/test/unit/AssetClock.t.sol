// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClockFixture} from "../utils/ClockFixture.sol";
import {
    ClockState,
    ClockData,
    ClosureType,
    MarketKind,
    FeedHealth,
    Restriction,
    Session
} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {IAssetClockEvents} from "../../src/libraries/Events.sol";
import {CalendarStore} from "../../src/clock/CalendarStore.sol";
import {AssetClock} from "../../src/clock/AssetClock.sol";
import {SequencerHealth} from "../../src/oracle/SequencerHealth.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @dev AssetClock against a synthetic Mon–Fri calendar and a controllable oracle.
///      Day k of week w: extOpen 00:00, open 09:00, close 15:30, extClose 20:00 (UTC of the synthetic venue).
contract AssetClockTest is ClockFixture, IAssetClockEvents {
    MockOracle mo;
    uint40 constant T0 = 1_799_971_200; // 00:00 UTC; the synthetic week starts here whatever the weekday
    bytes32 constant FUND = keccak256("TBILL:USBANK");

    function setUp() public {
        vm.warp(T0 - 1 days);
        _syntheticSessions(T0, 3);
        calendar = new CalendarStore(timelock);
        vm.startPrank(timelock);
        calendar.appendSessions(XNYS, sessions);
        calendar.appendSessions(USBANK, sessions);
        vm.stopPrank();
        seqHealth = new SequencerHealth();
        clock = new AssetClock(timelock, guardian, address(calendar), address(seqHealth));
        seqHealth.setClock(address(clock));
        mo = new MockOracle();
        clock.initializeWiring(address(mo), auctionHouse, settlement);
    }

    // ───────────── helpers ─────────────

    function _day(uint256 w, uint256 d) internal view returns (Session memory) {
        return sessions[w * 5 + d];
    }

    function _healthy() internal {
        FeedHealth memory h;
        mo.setHealth(h);
    }

    function _listAt(uint256 t) internal {
        vm.warp(t);
        vm.prank(timelock);
        clock.listAsset(NVDA, XNYS, MarketKind.EQUITY);
    }

    function _pokeAt(uint256 t) internal returns (ClockState) {
        vm.warp(t);
        return clock.poke(NVDA);
    }

    /// @dev Listed Monday 10:00, then closed at Monday's close with a valid reference.
    function _mondayClosed() internal returns (Session memory mon) {
        mon = _day(0, 0);
        _healthy();
        _listAt(mon.open + 1 hours);
        assertEq(uint8(_pokeAt(mon.open + 1 hours)), uint8(ClockState.REGULAR));
        mo.setClose(180e18, mon.close);
        _pokeAt(mon.close + 10);
    }

    // ───────────── construction / wiring / governance ─────────────

    function test_constructorAndWiring() public {
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new AssetClock(address(0), guardian, address(calendar), address(seqHealth));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new AssetClock(timelock, address(0), address(calendar), address(seqHealth));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new AssetClock(timelock, guardian, address(0), address(seqHealth));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new AssetClock(timelock, guardian, address(calendar), address(0));

        AssetClock c2 = new AssetClock(timelock, guardian, address(calendar), address(seqHealth));
        vm.prank(makeAddr("x"));
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        c2.initializeWiring(address(mo), auctionHouse, settlement);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        c2.initializeWiring(address(0), auctionHouse, settlement);
        // not wired yet: poke fails closed
        vm.prank(timelock);
        c2.listAsset(NVDA, XNYS, MarketKind.EQUITY);
        vm.expectRevert(ICredenceErrors.NotWired.selector);
        c2.poke(NVDA);
        c2.initializeWiring(address(mo), address(0), address(0));
        vm.expectRevert(ICredenceErrors.AlreadyWired.selector);
        c2.initializeWiring(address(mo), auctionHouse, settlement);
        assertTrue(c2.wired());
        assertEq(c2.calendar(), address(calendar));
        assertEq(c2.sequencerHealth(), address(seqHealth));
        assertEq(c2.guardian(), guardian);
        assertEq(c2.timelock(), timelock);
        // with no auction house wired, nobody can complete a reopen
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        c2.markReopenComplete(NVDA, 1);
    }

    function test_setOracle() public {
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        clock.setOracle(address(1));
        vm.startPrank(timelock);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        clock.setOracle(address(0));
        vm.expectEmit(false, false, false, true);
        emit OracleSet(address(7));
        clock.setOracle(address(7));
        vm.stopPrank();
        assertEq(clock.oracle(), address(7));
    }

    function test_listAsset() public {
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        clock.listAsset(NVDA, XNYS, MarketKind.EQUITY);
        vm.startPrank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownVenue.selector, bytes32("NOPE")));
        clock.listAsset(NVDA, bytes32("NOPE"), MarketKind.EQUITY);
        vm.expectEmit(true, false, false, true);
        emit AssetListed(NVDA, XNYS, MarketKind.EQUITY);
        clock.listAsset(NVDA, XNYS, MarketKind.EQUITY);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.AssetAlreadyListed.selector, NVDA));
        clock.listAsset(NVDA, XNYS, MarketKind.EQUITY);
        vm.stopPrank();
        assertEq(uint8(clock.state(NVDA)), uint8(ClockState.CLOSED), "fail closed until poked");
        assertTrue(clock.assetConfig(NVDA).listed);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.AssetNotListed.selector, bytes32("X")));
        clock.state(bytes32("X"));
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.AssetNotListed.selector, bytes32("X")));
        clock.poke(bytes32("X"));
    }

    function test_listPostMarketAndPastCoverage() public {
        Session memory mon = _day(0, 0);
        _healthy();
        _listAt(mon.close + 1 hours); // post-market: today's close is not replayed
        assertEq(_info().closedSessions, 1);
        assertEq(uint8(clock.poke(NVDA)), uint8(ClockState.EXTENDED));
        assertEq(_info().closureId, 0);

        vm.warp(sessions[sessions.length - 1].extClose + 1 days);
        vm.prank(timelock);
        clock.listAsset(FUND, USBANK, MarketKind.NAV);
        ClockData memory d = clock.closureInfo(FUND);
        assertEq(d.closedSessions, sessions.length);
        assertEq(d.sessionCursor, sessions.length - 1);
    }

    // ───────────── calendar states ─────────────

    function test_calendarStates() public {
        Session memory mon = _day(0, 0);
        _healthy();
        _listAt(mon.extOpen - 1 hours);
        assertEq(uint8(clock.calendarState(NVDA)), uint8(ClockState.CLOSED), "before the calendar");
        vm.warp(mon.extOpen + 1);
        assertEq(uint8(clock.calendarState(NVDA)), uint8(ClockState.EXTENDED), "pre-market");
        vm.warp(mon.open);
        assertEq(uint8(clock.calendarState(NVDA)), uint8(ClockState.REGULAR));
        vm.warp(mon.close);
        assertEq(uint8(clock.calendarState(NVDA)), uint8(ClockState.EXTENDED), "post-market");
        vm.warp(mon.extClose);
        assertEq(uint8(clock.calendarState(NVDA)), uint8(ClockState.CLOSED), "20:00-24:00 gap");
        vm.warp(sessions[sessions.length - 1].close + 1);
        assertEq(uint8(clock.calendarState(NVDA)), uint8(ClockState.CLOSED), "past coverage");
        // every close is processed on this first poke; none has a reference → HALTED (fail closed)
        assertEq(uint8(clock.poke(NVDA)), uint8(ClockState.HALTED));
        mo.setClose(180e18, sessions[sessions.length - 1].close);
        assertEq(uint8(clock.poke(NVDA)), uint8(ClockState.CLOSED));
    }

    // ───────────── scheduled closures ─────────────

    /// @dev ADR-0109: a caller that starves the oracle read of gas must not force the fail-closed branch.
    function test_gasStarvedPokeRevertsInsteadOfHalting() public {
        Session memory mon = _day(0, 0);
        _healthy();
        _listAt(mon.open + 1 hours);
        assertEq(uint8(clock.poke(NVDA)), uint8(ClockState.REGULAR));
        mo.setBurn(400_000);
        vm.warp(mon.open + 2 hours);
        (bool ok, bytes memory ret) = address(clock).call{gas: 300_000}(abi.encodeCall(clock.poke, (NVDA)));
        assertFalse(ok, "starved poke must revert");
        assertEq(bytes4(ret), ICredenceErrors.InsufficientGas.selector);
        assertEq(uint8(clock.state(NVDA)), uint8(ClockState.REGULAR), "not halted");
        assertEq(uint8(clock.poke(NVDA)), uint8(ClockState.REGULAR), "enough gas: healthy read");
        // a genuine revert (cheap) still fails closed
        mo.setBurn(0);
        mo.setReverts(true, false, false, false);
        (ok,) = address(clock).call{gas: 300_000}(abi.encodeCall(clock.poke, (NVDA)));
        assertTrue(ok);
        assertEq(uint8(clock.state(NVDA)), uint8(ClockState.HALTED));
    }

    function test_scheduledClosureAndReference() public {
        Session memory mon = _mondayClosed();
        ClockData memory d = _info();
        assertEq(d.closureId, 1);
        assertEq(uint8(d.closureType), uint8(ClosureType.OVERNIGHT));
        assertEq(d.refPrice, 180e18);
        assertEq(d.refTime, mon.close);
        assertEq(d.reopenAt, _day(0, 1).open);
        assertEq(d.venueEpoch, 0);
        assertTrue(d.reopenPending);
        assertEq(uint8(d.state), uint8(ClockState.EXTENDED));
        assertEq(clock.closureDays(NVDA), 1);
    }

    function test_referenceProvisionalThenFinal() public {
        Session memory mon = _day(0, 0);
        _healthy();
        _listAt(mon.open + 1 hours);
        mo.setClose(179e18, mon.close - 10); // last regular print, before the close
        _pokeAt(mon.close + 1);
        assertEq(_info().refPrice, 179e18);
        mo.setClose(181e18, mon.close); // the official close lands
        vm.warp(mon.close + 30);
        vm.expectEmit(true, false, false, true);
        emit ReferenceUpdated(NVDA, 1, 181e18, mon.close);
        clock.poke(NVDA);
        assertEq(_info().refPrice, 181e18);
        mo.setClose(1e18, mon.close + 60); // final: no further updates
        _pokeAt(mon.close + 90);
        assertEq(_info().refPrice, 181e18);
    }

    function test_missingReferenceHalts() public {
        Session memory mon = _day(0, 0);
        _healthy();
        _listAt(mon.open + 1 hours);
        mo.setClose(180e18, mon.open - 1); // yesterday's close: not this session's
        assertEq(uint8(_pokeAt(mon.close + 1)), uint8(ClockState.HALTED), "no valid reference: HALTED");
        assertEq(_info().refPrice, 0);
        mo.setReverts(false, true, false, false);
        assertEq(uint8(_pokeAt(mon.close + 2)), uint8(ClockState.HALTED));
        mo.setReverts(false, false, false, false);
        mo.setClose(180e18, mon.close);
        assertEq(uint8(_pokeAt(mon.close + 3)), uint8(ClockState.EXTENDED), "reference recovered");
        mo.setClose(0, 0);
        assertEq(_info().refPrice, 180e18);
    }

    function test_missedPokesProcessEveryClose() public {
        Session memory mon = _mondayClosed();
        assertEq(_info().closureId, 1);
        mo.setClose(180e18, _day(1, 0).close);
        // nobody pokes for a week: Tue..Fri and next Monday closes are all counted
        _pokeAt(_day(1, 0).close + 1);
        ClockData memory d = _info();
        assertEq(d.closureId, 6, "one closure per scheduled close");
        assertEq(d.venueEpoch, 5);
        assertEq(uint8(d.closureType), uint8(ClosureType.OVERNIGHT));
        mon;
    }

    function test_weekendClosure() public {
        _healthy();
        Session memory fri = _day(0, 4);
        _listAt(fri.open + 1 hours);
        mo.setClose(180e18, fri.close);
        _pokeAt(fri.close + 1);
        assertEq(uint8(_info().closureType), uint8(ClosureType.WEEKEND));
        assertEq(_info().reopenAt, _day(1, 0).open);
        assertEq(clock.closureDays(NVDA), 3);
        assertEq(uint8(_pokeAt(fri.extClose + 1 days)), uint8(ClockState.CLOSED));
    }

    // ───────────── reopen / open print ─────────────

    function test_reopenFlow() public {
        _mondayClosed();
        Session memory tue = _day(0, 1);
        mo.setOpen(false, 0, false);
        assertEq(uint8(_pokeAt(tue.open)), uint8(ClockState.CLOSED), "waiting for the open print");
        mo.setReverts(false, false, false, true);
        assertEq(uint8(_pokeAt(tue.open + 10)), uint8(ClockState.CLOSED), "a failing oracle keeps it closed");
        mo.setReverts(false, false, false, false);
        mo.setOpen(true, 175e18, true);
        vm.warp(tue.open + 20);
        vm.expectEmit(true, false, false, true);
        emit OpenPrint(NVDA, 1, 175e18, true);
        assertEq(uint8(clock.poke(NVDA)), uint8(ClockState.REOPEN));
        assertEq(_info().openPrint, 175e18);
        assertEq(_info().openPrintAt, tue.open + 20);
        // INV-CLK-03: never rewritten
        mo.setOpen(true, 1e18, false);
        _pokeAt(tue.open + 30);
        assertEq(_info().openPrint, 175e18);

        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        clock.markReopenComplete(NVDA, 1);
        vm.startPrank(auctionHouse);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.WrongClosure.selector, 1, 2));
        clock.markReopenComplete(NVDA, 2);
        clock.markReopenComplete(NVDA, 0); // stale: no-op
        assertTrue(_info().reopenPending);
        vm.expectEmit(true, false, false, true);
        emit ReopenComplete(NVDA, 1);
        clock.markReopenComplete(NVDA, 1);
        vm.stopPrank();
        assertEq(uint8(clock.state(NVDA)), uint8(ClockState.REGULAR));
        vm.prank(settlement);
        clock.markReopenComplete(NVDA, 1); // already complete: no-op
    }

    function test_markReopenBeforeOpenPrintReverts() public {
        _mondayClosed();
        vm.prank(auctionHouse);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.ReopenNotPending.selector, NVDA));
        clock.markReopenComplete(NVDA, 1);
    }

    function test_sequencerGapExtendsPhase() public {
        _mondayClosed();
        Session memory tue = _day(0, 1);
        mo.setOpen(false, 0, false);
        _pokeAt(tue.open + 10); // gap measured from reopenAt: 10 s, no extension
        assertEq(_info().phaseExtension, 0);
        vm.warp(tue.open + 10 + 300);
        vm.expectEmit(false, false, false, true);
        emit PhaseExtended(300);
        clock.poke(NVDA);
        assertEq(_info().phaseExtension, 300 + 120);
        _pokeAt(tue.open + 10 + 300 + 100); // below 120 s: nothing
        assertEq(_info().phaseExtension, 420);
    }

    // ───────────── oracle input (INV-FAIL-01) ─────────────

    function test_oracleHaltsOpenAHaltClosure() public {
        Session memory mon = _day(0, 0);
        _healthy();
        _listAt(mon.open + 1 hours);
        _pokeAt(mon.open + 1 hours);
        FeedHealth memory h;
        h.stale = true;
        mo.setHealth(h);
        mo.setHalt(170e18, mon.open + 1 hours);
        vm.warp(mon.open + 2 hours);
        vm.expectEmit(true, false, false, true);
        emit ClosureStarted(NVDA, 1, 0, ClosureType.HALT, 170e18, _day(0, 1).open);
        assertEq(uint8(clock.poke(NVDA)), uint8(ClockState.HALTED));
        assertEq(_info().closeAt, mon.open + 2 hours);
        // halt clears: open print via the oracle's post-halt rule → REOPEN
        _healthy();
        mo.setOpen(true, 169e18, false);
        assertEq(uint8(_pokeAt(mon.open + 3 hours)), uint8(ClockState.REOPEN));
        assertEq(_info().closureId, 1);
    }

    function test_oracleInputs() public {
        Session memory mon = _day(0, 0);
        _healthy();
        _listAt(mon.open + 1 hours);
        FeedHealth memory h;
        h.severeDisagreement = true;
        mo.setHealth(h);
        assertEq(uint8(_pokeAt(mon.open + 1 hours)), uint8(ClockState.HALTED));
        mo.setReverts(true, false, false, false);
        assertEq(uint8(_pokeAt(mon.open + 2 hours)), uint8(ClockState.HALTED), "failing oracle: HALTED");
        mo.setReverts(false, false, true, false);
        h = FeedHealth(false, false, false, false, false, false, false);
        h.statusClosed = true;
        mo.setHealth(h);
        assertEq(uint8(_pokeAt(mon.open + 3 hours)), uint8(ClockState.CLOSED), "feed says closed");
        h.statusClosed = false;
        h.issuerFrozen = true;
        mo.setHealth(h);
        vm.warp(mon.extClose + 2 hours); // calendar CLOSED: a freeze still halts
        assertEq(uint8(clock.poke(NVDA)), uint8(ClockState.HALTED));
        h.issuerFrozen = false;
        mo.setClose(180e18, mon.close); // Monday's scheduled closure has its reference
        h.stale = true; // stale only matters while the calendar is open
        mo.setHealth(h);
        assertEq(uint8(_pokeAt(mon.extClose + 3 hours)), uint8(ClockState.CLOSED));
    }

    function test_navAsset() public {
        Session memory mon = _day(0, 0);
        vm.warp(mon.open + 1 hours);
        vm.prank(timelock);
        clock.listAsset(FUND, USBANK, MarketKind.NAV);
        FeedHealth memory h;
        mo.setHealth(h);
        assertEq(uint8(clock.poke(FUND)), uint8(ClockState.REGULAR));
        h.stale = true; // NAV older than 26 h: CLOSED
        mo.setHealth(h);
        vm.warp(mon.open + 2 hours);
        assertEq(uint8(clock.poke(FUND)), uint8(ClockState.CLOSED));
        h.navInvalid = true;
        mo.setHealth(h);
        vm.warp(mon.open + 3 hours);
        assertEq(uint8(clock.poke(FUND)), uint8(ClockState.HALTED));
        // a NAV reference is taken without the session-open check
        mo.setClose(1.01e18, mon.open - 3 days);
        h = FeedHealth(false, false, false, false, false, false, false);
        mo.setHealth(h);
        vm.warp(_day(0, 1).close + 1);
        clock.poke(FUND);
        assertEq(clock.closureInfo(FUND).refPrice, 1.01e18);
    }

    // ───────────── guardian (INV-CLK-02) ─────────────

    function test_restrict() public {
        Session memory mon = _day(0, 0);
        _healthy();
        _listAt(mon.open + 1 hours);
        _pokeAt(mon.open + 1 hours);
        uint40 now_ = uint40(vm.getBlockTimestamp());

        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        clock.restrict(NVDA, ClockState.HALTED, now_ + 1 hours);
        vm.startPrank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.InvalidRestriction.selector, ClockState.REGULAR)
        );
        clock.restrict(NVDA, ClockState.REGULAR, now_ + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.InvalidRestriction.selector, ClockState.REOPEN)
        );
        clock.restrict(NVDA, ClockState.REOPEN, now_ + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.RestrictionTooLong.selector, now_ + 8 days, now_ + 7 days)
        );
        clock.restrict(NVDA, ClockState.HALTED, now_ + 8 days);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.RestrictionNotTighter.selector, ClockState.HALTED, now_, 0)
        );
        clock.restrict(NVDA, ClockState.HALTED, now_);
        vm.expectEmit(true, false, false, true);
        emit Restricted(NVDA, ClockState.CLOSED, now_ + 2 hours);
        clock.restrict(NVDA, ClockState.CLOSED, now_ + 2 hours);
        assertEq(uint8(clock.state(NVDA)), uint8(ClockState.CLOSED), "applied immediately");
        assertEq(_info().closureId, 1, "a guardian close opens a closure");
        assertEq(uint8(_info().closureType), uint8(ClosureType.HALT));
        vm.expectRevert(
            abi.encodeWithSelector(
                ICredenceErrors.RestrictionNotTighter.selector,
                ClockState.CLOSED,
                now_ + 1 hours,
                now_ + 2 hours
            )
        );
        clock.restrict(NVDA, ClockState.CLOSED, now_ + 1 hours); // would shorten
        clock.restrict(NVDA, ClockState.HALTED, now_ + 1 hours);
        vm.stopPrank();
        Restriction memory r = clock.restriction(NVDA);
        assertEq(uint8(r.state), uint8(ClockState.HALTED));
        assertEq(r.until, now_ + 1 hours);
        assertEq(uint8(clock.state(NVDA)), uint8(ClockState.HALTED));

        // the HALT expiring does not lift the longer CLOSED
        vm.warp(now_ + 1 hours + 1);
        r = clock.restriction(NVDA);
        assertEq(uint8(r.state), uint8(ClockState.CLOSED));
        assertEq(uint8(clock.poke(NVDA)), uint8(ClockState.CLOSED));
        vm.warp(now_ + 2 hours + 1);
        r = clock.restriction(NVDA);
        assertEq(uint8(r.state), uint8(ClockState.REGULAR));
        mo.setOpen(true, 180e18, false);
        assertEq(uint8(clock.poke(NVDA)), uint8(ClockState.REOPEN), "the closure still ends through REOPEN");
    }

    // ───────────── corporate action ─────────────

    function test_corporateAction() public {
        Session memory mon = _day(0, 0);
        _healthy();
        _listAt(mon.open + 1 hours);
        _pokeAt(mon.open + 1 hours);

        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        clock.beginCorporateAction(NVDA);
        vm.expectEmit(true, false, false, true);
        emit CorporateActionBegun(NVDA, 1);
        vm.prank(guardian);
        clock.beginCorporateAction(NVDA);
        assertEq(uint8(clock.state(NVDA)), uint8(ClockState.CORP_ACTION));
        assertEq(uint8(_info().closureType), uint8(ClosureType.CORP_ACTION));
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.CorporateActionActive.selector, NVDA));
        clock.beginCorporateAction(NVDA);

        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        clock.confirmCorporateAction(NVDA, 2e18);
        vm.startPrank(timelock);
        vm.expectRevert(bytes("cap"));
        clock.confirmCorporateAction(NVDA, 7); // the adapter rejects the ratio: nothing changes
        assertTrue(_info().corporateAction);
        mo.setOpen(true, 90e18, false);
        vm.expectEmit(true, false, false, true);
        emit CorporateActionConfirmed(NVDA, 2e18);
        clock.confirmCorporateAction(NVDA, 2e18);
        assertEq(mo.lastSpt(), 2e18);
        assertEq(uint8(clock.state(NVDA)), uint8(ClockState.REOPEN));
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.CorporateActionNotActive.selector, NVDA));
        clock.confirmCorporateAction(NVDA, 2e18);
        vm.stopPrank();
    }

    // ───────────── views ─────────────

    function test_bellAndWindows() public {
        Session memory mon = _day(0, 0);
        _healthy();
        _listAt(mon.extOpen - 1);
        // before the first session
        (uint40 closeAt, uint40 reopenAt, ClosureType t) = clock.closureWindow(NVDA);
        assertEq(closeAt, 0);
        assertEq(reopenAt, mon.open);
        assertEq(uint8(t), uint8(ClosureType.NONE));
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.ClosureOpenEnded.selector, NVDA));
        clock.closureDays(NVDA);

        _pokeAt(mon.close - 3 hours);
        assertEq(_info().nextCloseAt, mon.close);
        assertEq(_info().bellWindowAt, mon.close - 2 hours);
        assertEq(_info().bellAt, mon.close - 15 minutes);
        assertFalse(clock.isBellWindow(NVDA));
        vm.warp(mon.close - 2 hours);
        assertTrue(clock.isBellWindow(NVDA));
        assertFalse(clock.isAfterBellDeadline(NVDA));
        vm.warp(mon.close - 15 minutes);
        assertTrue(clock.isAfterBellDeadline(NVDA));
        vm.warp(mon.close);
        assertFalse(clock.isBellWindow(NVDA), "after the close the next close is tomorrow's");
        (closeAt, reopenAt, t) = clock.closureWindow(NVDA);
        assertEq(closeAt, mon.close);
        assertEq(reopenAt, _day(0, 1).open);
        assertEq(uint8(t), uint8(ClosureType.OVERNIGHT));
        vm.warp(_day(0, 1).extOpen + 1); // pre-market: still the same closure
        (closeAt,,) = clock.closureWindow(NVDA);
        assertEq(closeAt, mon.close);
        _pokeAt(_day(0, 1).extOpen + 1);
        assertEq(_info().nextCloseAt, _day(0, 1).close);

        // after the last session's open: no reopen is known
        Session memory last = sessions[sessions.length - 1];
        vm.warp(last.open + 1);
        (, reopenAt,) = clock.closureWindow(NVDA);
        assertEq(reopenAt, 0);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.ClosureOpenEnded.selector, NVDA));
        clock.closureDays(NVDA);
        vm.warp(last.close + 1);
        _pokeAt(last.close + 1);
        assertEq(_info().nextCloseAt, 0);
        assertEq(_info().bellAt, 0);
        assertFalse(clock.isBellWindow(NVDA));
        assertFalse(clock.isAfterBellDeadline(NVDA));
    }

    function test_previewState() public {
        Session memory mon = _day(0, 0);
        _healthy();
        _listAt(mon.open + 1 hours);
        vm.warp(mon.open + 1 hours);
        assertEq(uint8(clock.previewState(NVDA)), uint8(ClockState.REGULAR));
        clock.poke(NVDA);
        // a close pending: preview sees the new closure and its reference
        mo.setClose(180e18, mon.close);
        vm.warp(mon.close + 1);
        assertEq(uint8(clock.previewState(NVDA)), uint8(ClockState.EXTENDED));
        mo.setClose(180e18, mon.open - 1);
        assertEq(uint8(clock.previewState(NVDA)), uint8(ClockState.HALTED), "missing reference");
        mo.setClose(179e18, mon.close - 5);
        clock.poke(NVDA); // provisional reference
        mo.setClose(0, 0);
        assertEq(uint8(clock.previewState(NVDA)), uint8(ClockState.EXTENDED));
        mo.setClose(181e18, mon.close);
        assertEq(uint8(clock.previewState(NVDA)), uint8(ClockState.EXTENDED));
        // next day: open print available → REOPEN; not available → CLOSED; oracle failing → CLOSED
        vm.warp(_day(0, 1).open + 1);
        mo.setOpen(true, 175e18, false);
        assertEq(uint8(clock.previewState(NVDA)), uint8(ClockState.REOPEN));
        mo.setOpen(false, 0, false);
        assertEq(uint8(clock.previewState(NVDA)), uint8(ClockState.CLOSED));
        mo.setReverts(false, false, false, true);
        assertEq(uint8(clock.previewState(NVDA)), uint8(ClockState.CLOSED));
        mo.setReverts(false, false, false, false);
        // a non-calendar halt from REGULAR is previewed too
        mo.setOpen(true, 175e18, false);
        clock.poke(NVDA);
        uint64 cid = _info().closureId;
        vm.prank(auctionHouse);
        clock.markReopenComplete(NVDA, cid);
        FeedHealth memory h;
        h.stale = true;
        mo.setHealth(h);
        assertEq(uint8(clock.previewState(NVDA)), uint8(ClockState.HALTED));
    }

    function test_pokeMany() public {
        Session memory mon = _day(0, 0);
        _healthy();
        _listAt(mon.open + 1 hours);
        vm.prank(timelock);
        clock.listAsset(FUND, USBANK, MarketKind.NAV);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = NVDA;
        ids[1] = FUND;
        clock.pokeMany(ids);
        assertEq(uint8(clock.state(NVDA)), uint8(ClockState.REGULAR));
        assertEq(uint8(clock.state(FUND)), uint8(ClockState.REGULAR));
    }
}
