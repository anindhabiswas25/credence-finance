// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {
    ClockState,
    ClockData,
    ClosureType,
    MarketKind,
    AssetConfig,
    Restriction
} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {IAssetClockEvents} from "../libraries/Events.sol";

/// @title Asset Clock (Build Guide §8.2.2). Lazy state machine per asset.
/// @notice State = most restrictive of calendar, oracle, guardian and corporate-action inputs.
///         Restrictiveness: CORP_ACTION > HALTED > CLOSED > REOPEN > EXTENDED > REGULAR.
interface IAssetClock is IAssetClockEvents, ICredenceErrors {
    /// @notice Run the transition algorithm (§8.2.2 steps 1–10). Idempotent within a block. Permissionless.
    /// @custom:state any
    function poke(bytes32 assetId) external returns (ClockState);
    function pokeMany(bytes32[] calldata assetIds) external;

    /// @notice Stored state (may lag until poked).
    function state(bytes32 assetId) external view returns (ClockState);
    /// @notice What `poke()` would return now (may differ if an open print would be written by the poke).
    function previewState(bytes32 assetId) external view returns (ClockState);
    /// @notice Calendar-only state now: REGULAR / EXTENDED / CLOSED (CLOSED beyond coverage).
    function calendarState(bytes32 assetId) external view returns (ClockState);
    function closureInfo(bytes32 assetId) external view returns (ClockData memory);
    /// @notice bellWindowAt ≤ now < closeAt of the next scheduled close (computed from the calendar).
    function isBellWindow(bytes32 assetId) external view returns (bool);
    /// @notice bellAt ≤ now < closeAt of the next scheduled close.
    function isAfterBellDeadline(bytes32 assetId) external view returns (bool);
    /// @notice The scheduled closure that is in progress or comes next: the one between the close of session j−1
    ///         and the open of session j, where j is the first session with `open > now`.
    function closureWindow(bytes32 assetId)
        external
        view
        returns (uint40 closeAt, uint40 reopenAt, ClosureType t);
    /// @notice ceil_days(reopenAt − closeAt) of `closureWindow` (R-07). Reverts `ClosureOpenEnded` when either end is
    ///         unknown (before the first session or past coverage).
    function closureDays(bytes32 assetId) external view returns (uint256);
    /// @notice The most restrictive active guardian restriction ((REGULAR, 0) if none).
    function restriction(bytes32 assetId) external view returns (Restriction memory);
    function assetConfig(bytes32 assetId) external view returns (AssetConfig memory);

    /// @notice onlyAuctionHouse / onlySettlement: the REOPEN of `closureId` is done. A stale closureId is a no-op.
    function markReopenComplete(bytes32 assetId, uint64 closureId) external;
    /// @notice onlyTimelock
    function listAsset(bytes32 assetId, bytes32 venue, MarketKind kind) external;
    /// @notice onlyGuardian. `s` ∈ {CLOSED, HALTED}; `until` ≤ now + 7 days; never shortens an active restriction.
    function restrict(bytes32 assetId, ClockState s, uint40 until) external;
    /// @notice onlyGuardian or timelock
    function beginCorporateAction(bytes32 assetId) external;
    /// @notice onlyTimelock. Pushes the new ratio into the OracleAdapter (capped ×10 / ÷10) and ends CORP_ACTION.
    function confirmCorporateAction(bytes32 assetId, uint256 newSharesPerToken) external;
    /// @notice onlyTimelock: replace the OracleAdapter pointer (R-21, holds no funds).
    function setOracle(address oracle_) external;
    /// @notice One-time wiring by the deployer (§7.4). Reverts on a second call.
    function initializeWiring(address oracle_, address auctionHouse_, address settlement_) external;

    function calendar() external view returns (address);
    function oracle() external view returns (address);
    function sequencerHealth() external view returns (address);
    function auctionHouse() external view returns (address);
    function settlement() external view returns (address);
    function timelock() external view returns (address);
    function guardian() external view returns (address);
}
