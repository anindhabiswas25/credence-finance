// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoverRequest, Epoch} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {IUnderwriterPoolEvents} from "../libraries/Events.sol";

/// @title Underwriter Pool: junior first-loss capital, ERC-20 shares (Build Guide §8.6). Implemented in S3.
interface IUnderwriterPool is IERC20, IUnderwriterPoolEvents, ICredenceErrors {
    // underwriters
    function deposit(uint256 assets, address receiver) external returns (uint256 sharesOrTicket);
    function requestWithdraw(uint256 shares) external returns (uint64 epochId);
    function claimWithdraw(uint64 epochId) external returns (uint256 assets);
    function claimDeposit(uint64 epochId) external returns (uint256 shares);

    // cover (onlyMarket)
    function previewCover(CoverRequest calldata r) external view returns (uint256 premium, uint256 uAfter);
    function writeCover(CoverRequest calldata r, uint256 premium) external returns (uint64 policyId);

    // income (onlyMarket / onlyAuctionHouse)
    function creditRiskFee(uint256 assets) external;
    function creditPenalty(uint256 assets) external;
    function creditBond(uint256 assets) external;

    // losses and backstop (onlyMarket / onlyAuctionHouse / onlySettlement)
    function payShortfall(uint256 s) external returns (uint256 paid);
    function backstopBuy(bytes32 assetId, address token, uint256 qty, uint256 price) external;
    function fallbackAdvance(bytes32 marketId, uint256 qty, uint256 price)
        external
        returns (uint256 requestId);

    // lifecycle (permissionless, tipped)
    function openEpoch(bytes32 venue) external;
    function snapshotEpoch(uint64 epochId) external;
    function settleEpoch(uint64 epochId) external;

    // views
    function nav() external view returns (uint256);
    function sharePrice() external view returns (uint256);
    function utilisation(uint64 epochId) external view returns (uint256);
    function capacityHeadroom(uint64 epochId) external view returns (uint256);
    function epoch(uint64 epochId) external view returns (Epoch memory);
    function currentEpoch(bytes32 venue) external view returns (uint64);
}
