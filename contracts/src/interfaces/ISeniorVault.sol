// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {RedeemRequest} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {ISeniorVaultEvents} from "../libraries/Events.sol";

/// @title Senior Vault: ERC-4626 + ERC-7540-style FIFO redeem queue (Build Guide §8.5, R-17). Interface v1.
interface ISeniorVault is IERC4626, ISeniorVaultEvents, ICredenceErrors {
    /// @notice Escrow shares in the FIFO redemption queue (R-17) for what idle liquidity cannot pay now.
    function requestRedeem(uint256 shares, address receiver) external returns (uint256 requestId);
    /// @notice Pay out a processed redemption request.
    function claimRedeem(uint256 requestId) external returns (uint256 assets);
    /// @notice Permissionless: process up to `maxRequests` queued redemptions at the current share price as
    ///        liquidity allows.
    function processQueue(uint256 maxRequests) external;
    /// @notice onlyAllocator: supply idle assets to a market (≤ its cap).
    function allocate(bytes32 marketId, uint256 assets) external;
    /// @notice onlyAllocator: withdraw supply from a market (≤ its liquidity).
    function deallocate(bytes32 marketId, uint256 assets) external;
    /// @notice onlyTimelock: a market's allocation cap.
    function setCap(bytes32 marketId, uint256 cap) external;
    /// @notice onlyAllocator: the order deposits are supplied in.
    function setSupplyQueue(bytes32[] calldata ids) external;
    /// @notice onlyAllocator: the order withdrawals pull from.
    function setWithdrawQueue(bytes32[] calldata ids) external;
    /// @notice Assets held by the vault and not supplied.
    function idle() external view returns (uint256);
    /// @notice Unprocessed redemption requests.
    function queueLength() external view returns (uint256);

    // ── v1 additions ──
    /// @notice onlyTimelock. The allocator Safe (the timelock is always an allocator too).
    function setAllocator(address allocator) external;
    /// @notice The allocator role.
    function allocator() external view returns (address);
    /// @notice The governance timelock.
    function timelock() external view returns (address);
    /// @notice The CredenceMarket it supplies.
    function market() external view returns (address);
    /// @notice A market's allocation cap.
    function cap(bytes32 marketId) external view returns (uint256);
    /// @notice The supply order.
    function supplyQueue() external view returns (bytes32[] memory);
    /// @notice The withdraw order.
    function withdrawQueue() external view returns (bytes32[] memory);
    /// @notice One redemption request.
    function redeemRequest(uint256 requestId) external view returns (RedeemRequest memory);
    /// @notice Id of the oldest unprocessed request (== nextRequestId when the queue is empty).
    function queueHead() external view returns (uint256);
    /// @notice The id the next redemption request will get.
    function nextRequestId() external view returns (uint256);
    /// @notice Shares escrowed by unprocessed requests.
    function pendingRedeemShares() external view returns (uint256);
    /// @notice Assets set aside for processed, unclaimed requests (excluded from totalAssets).
    function claimableAssets() external view returns (uint256);

    // ── S5 additions (QA-11, ADR-0117) ──
    /// @notice onlyTimelock. Remove a market with nothing supplied from the vault: its cap, its slot in the
    ///         MAX_QUEUE list and both queues. Reverts `MarketNotEmpty` while the market holds any supply.
    ///         `setCap` enables it again.
    function disable(bytes32 marketId) external;
    /// @notice The enabled markets (every market with a cap that was not disabled since).
    function enabledMarkets() external view returns (bytes32[] memory);
}
