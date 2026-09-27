// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {IFaucetEvents} from "../libraries/Events.sol";

/// @title Testnet faucet with a 24-hour rate limit per (address, token) (Build Guide §8.12).
interface IFaucet is IFaucetEvents, ICredenceErrors {
    function drip(address token) external returns (uint256 amount);
    function configure(address token, uint256 amount, bool requiresAllowlist) external; // onlyOwner
    function nextDripAt(address account, address token) external view returns (uint40);
    function dripAmount(address token) external view returns (uint256);
    function COOLDOWN() external view returns (uint40);
}
