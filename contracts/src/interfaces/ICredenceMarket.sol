// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {MarketParams, MarketState, Position, GuardianOverlay, BellStatus} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {ICredenceMarketEvents} from "../libraries/Events.sol";

/// @title Singleton of isolated markets keyed by marketId (Build Guide §8.4, R-21). Implemented in S2.
interface ICredenceMarket is ICredenceMarketEvents, ICredenceErrors {
    // ── governance ──
    function createMarket(MarketParams calldata p) external returns (bytes32 marketId); // onlyTimelock
    function setCaps(bytes32 id, uint128 supplyCap, uint128 borrowCap) external; // onlyTimelock
    function setRiskParams(bytes32 id, uint64 maxLtv, uint64 lt, uint64 penalty) external; // onlyTimelock; lt ≥ maxLtv + 3pp
    function setFeeSplit(bytes32 id, uint16 poolBps, uint16 treasuryBps) external; // onlyTimelock; sum ≤ 3000
    function applyOverlay(bytes32 id, GuardianOverlay calldata o) external; // onlyGuardian (risk-reducing only)

    // ── senior vault ──
    function supply(bytes32 id, uint256 assets) external; // onlyVault
    function withdrawSupply(bytes32 id, uint256 assets, address to) external; // onlyVault; ≤ liquidity

    // ── borrower ──
    /// @custom:state any (no external calls except the token)
    function addCollateral(bytes32 id, address onBehalf, uint256 amount) external;
    function withdrawCollateral(bytes32 id, uint256 amount, address to) external;
    function borrow(bytes32 id, uint256 assets, address to) external;
    function borrowWithCover(bytes32 id, uint256 assets, address to, uint256 maxPremium) external;
    function buyCover(bytes32 id, uint256 maxPremium, bool addToDebt) external;
    /// @custom:state any (no oracle or engine call)
    function repay(bytes32 id, address onBehalf, uint256 assets, uint256 shares)
        external
        returns (uint256 repaid);
    function setAutoCover(bytes32 id, bool enabled) external;

    // ── keepers (permissionless, tipped) ──
    function enforceBell(bytes32 id, address[] calldata borrowers) external;
    function flagForAuction(bytes32 id, address[] calldata borrowers) external;
    function settlePositions(uint64 auctionId, address[] calldata borrowers) external;
    function claimFees(bytes32 id) external;

    // ── auction house / settlement adapter callbacks ──
    function releaseLots(uint64 auctionId) external returns (uint256 totalQty); // onlyAuctionHouse / onlySettlement
    function onAuctionCleared(uint64 auctionId, uint256 proceeds, uint256 blendedPrice) external; // onlyAuctionHouse / onlySettlement

    // ── views ──
    function marketParams(bytes32 id) external view returns (MarketParams memory);
    function marketState(bytes32 id) external view returns (MarketState memory);
    function position(bytes32 id, address b) external view returns (Position memory);
    function overlay(bytes32 id) external view returns (GuardianOverlay memory);
    function coveredCollateral(bytes32 id, uint64 closureId) external view returns (uint128);
    function debtOf(bytes32 id, address b) external view returns (uint256);
    function healthFactor(bytes32 id, address b) external view returns (uint256);
    function ltv(bytes32 id, address b) external view returns (uint256);
    function borrowLimitLtv(bytes32 id, address b) external view returns (uint256);
    function bellStatus(bytes32 id, address b)
        external
        view
        returns (BellStatus, uint256 cureRepay, uint256 cureCollateral, uint256 coverPremium);
    function liquidity(bytes32 id) external view returns (uint256);
    function borrowRate(bytes32 id) external view returns (uint256);
}
