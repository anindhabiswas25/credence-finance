// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ERC-8056 Scaled UI Amount, with its required pending-multiplier extension (ADR-0119).
/// @notice Robinhood Stock Tokens implement it: underlying shares = raw amount × uiMultiplier / 1e18. A corporate action
///         (dividend reinvestment, split, reverse split) changes the multiplier, never the raw balances. A scheduled
///         update is readable before it takes effect at `effectiveAt` (`block.timestamp >= effectiveAt`).
interface IScaledUIAmount {
    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);
    event UIMultiplierUpdateCancelled(uint256 cancelledMultiplier, uint256 cancelledEffectiveAt);

    /// @notice The active multiplier, WAD (1e18 = 1.0).
    function uiMultiplier() external view returns (uint256);
    /// @notice The last scheduled multiplier (active once `block.timestamp >= effectiveAt()`), WAD; 0 if none.
    function newUIMultiplier() external view returns (uint256);
    /// @notice When `newUIMultiplier` takes effect; 0 if none was scheduled.
    function effectiveAt() external view returns (uint256);
}
