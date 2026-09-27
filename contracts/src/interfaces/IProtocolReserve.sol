// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {IProtocolReserveEvents} from "../libraries/Events.sol";

/// @title Protocol reserve: second loss after the pool (Build Guide §8.10). Implemented in S2.
interface IProtocolReserve is IProtocolReserveEvents, ICredenceErrors {
    /// @notice onlyMarket. Pays min(s, balance) to the market.
    function cover(uint256 s) external returns (uint256 paid);
    /// @notice onlyMarket. Credits penalty / fee share; anything above `targetSize` flows to the treasury.
    function fund(uint256 amount) external;
    function balance() external view returns (uint256);
    function targetSize() external view returns (uint256);
    function setTargetSize(uint256 target) external; // onlyTimelock
}
