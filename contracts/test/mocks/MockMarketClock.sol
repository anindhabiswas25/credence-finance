// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClockState, ClockData, ClosureType, AssetConfig, MarketKind} from "../../src/libraries/Types.sol";

/// @notice The AssetClock views and `poke` the market uses, settable per asset, with a revert switch
///         (INV-REPAY-01/02 run with the clock failing too).
contract MockMarketClock {
    mapping(bytes32 => ClockState) public st;
    mapping(bytes32 => ClockData) internal d;
    mapping(bytes32 => ClosureType) public nextType;
    mapping(bytes32 => uint256) public days_;
    bool public reverting;
    uint256 public pokes;
    // S3: what the real UnderwriterPool / AuctionHouse read
    address public calendar;
    address public auctionHouse;
    address public settlement;
    uint256 public reopenCompletions;
    mapping(bytes32 => MarketKind) public kindOf; // S4: EQUITY by default

    function setSettlement(address a) external {
        settlement = a;
    }

    function setKind(bytes32 a, MarketKind k) external {
        kindOf[a] = k;
    }

    function assetConfig(bytes32 a) external view returns (AssetConfig memory c) {
        c.kind = kindOf[a];
        c.listed = true;
    }

    function setCalendar(address c) external {
        calendar = c;
    }

    function setAuctionHouse(address a) external {
        auctionHouse = a;
    }

    /// @dev The calendar session the asset is in (the market sends it as CoverRequest.epochId).
    function setCursor(bytes32 a, uint32 cursor) external {
        d[a].sessionCursor = cursor;
    }

    /// @dev A closure opened at the close of session `venueEpoch`, REOPEN pending until markReopenComplete.
    function setReopen(bytes32 a, uint64 closureId, uint64 venueEpoch, bool pending) external {
        d[a].closureId = closureId;
        d[a].venueEpoch = venueEpoch;
        d[a].reopenPending = pending;
    }

    function markReopenComplete(bytes32 a, uint64 closureId) external {
        require(
            msg.sender == auctionHouse || (settlement != address(0) && msg.sender == settlement),
            "only auction house"
        );
        require(closureId == d[a].closureId && d[a].reopenPending, "not pending");
        d[a].reopenPending = false;
        ++reopenCompletions;
        if (st[a] == ClockState.REOPEN) {
            st[a] = ClockState.REGULAR;
            d[a].state = ClockState.REGULAR;
        }
    }

    function setState(bytes32 a, ClockState s) external {
        st[a] = s;
        d[a].state = s;
    }

    function setData(bytes32 a, ClockData memory x) external {
        d[a] = x;
        st[a] = x.state;
    }

    /// @dev Bell times of the next close: window = close − 2 h, deadline = close − 15 min (§3.5).
    function setNextClose(bytes32 a, uint40 closeAt, ClosureType t, uint256 closureDays_) external {
        ClockData storage x = d[a];
        x.nextCloseAt = closeAt;
        x.bellWindowAt = closeAt - 2 hours;
        x.bellAt = closeAt - 15 minutes;
        nextType[a] = t;
        days_[a] = closureDays_;
    }

    function setClosureId(bytes32 a, uint64 id) external {
        d[a].closureId = id;
    }

    function setOpenPrint(bytes32 a, uint128 p, uint40 at) external {
        d[a].openPrint = p;
        d[a].openPrintAt = at;
    }

    function setPhaseExtension(bytes32 a, uint40 ext) external {
        d[a].phaseExtension = ext;
    }

    mapping(bytes32 => ClockState) public restrictedState;
    mapping(bytes32 => uint40) public restrictedUntil;

    /// @dev Like AssetClock.restrict: a live restriction can only be extended, never shortened (INV-CLK-02).
    function restrict(bytes32 a, ClockState s_, uint40 until) external {
        require(until >= restrictedUntil[a] || restrictedUntil[a] <= block.timestamp, "shorter");
        restrictedState[a] = s_;
        restrictedUntil[a] = until;
    }

    function setReverting(bool r) external {
        reverting = r;
    }

    function poke(bytes32 a) external returns (ClockState) {
        require(!reverting, "clock");
        ++pokes;
        return st[a];
    }

    function state(bytes32 a) external view returns (ClockState) {
        return st[a];
    }

    function previewState(bytes32 a) external view returns (ClockState) {
        return st[a];
    }

    function closureInfo(bytes32 a) external view returns (ClockData memory) {
        require(!reverting, "clock");
        return d[a];
    }

    function isAfterBellDeadline(bytes32 a) external view returns (bool) {
        ClockData storage x = d[a];
        return x.bellAt != 0 && block.timestamp >= x.bellAt && block.timestamp < x.nextCloseAt;
    }

    function closureWindow(bytes32 a) external view returns (uint40, uint40, ClosureType) {
        require(!reverting, "clock");
        return (d[a].nextCloseAt, 0, nextType[a]);
    }

    function closureDays(bytes32 a) external view returns (uint256) {
        require(!reverting, "clock");
        require(days_[a] != 0, "open-ended");
        return days_[a];
    }
}
