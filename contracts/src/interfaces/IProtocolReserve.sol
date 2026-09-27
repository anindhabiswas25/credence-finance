// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {IProtocolReserveEvents} from "../libraries/Events.sol";

/// @title Protocol reserve: second loss after the pool (Build Guide §8.10). Interface v1.
interface IProtocolReserve is IProtocolReserveEvents, ICredenceErrors {
    /// @notice onlyMarket. Pays min(s, balance) to the market.
    function cover(uint256 s) external returns (uint256 paid);
    /// @notice onlyMarket. Credits penalty / fee share; anything above `targetSize` flows to the treasury.
    function fund(uint256 amount) external;
    function balance() external view returns (uint256);
    function targetSize() external view returns (uint256);
    function setTargetSize(uint256 target) external; // onlyTimelock

    // ── v1 additions ──
    /// @notice Once, by the deployer.
    function initializeWiring(address market) external;
    /// @notice onlyTimelock. Target = max(targetSize floor, bps × market.totalBorrowsAll()); 500 = 5% (§8.10).
    function setTargetBps(uint16 bps) external;
    function targetBps() external view returns (uint16);
    function market() external view returns (address);
    function treasury() external view returns (address);
    function token() external view returns (address);
    function timelock() external view returns (address);
}
