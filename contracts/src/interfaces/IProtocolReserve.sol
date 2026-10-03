// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {IProtocolReserveEvents} from "../libraries/Events.sol";

/// @title Protocol reserve: second loss after the pool (Build Guide §8.10). Interface v1.
interface IProtocolReserve is IProtocolReserveEvents, ICredenceErrors {
    /// @notice onlyMarket. Pays min(s, balance) to the market.
    function cover(uint256 s) external returns (uint256 paid);
    /// @notice onlyMarket. Credits penalty / fee share; anything above `targetSize` flows to the treasury.
    function fund(uint256 amount) external;
    /// @notice The reserve's cash.
    function balance() external view returns (uint256);
    /// @notice The reserve's target size (loan units).
    function targetSize() external view returns (uint256);
    /// @notice onlyTimelock: the target size.
    function setTargetSize(uint256 target) external;

    // ── v1 additions ──
    /// @notice Once, by the deployer.
    function initializeWiring(address market) external;
    /// @notice onlyTimelock. Target = max(targetSize floor, bps × market.totalBorrowsAll()); 500 = 5% (§8.10).
    function setTargetBps(uint16 bps) external;
    /// @notice The target as bps of total borrows.
    function targetBps() external view returns (uint16);
    /// @notice The market it covers shortfalls for.
    function market() external view returns (address);
    /// @notice Where funding above the target overflows.
    function treasury() external view returns (address);
    /// @notice The reserve token (USDC).
    function token() external view returns (address);
    /// @notice The governance timelock.
    function timelock() external view returns (address);
}
