// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {ITreasuryEvents} from "../libraries/Events.sol";

/// @title Protocol treasury (Build Guide §8.10). Implemented in S2.
interface ITreasury is ITreasuryEvents, ICredenceErrors {
    function fundTips(uint256 amount) external; // onlyTimelock
    function withdraw(address token, address to, uint256 amount) external; // onlyTimelock
}
