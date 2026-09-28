// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClockFixture} from "../utils/ClockFixture.sol";
import {Session, ReportKind, FeedMarketStatus, MarketKind, ClockState} from "../../src/libraries/Types.sol";
import {CalendarStore} from "../../src/clock/CalendarStore.sol";
import {AssetClock} from "../../src/clock/AssetClock.sol";
import {SequencerHealth} from "../../src/oracle/SequencerHealth.sol";
import {CredencePriceFeed} from "../../src/oracle/CredencePriceFeed.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {MockProbeToken} from "../mocks/MockProbeToken.sol";

/// @notice R-23 end to end: real USBANK calendar (fixture 2026-10-01 → 11-25), CalendarStore, AssetClock,
///         OracleAdapter and a signed NAV feed. Freshness counts USBANK strikes (17:00 ET), so weekends and bank
///         holidays never stale a NAV; one missed strike → CLOSED, two → HALTED.
contract NavStalenessTest is ClockFixture {
    bytes32 constant FUND = keccak256("TBILL:USBANK");
    CredencePriceFeed navFeed;

    function setUp() public {
        _loadCalendarFixture("test/fixtures/USBANK-20261001-fixture.json");
        vm.warp(sessions[0].open + 1 hours);
        calendar = new CalendarStore(timelock);
        vm.prank(timelock);
        calendar.appendSessions(USBANK, sessions);
        seqHealth = new SequencerHealth();
        clock = new AssetClock(timelock, guardian, address(calendar), address(seqHealth));
        seqHealth.setClock(address(clock));
        _makeCommittee();
        navFeed = new CredencePriceFeed(timelock, signers, 2);
        oracle = new OracleAdapter(timelock);
        oracle.setClock(address(clock));
        clock.initializeWiring(address(oracle), auctionHouse, settlement);
        MockProbeToken fund = new MockProbeToken();
        vm.startPrank(timelock);
        oracle.setAssetConfig(
            FUND, address(navFeed), address(0), address(0), address(fund), MarketKind.NAV, 0
        );
        clock.listAsset(FUND, USBANK, MarketKind.NAV);
        vm.stopPrank();
    }

    function _navAt(uint256 nav, uint40 at) internal {
        vm.warp(at);
        _submit(navFeed, _report(navFeed, FUND, ReportKind.NAV, nav, at, 0, FeedMarketStatus.CLOSED));
    }

    function _stateAt(uint256 t) internal returns (ClockState) {
        vm.warp(t);
        return clock.poke(FUND);
    }

    /// @dev Monday-morning reopen of a NAV market: the first valid NAV after the close is the open print.
    function _reopen(uint256 t) internal {
        assertEq(uint8(_stateAt(t)), uint8(ClockState.REOPEN), "reopen on the fresh NAV");
        uint64 id = clock.closureInfo(FUND).closureId;
        vm.prank(settlement);
        clock.markReopenComplete(FUND, id);
        assertEq(uint8(clock.state(FUND)), uint8(ClockState.REGULAR));
    }

    function test_normalWeekend() public {
        Session memory fri = sessions[1]; // Fri 2026-10-02
        Session memory mon = sessions[2]; // Mon 2026-10-05
        _navAt(1e18, fri.close + 15 minutes);
        assertEq(uint8(_stateAt(fri.extClose + 1 hours)), uint8(ClockState.CLOSED), "weekend");
        // Monday 10:00 ET: the NAV is ~65 h old (the v1.0 "50 h" rule would HALT here)
        _reopen(mon.open + 1 hours);
        assertEq(uint8(_stateAt(mon.close - 1 hours)), uint8(ClockState.REGULAR));
    }

    function test_holidayWeekend() public {
        Session memory fri = sessions[6]; // Fri 2026-10-09
        Session memory tue = sessions[7]; // Tue 2026-10-13, after Columbus Day
        _navAt(1e18, fri.close + 15 minutes);
        assertEq(uint8(_stateAt(fri.close + 3 days)), uint8(ClockState.CLOSED), "holiday Monday");
        _reopen(tue.open + 1 hours); // ~89 h old
    }

    function test_missedSingleStrike() public {
        Session memory fri = sessions[1];
        Session memory mon = sessions[2];
        Session memory tue = sessions[3];
        _navAt(1e18, fri.close + 15 minutes);
        _reopen(mon.open + 1 hours);
        // no NAV for Monday's strike: Tuesday is CLOSED (stale) during its regular hours, not HALTED
        assertEq(uint8(_stateAt(tue.open + 1 hours)), uint8(ClockState.CLOSED), "one missed strike");
        _navAt(1.0001e18, tue.open + 2 hours); // the late NAV is Tuesday's open print
        _reopen(tue.open + 3 hours);
    }

    function test_missedDoubleStrike() public {
        Session memory fri = sessions[1];
        Session memory mon = sessions[2];
        Session memory wed = sessions[4];
        _navAt(1e18, fri.close + 15 minutes);
        _reopen(mon.open + 1 hours);
        // Monday's and Tuesday's strikes both missed
        assertEq(uint8(_stateAt(wed.open + 1 hours)), uint8(ClockState.HALTED), "two missed strikes");
    }
}
