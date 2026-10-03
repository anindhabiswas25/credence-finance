// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {ClockFixture} from "../utils/ClockFixture.sol";
import {
    ClockState,
    ClockData,
    ClosureType,
    MarketKind,
    FeedHealth,
    Restriction,
    Session,
    FeedMarketStatus
} from "../../src/libraries/Types.sol";
import {ClockLib} from "../../src/libraries/ClockLib.sol";
import {IAssetClockEvents} from "../../src/libraries/Events.sol";
import {CalendarStore} from "../../src/clock/CalendarStore.sol";
import {AssetClock} from "../../src/clock/AssetClock.sol";
import {SequencerHealth} from "../../src/oracle/SequencerHealth.sol";
import {CredencePriceFeed} from "../../src/oracle/CredencePriceFeed.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {CredenceStockToken} from "../../src/testnet/CredenceStockToken.sol";
import {MockTwapSource} from "../mocks/MockTwapSource.sol";

/// @dev Drives the real clock + price stack with random actors: time, relayers (live / open / close / status),
///      the DEX, the guardian, governance (corporate actions), the auction house and the issuer (freeze).
///      Ghost state is rebuilt from events so the invariants are checked against what the contract announced.
contract ClockHandler is ClockFixture {
    using ClockLib for ClockState;

    uint40 public constant T0 = 1_799_971_200;
    uint256 public constant WEEKS = 20;

    // ── ghosts ──
    uint64 public scheduledClosures;
    uint64 public unscheduledClosures;
    uint32 public closedAtList;
    uint40 public lastPokeTs;
    uint64 public maxClosureId;
    mapping(uint64 closureId => uint256) public openPrintEvents;
    mapping(uint64 closureId => uint128) public openPrintSeen;
    bool public closureIdDecreased;
    bool public openPrintRewritten;
    bool public failClosedViolated;
    bool public guardianViolated;
    bool public restrictionShortened;
    string public violation;
    uint40 public ghostHaltedUntil;
    uint40 public ghostClosedUntil;
    uint256 public calls;

    bytes32 internal constant CLOSURE_STARTED =
        keccak256("ClosureStarted(bytes32,uint64,uint64,uint8,uint256,uint40)");
    bytes32 internal constant OPEN_PRINT = keccak256("OpenPrint(bytes32,uint64,uint256,bool)");

    constructor() {
        vm.warp(T0);
        _syntheticSessions(T0, WEEKS);
        _deployStack();
        vm.warp(sessions[0].open + 30 minutes);
        _liveBoth(price(), FeedMarketStatus.REGULAR);
        _list();
        closedAtList = clock.closureInfo(NVDA).closedSessions;
        _recordedPoke();
    }

    function price() public pure returns (uint256) {
        return 180e18;
    }

    // ───────────── actions ─────────────

    function warp(uint256 secs) external {
        calls++;
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 30 hours));
    }

    function poke() external {
        calls++;
        _recordedPoke();
    }

    /// @dev A relayer tick: live prints, with the status a vendor would report for the calendar state
    ///      (or a random one), at a price within ±8% of 180.
    function relay(uint256 seed, bool bothFeeds, bool randomStatus) external {
        calls++;
        uint256 p = 180e18 * (920 + (seed % 161)) / 1000;
        uint8 status = randomStatus ? uint8(seed % 6) : _vendorStatus();
        _live(feedA, NVDA, p, status);
        if (bothFeeds) _live(feedB, NVDA, seed % 7 == 0 ? p * 107 / 100 : p, status);
        _recordedPoke();
    }

    function officialPrints(uint256 seed, bool agree) external {
        calls++;
        (uint256 idx, bool found) = calendar.findSession(XNYS, uint40(vm.getBlockTimestamp()));
        if (!found) return;
        Session memory s = sessions[idx];
        uint256 now_ = vm.getBlockTimestamp();
        uint256 p = 180e18 * (950 + (seed % 101)) / 1000;
        if (now_ >= s.open) {
            _openPrint(feedA, NVDA, p, s.open);
            _openPrint(feedB, NVDA, agree ? p : p * 110 / 100, s.open);
        }
        if (now_ >= s.close) {
            _closePrint(feedA, NVDA, p, s.open, uint40(s.close));
        }
        _recordedPoke();
    }

    function haltStatus(bool halted) external {
        calls++;
        _status(feedA, NVDA, halted ? FeedMarketStatus.HALTED : _vendorStatus());
        _recordedPoke();
    }

    function dexMove(uint256 p, bool deep) external {
        calls++;
        dex.set(bound(p, 1e18, 400e18), true, deep ? 1e30 : 0);
    }

    function guardianRestrict(bool halt, uint256 dur) external {
        calls++;
        ClockState s = halt ? ClockState.HALTED : ClockState.CLOSED;
        uint40 until = uint40(vm.getBlockTimestamp() + bound(dur, 0, 8 days));
        uint40 prev = halt ? clock.haltedUntil(NVDA) : clock.closedUntil(NVDA);
        vm.recordLogs();
        vm.prank(guardian);
        try clock.restrict(NVDA, s, until) {
            if (until < prev) restrictionShortened = true;
            if (halt) ghostHaltedUntil = until;
            else ghostClosedUntil = until;
        } catch {}
        _consumeLogs();
        _recordedPoke(); // a failed call poked nothing: poke now so every ghost refers to this block
    }

    function corporateAction(bool begin, uint256 ratioSeed) external {
        calls++;
        vm.recordLogs();
        if (begin) {
            vm.prank(guardian);
            try clock.beginCorporateAction(NVDA) {} catch {}
        } else {
            vm.prank(timelock);
            try clock.confirmCorporateAction(NVDA, bound(ratioSeed, 0.2e18, 5e18)) {} catch {}
        }
        _consumeLogs();
        _recordedPoke();
    }

    function auctionDone(bool stale) external {
        calls++;
        ClockData memory d = clock.closureInfo(NVDA);
        vm.recordLogs();
        vm.prank(auctionHouse);
        try clock.markReopenComplete(NVDA, stale && d.closureId > 0 ? d.closureId - 1 : d.closureId) {}
            catch {}
        _consumeLogs();
        _recordedPoke();
    }

    function issuerFreeze(bool f) external {
        calls++;
        vm.prank(issuer);
        token.setFrozen(f);
        _recordedPoke();
    }

    // ───────────── bookkeeping ─────────────

    function _vendorStatus() internal view returns (uint8) {
        ClockState c = clock.calendarState(NVDA);
        if (c == ClockState.REGULAR) return FeedMarketStatus.REGULAR;
        if (c == ClockState.EXTENDED) return FeedMarketStatus.POST;
        return FeedMarketStatus.CLOSED;
    }

    function _recordedPoke() internal {
        vm.recordLogs();
        clock.poke(NVDA);
        _consumeLogs();
        _afterPoke();
    }

    function _consumeLogs() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(clock)) continue;
            if (logs[i].topics[0] == CLOSURE_STARTED) {
                (,, uint8 t,,) = abi.decode(logs[i].data, (uint64, uint64, uint8, uint256, uint40));
                if (t == uint8(ClosureType.HALT) || t == uint8(ClosureType.CORP_ACTION)) {
                    unscheduledClosures++;
                } else {
                    scheduledClosures++;
                }
            } else if (logs[i].topics[0] == OPEN_PRINT) {
                (uint64 cid, uint256 p,) = abi.decode(logs[i].data, (uint64, uint256, bool));
                openPrintEvents[cid]++;
                if (openPrintSeen[cid] != 0 && openPrintSeen[cid] != p) openPrintRewritten = true;
                openPrintSeen[cid] = uint128(p);
            }
        }
    }

    /// @dev Checks that must hold in the same block as the transition (INV-CLK-02, INV-FAIL-01).
    function _afterPoke() internal {
        lastPokeTs = uint40(vm.getBlockTimestamp());
        ClockData memory d = clock.closureInfo(NVDA);
        if (d.closureId < maxClosureId) closureIdDecreased = true;
        maxClosureId = d.closureId;
        if (d.openPrint != 0 && openPrintSeen[d.closureId] != 0 && d.openPrint != openPrintSeen[d.closureId])
        {
            openPrintRewritten = true;
        }
        ClockState st = d.state;

        // INV-CLK-02: an active guardian restriction is always respected
        Restriction memory r = clock.restriction(NVDA);
        if (r.state != ClockState.REGULAR && st.rank() < r.state.rank()) {
            guardianViolated = true;
            violation = "state below active restriction";
        }

        // INV-FAIL-01: never less restrictive than the calendar, nor than the oracle's verdict
        ClockState cal = clock.calendarState(NVDA);
        if (st.rank() < cal.rank()) {
            failClosedViolated = true;
            violation = "state below calendar";
        }
        FeedHealth memory h = oracle.feedHealth(NVDA);
        bool open = cal != ClockState.CLOSED;
        if ((h.statusHalted || h.issuerFrozen || (open && (h.stale || h.severeDisagreement)))) {
            if (st.rank() < ClockState.HALTED.rank()) {
                failClosedViolated = true;
                violation = "oracle HALT not applied";
            }
        } else if (open && h.statusClosed && st.rank() < ClockState.CLOSED.rank()) {
            failClosedViolated = true;
            violation = "feed-closed not applied";
        }
    }

    // ───────────── views for the invariant contract ─────────────

    function clock_() external view returns (address) {
        return address(clock);
    }

    function oracle_() external view returns (address) {
        return address(oracle);
    }

    function sessionCount() external view returns (uint256) {
        return sessions.length;
    }

    function sessionClose(uint256 i) external view returns (uint40) {
        return sessions[i].close;
    }
}
