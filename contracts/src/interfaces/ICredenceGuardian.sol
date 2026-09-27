// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {IGuardianEvents} from "../libraries/Events.sol";

/// @title Guardian: can only make the protocol safer (Build Guide §8.11). Interface v1.
/// @notice Callable by the Guardian Safe only (`safe`), except `executeUnpause*` after the delay (anyone) and the
///         timelock's instant unpause.
interface ICredenceGuardian is IGuardianEvents, ICredenceErrors {
    function pauseBorrow(bytes32 marketId) external; // instant; bytes32(0) = ALL
    function scheduleUnpauseBorrow(bytes32 marketId) external; // 6-hour delay
    function executeUnpause(bytes32 marketId) external; // after the delay, or instantly by the timelock
    function haltAsset(bytes32 assetId, uint40 until) external; // until ≤ now + 7 days, renewable
    function extendClosed(bytes32 assetId, uint40 until) external; // only extends
    function raiseHaircut(bytes32 marketId, uint64 bps) external; // bps ≤ 1000; expires after 7 days
    function pauseCover(address poolOrMarket) external; // instant
    function scheduleUnpauseCover(address poolOrMarket) external; // 6-hour delay
    function executeUnpauseCover(address poolOrMarket) external;

    // ── v1 additions ──
    /// @notice Once, by the deployer. The clock is wired at construction of the clock (guardian = this).
    function initializeWiring(address market, address clock) external;
    function safe() external view returns (address);
    function timelock() external view returns (address);
    function market() external view returns (address);
    function clock() external view returns (address);
    function UNPAUSE_DELAY() external view returns (uint40);
    function MAX_HALT() external view returns (uint40);
    function HAIRCUT_TTL() external view returns (uint40);
    function MAX_HAIRCUT_BPS() external view returns (uint64);
    /// @notice When a scheduled borrow unpause becomes executable (0 = none).
    function unpauseBorrowAt(bytes32 marketId) external view returns (uint40);
    function unpauseCoverAt(address poolOrMarket) external view returns (uint40);
}
