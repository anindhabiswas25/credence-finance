// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {IFaucetEvents} from "../libraries/Events.sol";

/// @title Testnet faucet with a 24-hour rate limit per (address, token) (Build Guide §8.12).
interface IFaucet is IFaucetEvents, ICredenceErrors {
    /// @notice Send the caller the token's drip amount (24-hour cooldown; allowlist if required).
    function drip(address token) external returns (uint256 amount);
    /// @notice onlyOwner: a token's drip amount and whether the caller must be allowlisted.
    function configure(address token, uint256 amount, bool requiresAllowlist) external;
    /// @notice When `account` may next drip `token`.
    function nextDripAt(address account, address token) external view returns (uint40);
    /// @notice The drip amount of a token.
    function dripAmount(address token) external view returns (uint256);
    /// @notice Cooldown between drips per account and token (24 hours).
    function COOLDOWN() external view returns (uint40);
}
