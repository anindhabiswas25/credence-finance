// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Session, ClosureType, FeedMarketStatus} from "../../src/libraries/Types.sol";
import {CalendarStore} from "../../src/clock/CalendarStore.sol";
import {ChainlinkStockPriceSource} from "../../src/oracle/ChainlinkStockPriceSource.sol";
import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";
import {MockRobinhoodStock, MockAccessControlsRegistry} from "../mocks/MockRobinhoodStock.sol";

/// @dev ChainlinkStockPriceSource (ADR-0121) against 800 recorded rounds of Chainlink's "Robinhood TSLA / USD" feed on
///      Robinhood Chain mainnet (2026-07-29 .. 2026-09-30, `test/fixtures/chainlink/rhtsla-rounds.json`), with an XNYS
///      calendar for those weeks (EDT: open 13:30Z, close 20:00Z; Labor Day 2026-09-07 closed).
contract ChainlinkStockPriceSourceTest is Test {
    bytes32 internal constant XNYS = bytes32("XNYS");
    bytes32 internal constant RHTSLA = keccak256("RHTSLA:XNAS");
    uint40 internal constant MON_AUG03 = 1_785_715_200; // 2026-08-03 00:00:00 UTC
    uint40 internal constant LABOR_DAY = 1_788_739_200; // 2026-09-07 00:00:00 UTC
    address internal timelock = makeAddr("timelock");

    CalendarStore internal cal;
    MockChainlinkAggregator internal agg;
    MockRobinhoodStock internal token;
    ChainlinkStockPriceSource internal src;
    uint256[] internal upd;
    int256[] internal ans;

    function setUp() public {
        string memory j = vm.readFile("test/fixtures/chainlink/rhtsla-rounds.json");
        uint256[] memory ids = vm.parseJsonUintArray(j, ".roundIds");
        int256[] memory a = vm.parseJsonIntArray(j, ".answers");
        uint256[] memory u = vm.parseJsonUintArray(j, ".updatedAts");
        uint80[] memory ids80 = new uint80[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            ids80[i] = uint80(ids[i]);
            upd.push(u[i]);
            ans.push(a[i]);
        }
        agg = new MockChainlinkAggregator(8);
        agg.load(ids80, a, u);

        cal = new CalendarStore(timelock);
        Session[] memory s = new Session[](42);
        uint256 n;
        for (uint256 d; d < 59; ++d) {
            uint40 day = MON_AUG03 + uint40(d) * 1 days;
            uint256 wd = (d % 7); // 0 = Monday
            if (wd >= 5 || day == LABOR_DAY) continue;
            bool beforeGap = wd == 4 || day + 1 days == LABOR_DAY;
            s[n++] = Session(
                day + 8 hours,
                day + 13 hours + 30 minutes,
                day + 20 hours,
                day + 24 hours - 1,
                beforeGap
                    ? (wd == 4 && day + 3 days == LABOR_DAY
                            ? ClosureType.HOLIDAY_WEEKEND
                            : ClosureType.WEEKEND)
                    : ClosureType.OVERNIGHT
            );
        }
        assembly {
            mstore(s, n)
        }
        vm.prank(timelock);
        cal.appendSessions(XNYS, s);

        token = new MockRobinhoodStock("Tesla", "TSLA", address(new MockAccessControlsRegistry()));
        src = new ChainlinkStockPriceSource(timelock, address(cal), XNYS);
        vm.prank(timelock);
        src.setFeed(RHTSLA, address(agg), address(token), 86_400);
    }

    /// @dev Round k is the latest, and the chain time is `dt` after it.
    function _at(uint256 k, uint256 dt) internal {
        agg.setHead(k);
        vm.warp(upd[k] + dt);
    }

    function _wad(uint256 k) internal view returns (uint256) {
        return uint256(ans[k]) * 1e10;
    }

    function _firstRoundAfter(uint256 t) internal view returns (uint256 k) {
        while (upd[k] < t) ++k;
    }

    function test_setFeedGuards() public {
        vm.expectRevert(ChainlinkStockPriceSource.Unauthorized.selector);
        src.setFeed(RHTSLA, address(agg), address(token), 1);
        vm.startPrank(timelock);
        vm.expectRevert(ChainlinkStockPriceSource.InvalidFeed.selector);
        src.setFeed(RHTSLA, address(0), address(token), 1);
        vm.expectRevert(ChainlinkStockPriceSource.InvalidFeed.selector);
        src.setFeed(RHTSLA, address(agg), address(token), 0);
        vm.stopPrank();
        (uint256 p,,) = src.latest(keccak256("NOPE"));
        assertEq(p, 0);
    }

    /// Regular hours: a round younger than the heartbeat is current (observedAt = now), priced per share = answer × 1e10
    /// ÷ the multiplier; status REGULAR from the calendar.
    function test_latestDuringRegularHours() public {
        uint256 k = _firstRoundAfter(MON_AUG03 + 7 days + 15 hours); // Mon Aug 10, 15:00Z
        _at(k, 60);
        (uint256 p, uint40 t, uint8 st) = src.latest(RHTSLA);
        assertEq(p, _wad(k));
        assertEq(t, block.timestamp, "fresh within the 24 h heartbeat");
        assertEq(st, FeedMarketStatus.REGULAR);
        (uint256 lp, uint40 lt) = src.lastRegular(RHTSLA);
        assertEq(lp, _wad(k));
        assertEq(lt, upd[k]);
        token.updateMultiplier(2e18);
        (p,,) = src.latest(RHTSLA);
        assertEq(p, _wad(k) / 2, "per share after a 2:1 split: the token price is unchanged");
    }

    /// The Labor Day weekend (recorded: Fri Sep 4 18:14Z → Tue Sep 8 00:00Z, 77.8 h without a round): past the
    /// heartbeat the round keeps its own time (stale for the adapter), the status is CLOSED, and the official close is
    /// the round in force at Friday's 20:00Z close.
    function test_weekendHeldPriceAndClose() public {
        uint256 k = _firstRoundAfter(LABOR_DAY - 3 days + 20 hours) - 1; // in force at Fri Sep 4 20:00Z
        assertLt(upd[k], LABOR_DAY - 3 days + 20 hours);
        _at(k, 0);
        vm.warp(LABOR_DAY + 12 hours); // Monday noon, the holiday
        (uint256 p, uint40 t, uint8 st) = src.latest(RHTSLA);
        assertEq(p, _wad(k), "the held price");
        assertEq(t, upd[k], "older than the heartbeat: its own time");
        assertEq(st, FeedMarketStatus.CLOSED);
        (uint256 cp, uint40 ct, uint40 sd) = src.officialClose(RHTSLA);
        assertEq(cp, _wad(k));
        assertEq(ct, upd[k]);
        assertEq(sd, (LABOR_DAY - 3 days) / 1 days);
        (uint256 lp,) = src.lastRegular(RHTSLA);
        assertEq(lp, cp, "outside regular hours: the close");
    }

    /// The open: the first round within 30 min of the regular open, if the feed printed one (it updates on 0.5 %
    /// deviation, so a quiet open may have none: then ok = false and the adapter uses its TWAP fallback).
    function test_officialOpenFromTheFirstRoundAfterTheOpen() public {
        uint256 found;
        for (uint256 d; d < 50 && found < 3; ++d) {
            uint40 day = MON_AUG03 + uint40(d) * 1 days;
            if ((d % 7) >= 5 || day == LABOR_DAY) continue;
            uint40 open = day + 13 hours + 30 minutes;
            uint256 k = _firstRoundAfter(open);
            _at(k + 3 < upd.length ? k + 3 : k, 0);
            if (block.timestamp < open + 30 minutes) vm.warp(open + 30 minutes);
            (uint256 p, uint40 at, bool ok) = src.officialOpen(RHTSLA, open);
            if (upd[k] < open + 30 minutes) {
                assertTrue(ok);
                assertEq(at, upd[k]);
                assertEq(p, _wad(k));
                ++found;
            } else {
                assertFalse(ok, "no round within 30 min of the open");
            }
        }
        assertEq(found, 3, "three recorded opens checked");
    }

    /// TWAP over 1 h in regular hours = the time-weighted mean of the recorded rounds, computed here independently.
    function test_twapMatchesTheRecordedRounds() public {
        uint256 k = _firstRoundAfter(MON_AUG03 + 8 days + 17 hours); // Tue Aug 11, 17:00Z
        _at(k, 120);
        uint256 start = block.timestamp - 1 hours;
        uint256 acc;
        uint256 segEnd = block.timestamp;
        uint256 i = k;
        while (true) {
            uint256 from = upd[i] > start ? upd[i] : start;
            acc += _wad(i) * (segEnd - from);
            if (upd[i] <= start) break;
            segEnd = upd[i];
            --i;
        }
        (uint256 tw, bool ok) = src.twap(RHTSLA, 1 hours);
        assertTrue(ok);
        assertEq(tw, acc / 1 hours);
        (uint256 now0,) = src.twap(RHTSLA, 0);
        assertEq(now0, _wad(k));
        (, ok) = src.twap(RHTSLA, 30 days);
        assertFalse(ok, "64 rounds do not reach back 30 days");
    }
}
