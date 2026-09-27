// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClockState} from "./Types.sol";

/// @title Clock-state restrictiveness (Build Guide §8.1, §8.2.2).
/// @dev CORP_ACTION (5) > HALTED (4) > CLOSED (3) > REOPEN (2) > EXTENDED (1) > REGULAR (0).
library ClockLib {
    function rank(ClockState s) internal pure returns (uint8) {
        if (s == ClockState.REGULAR) return 0;
        if (s == ClockState.EXTENDED) return 1;
        if (s == ClockState.REOPEN) return 2;
        if (s == ClockState.CLOSED) return 3;
        if (s == ClockState.HALTED) return 4;
        return 5; // CORP_ACTION
    }

    function mostRestrictive(ClockState a, ClockState b) internal pure returns (ClockState) {
        return rank(a) >= rank(b) ? a : b;
    }

    /// @notice True for the states in which a closure is in force (no liquidation; §1.5 P1).
    function isShut(ClockState s) internal pure returns (bool) {
        return s == ClockState.CLOSED || s == ClockState.HALTED || s == ClockState.CORP_ACTION;
    }
}
