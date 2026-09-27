// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClockState, ClockData} from "../../src/libraries/Types.sol";

/// @dev The three AssetClock views the OracleAdapter reads, settable per test.
contract MockAssetClock {
    ClockState public st;
    ClockState public cal;
    ClockData internal d;

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
