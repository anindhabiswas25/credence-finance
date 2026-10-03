// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {IGuardianEvents} from "../libraries/Events.sol";

/// @title Guardian: can only make the protocol safer (Build Guide §8.11). Interface v1.
/// @notice Callable by the Guardian Safe only (`safe`), except `executeUnpause*` after the delay (anyone) and the
///         timelock's instant unpause.
interface ICredenceGuardian is IGuardianEvents, ICredenceErrors {
    /// @notice Guardian Safe: pause new borrowing at once (bytes32(0) = every market).
    function pauseBorrow(bytes32 marketId) external;
    /// @notice Guardian Safe: schedule the unpause, executable after the 6-hour delay.
    function scheduleUnpauseBorrow(bytes32 marketId) external;
    /// @notice Executes a scheduled borrow unpause after the delay (or at once by the timelock).
    function executeUnpause(bytes32 marketId) external;
    /// @notice Guardian Safe: hold an asset HALTED until `until` (≤ now + 7 days, renewable).
    function haltAsset(bytes32 assetId, uint40 until) external;
    /// @notice Guardian Safe: keep an asset CLOSED until `until` (it can only extend, never shorten).
    function extendClosed(bytes32 assetId, uint40 until) external;
    /// @notice Guardian Safe: lower a market's max LTV by `bps` (≤ 1,000) for 7 days; only ever raises the
    ///        haircut.
    function raiseHaircut(bytes32 marketId, uint64 bps) external;
    /// @notice Guardian Safe: stop Gap Cover sales on a pool or market at once.
    function pauseCover(address poolOrMarket) external;
    /// @notice Guardian Safe: schedule the cover unpause, executable after the 6-hour delay.
    function scheduleUnpauseCover(address poolOrMarket) external;
    /// @notice Executes a scheduled cover unpause after the delay (or at once by the timelock).
    function executeUnpauseCover(address poolOrMarket) external;

    // ── v1 additions ──
    /// @notice Once, by the deployer: the market singletons of every stack (equity, NAV; R-01) and the shared clock.
    ///         A market id is applied on the market contract that lists it; bytes32(0) applies to all of them.
    function initializeWiring(address[] calldata markets, address clock) external;
    /// @notice The guardian Safe (the only caller of the restrict functions).
    function safe() external view returns (address);
    /// @notice The governance timelock.
    function timelock() external view returns (address);
    /// @notice The markets the guardian acts on.
    function markets() external view returns (address[] memory);
    /// @notice The AssetClock the guardian restricts.
    function clock() external view returns (address);
    /// @notice Delay between scheduling and executing an unpause (6 hours).
    function UNPAUSE_DELAY() external view returns (uint40);
    /// @notice Longest single halt (7 days).
    function MAX_HALT() external view returns (uint40);
    /// @notice Lifetime of a raised haircut (7 days).
    function HAIRCUT_TTL() external view returns (uint40);
    /// @notice Largest haircut (1,000 bps).
    function MAX_HAIRCUT_BPS() external view returns (uint64);
    /// @notice When a scheduled borrow unpause becomes executable (0 = none).
    function unpauseBorrowAt(bytes32 marketId) external view returns (uint40);
    /// @notice When a scheduled cover unpause becomes executable (0 = none).
    function unpauseCoverAt(address poolOrMarket) external view returns (uint40);
}
