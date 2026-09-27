// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {IGuardianEvents} from "../libraries/Events.sol";

/// @title Guardian: can only make the protocol safer (Build Guide §8.11). Implemented in S2.
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
}
