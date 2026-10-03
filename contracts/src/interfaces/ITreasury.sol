// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {ITreasuryEvents} from "../libraries/Events.sol";

/// @title Protocol treasury (Build Guide §8.10). Interface v1.
interface ITreasury is ITreasuryEvents, ICredenceErrors {
    /// @notice onlyTimelock: move `amount` to the KeeperTips budget.
    function fundTips(uint256 amount) external;
    /// @notice onlyTimelock: send treasury funds.
    function withdraw(address token, address to, uint256 amount) external;

    // ── v1 additions ──
    /// @notice The treasury token (USDC).
    function token() external view returns (address);
    /// @notice The KeeperTips contract it funds.
    function tips() external view returns (address);
    /// @notice The governance timelock.
    function timelock() external view returns (address);
}
