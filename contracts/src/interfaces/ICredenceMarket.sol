// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {
    MarketParams,
    MarketState,
    Position,
    GuardianOverlay,
    BellStatus,
    MarketWiring,
    LotInfo
} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {ICredenceMarketEvents} from "../libraries/Events.sol";

/// @title Singleton of isolated markets keyed by marketId (Build Guide §8.4, R-21). Interface v1, implemented in S2.
/// @dev v1 additions are marked `v1`; every v0 selector is unchanged (ADR-0104).
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

    // ── v1 additions ──
    /// @notice Once, by the deployer (Wire step, §7.4). Reverts `AlreadyWired` on a second call.
    function initializeWiring(MarketWiring calldata w) external;
    /// @notice onlyTimelock (R-21: the engine holds no funds and is replaceable).
    function setEngine(address engine) external;
    /// @notice onlyTimelock (R-21).
    function setOracle(address oracle) external;
    /// @notice onlyTimelock. Share of the treasury fee sent to the ProtocolReserve in `claimFees` (§8.10), ≤ 10,000.
    function setReserveFeeShare(uint16 bps) external;
    function wiring() external view returns (MarketWiring memory);
    function timelock() external view returns (address);
    function guardian() external view returns (address);
    function reserveFeeShareBps() external view returns (uint16);
    /// @notice Every created market id, in creation order (for indexers).
    function marketIds() external view returns (bytes32[] memory);
    function lotInfo(uint64 auctionId) external view returns (LotInfo memory);
    function lotBorrowers(uint64 auctionId) external view returns (address[] memory);
    /// @notice x_i of `b` in the lot (0 before `releaseLots`), and whether it has been settled.
    function lotPosition(uint64 auctionId, address b) external view returns (uint128 qty, bool settled);
    /// @notice D × (1 + r_b × days/365) for the upcoming closure (R-08), with interest accrued to now.
    function projectedDebt(bytes32 id, address b) external view returns (uint256);
    /// @notice The closureId that cover bought now would protect (closureInfo.closureId + 1).
    function upcomingClosureId(bytes32 id) external view returns (uint64);
    /// @notice Σ totalBorrowAssets over all markets (ProtocolReserve target, §8.10).
    function totalBorrowsAll() external view returns (uint256);
}
