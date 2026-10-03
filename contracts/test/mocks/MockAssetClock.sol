// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClockState, ClockData, AssetConfig, MarketKind} from "../../src/libraries/Types.sol";

/// @dev The AssetClock views the OracleAdapter reads, settable per test.
contract MockAssetClock {
    ClockState public st;
    ClockState public cal;
    ClockData internal d;
    address public calendar;
    bytes32 internal venue_;

    function setCalendar(address c, bytes32 venue) external {
        calendar = c;
        venue_ = venue;
    }

    function assetConfig(bytes32) external view returns (AssetConfig memory) {
        return AssetConfig({venue: venue_, kind: MarketKind.NAV, listed: true});
    }

    function set(ClockState s, ClockState c) external {
        st = s;
        cal = c;
    }

    function setData(ClockData memory x) external {
        d = x;
    }

    function state(bytes32) external view returns (ClockState) {
        return st;
    }

    function calendarState(bytes32) external view returns (ClockState) {
        return cal;
    }

    function closureInfo(bytes32) external view returns (ClockData memory) {
        return d;
    }
}
