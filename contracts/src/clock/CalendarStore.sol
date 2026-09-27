// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Session, ClosureType} from "../libraries/Types.sol";
import {ICalendarStore} from "../interfaces/ICalendarStore.sol";

/// @title CalendarStore: append-only exchange sessions per venue (Build Guide §8.2.1).
/// @notice Sessions are precomputed off-chain in UTC and loaded a year ahead through the timelock.
///         There is no timezone or DST logic on-chain.
contract CalendarStore is ICalendarStore {
    address public immutable timelock;

    mapping(bytes32 venue => Session[]) internal _sessions;

    constructor(address timelock_) {
        if (timelock_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
    }

    /// @inheritdoc ICalendarStore
    /// @custom:state any (governance)
    function appendSessions(bytes32 venue, Session[] calldata s) external {
        if (msg.sender != timelock) revert Unauthorized();
        if (venue == bytes32(0)) revert UnknownVenue(venue);
        uint256 n = s.length;
        if (n == 0) revert EmptySessions();

        Session[] storage arr = _sessions[venue];
        uint256 from = arr.length;
        uint40 prevExtClose = from == 0 ? 0 : arr[from - 1].extClose;

        for (uint256 i; i < n; ++i) {
            Session calldata x = s[i];
            if (!(x.extOpen < x.open && x.open < x.close && x.close < x.extClose)) {
                revert SessionNotIncreasing(from + i);
            }
            if (
                x.closureTypeAfter != ClosureType.OVERNIGHT && x.closureTypeAfter != ClosureType.WEEKEND
                    && x.closureTypeAfter != ClosureType.HOLIDAY_WEEKEND
            ) revert InvalidClosureType(from + i);
            if ((from + i) > 0 && x.extOpen < prevExtClose) revert SessionOutOfOrder(from + i);
            arr.push(x);
            prevExtClose = x.extClose;
        }
        emit SessionsAppended(venue, from, n, s[n - 1].close);
    }

    /// @inheritdoc ICalendarStore
    function sessionCount(bytes32 venue) external view returns (uint256) {
        return _sessions[venue].length;
    }

    /// @inheritdoc ICalendarStore
    function session(bytes32 venue, uint256 i) external view returns (Session memory) {
        Session[] storage arr = _sessions[venue];
        if (i >= arr.length) revert SessionIndexOutOfRange(i);
        return arr[i];
    }

    /// @inheritdoc ICalendarStore
    function sessions(bytes32 venue, uint256 from, uint256 count) external view returns (Session[] memory out) {
        Session[] storage arr = _sessions[venue];
        uint256 len = arr.length;
        if (from >= len) return new Session[](0);
        uint256 end = from + count > len ? len : from + count;
        out = new Session[](end - from);
        for (uint256 i = from; i < end; ++i) {
            out[i - from] = arr[i];
        }
    }

    /// @inheritdoc ICalendarStore
    function coverageEnd(bytes32 venue) external view returns (uint40) {
        Session[] storage arr = _sessions[venue];
        uint256 len = arr.length;
        return len == 0 ? 0 : arr[len - 1].close;
    }

    /// @inheritdoc ICalendarStore
    function findSession(bytes32 venue, uint40 t) external view returns (uint256 index, bool found) {
        Session[] storage arr = _sessions[venue];
        uint256 lo;
        uint256 hi = arr.length;
        // first index with extClose > t (extClose is strictly increasing)
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (arr[mid].extClose > t) hi = mid;
            else lo = mid + 1;
        }
        return (lo, lo < arr.length);
    }
}
