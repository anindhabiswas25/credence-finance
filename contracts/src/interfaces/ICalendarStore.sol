// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Session} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {ICalendarStoreEvents} from "../libraries/Events.sol";

/// @title Exchange-session calendar, append-only (Build Guide §8.2.1).
/// @notice Sessions are precomputed off-chain in UTC. There is no timezone or DST logic on-chain.
interface ICalendarStore is ICalendarStoreEvents, ICredenceErrors {
    /// @notice Append sessions for a venue. Each session must satisfy extOpen < open < close < extClose and
    ///         `closureTypeAfter` ∈ {OVERNIGHT, WEEKEND, HOLIDAY_WEEKEND}. Sessions never overlap:
    ///         `s[i].extOpen >= s[i-1].extClose` (equal on weeknights, where the 24/5 window runs through),
    ///         which implies the guide's `s[i].open > s[i-1].close`.
    /// @custom:state any (governance). onlyTimelock.
    function appendSessions(bytes32 venue, Session[] calldata s) external;

    /// @notice Number of sessions stored for a venue.
    function sessionCount(bytes32 venue) external view returns (uint256);
    /// @notice Session `i` of a venue (UTC unix seconds).
    function session(bytes32 venue, uint256 i) external view returns (Session memory);
    /// @notice Up to `count` sessions starting at `from` (truncated at the end of the calendar).
    function sessions(bytes32 venue, uint256 from, uint256 count) external view returns (Session[] memory);
    /// @notice Close of the last loaded session (0 if none). After it, every asset of the venue is CLOSED.
    function coverageEnd(bytes32 venue) external view returns (uint40);
    /// @notice Index of the first session whose `extClose > t` (binary search). `found = false` if none.
    function findSession(bytes32 venue, uint40 t) external view returns (uint256 index, bool found);
    /// @notice The governance timelock (the only writer).
    function timelock() external view returns (address);
}
