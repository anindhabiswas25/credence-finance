// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {ITreasuryEvents} from "../libraries/Events.sol";

/// @title Protocol treasury (Build Guide §8.10). Interface v1.
interface ITreasury is ITreasuryEvents, ICredenceErrors {
    function fundTips(uint256 amount) external; // onlyTimelock
    function withdraw(address token, address to, uint256 amount) external; // onlyTimelock

    // ── v1 additions ──
    function token() external view returns (address);
    function tips() external view returns (address);
    function timelock() external view returns (address);
}
