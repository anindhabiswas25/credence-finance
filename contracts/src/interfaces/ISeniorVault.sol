// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {ISeniorVaultEvents} from "../libraries/Events.sol";

/// @title Senior Vault: ERC-4626 + ERC-7540-style FIFO redeem queue (Build Guide §8.5, R-17). Implemented in S2.
interface ISeniorVault is IERC4626, ISeniorVaultEvents, ICredenceErrors {
    function requestRedeem(uint256 shares, address receiver) external returns (uint256 requestId);
    function claimRedeem(uint256 requestId) external returns (uint256 assets);
    function processQueue(uint256 maxRequests) external; // permissionless
    function allocate(bytes32 marketId, uint256 assets) external; // onlyAllocator, ≤ cap
    function deallocate(bytes32 marketId, uint256 assets) external; // onlyAllocator, ≤ market liquidity
    function setCap(bytes32 marketId, uint256 cap) external; // onlyTimelock
    function setSupplyQueue(bytes32[] calldata ids) external; // onlyAllocator
    function setWithdrawQueue(bytes32[] calldata ids) external; // onlyAllocator
    function idle() external view returns (uint256);
    function queueLength() external view returns (uint256);
}
