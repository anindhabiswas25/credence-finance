// SPDX-License-Identifier: MIT
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
    /// @notice onlyTimelock: list an isolated market; marketId = keccak256(loanToken, collateralToken,
    ///        assetId).
    function createMarket(MarketParams calldata p) external returns (bytes32 marketId);
    /// @notice onlyTimelock: a market's supply and borrow caps (loan units).
    function setCaps(bytes32 id, uint128 supplyCap, uint128 borrowCap) external;
    /// @notice onlyTimelock: max LTV, liquidation threshold (≥ max LTV + 3 pp) and penalty.
    function setRiskParams(bytes32 id, uint64 maxLtv, uint64 lt, uint64 penalty) external;
    /// @notice onlyTimelock: the pool's and the treasury's interest shares (sum ≤ 3,000 bps).
    function setFeeSplit(bytes32 id, uint16 poolBps, uint16 treasuryBps) external;
    /// @notice onlyGuardian: a risk-reducing overlay (haircut, borrow pause, cover pause).
    function applyOverlay(bytes32 id, GuardianOverlay calldata o) external;

    // ── senior vault ──
    /// @notice onlyVault: supply assets the vault has transferred.
    function supply(bytes32 id, uint256 assets) external;
    /// @notice onlyVault: take back supplied assets (≤ the market's liquidity).
    function withdrawSupply(bytes32 id, uint256 assets, address to) external;

    // ── borrower ──
    /// @custom:state any (no external calls except the token)
    function addCollateral(bytes32 id, address onBehalf, uint256 amount) external;
    /// @notice Withdraw collateral while the position stays within the state's limit (REGULAR: HF ≥ 1.05).
    function withdrawCollateral(bytes32 id, uint256 amount, address to) external;
    /// @notice Borrow within the borrow limit of the clock state (max LTV, or the safe LTV near a closure,
    ///        R-08).
    function borrow(bytes32 id, uint256 assets, address to) external;
    /// @notice Borrow above the safe LTV in the Bell window and buy Gap Cover for the upcoming closure in one
    ///        call.
    function borrowWithCover(bytes32 id, uint256 assets, address to, uint256 maxPremium) external;
    /// @notice Buy Gap Cover for the upcoming closure (premium ≤ maxPremium), paid from the wallet or added
    ///        to debt.
    function buyCover(bytes32 id, uint256 maxPremium, bool addToDebt) external;
    /// @custom:state any (no oracle or engine call)
    function repay(bytes32 id, address onBehalf, uint256 assets, uint256 shares)
        external
        returns (uint256 repaid);
    /// @notice Opt in or out of auto-cover at the Bell (on by default).
    function setAutoCover(bytes32 id, bool enabled) external;

    // ── keepers (permissionless, tipped) ──
    /// @notice Permissionless, tipped, after the Bell deadline: each listed NEEDS_ACTION position is
    ///        auto-covered or put into a pre-close sale.
    function enforceBell(bytes32 id, address[] calldata borrowers) external;
    /// @notice Permissionless, tipped: queue every listed HF < 1 position (EXTENDED: uncovered HF < 0.92)
    ///        into the lot of the state's auction kind.
    function flagForAuction(bytes32 id, address[] calldata borrowers) external;
    /// @notice Permissionless, tipped: F-4.5d for positions of a cleared lot (penalty, repayment, refund,
    ///        shortfall waterfall).
    function settlePositions(uint64 auctionId, address[] calldata borrowers) external;
    /// @notice Permissionless: sweep the pool's and treasury's fee receivables to cash as liquidity allows
    ///        (R-09).
    function claimFees(bytes32 id) external;

    // ── auction house / settlement adapter callbacks ──
    /// @notice onlyAuctionHouse / onlySettlement: size every queued position (F-4.5a/b) and move Σx to the
    ///        caller.
    function releaseLots(uint64 auctionId) external returns (uint256 totalQty);
    /// @notice onlyAuctionHouse / onlySettlement: pull the lot's proceeds and record p̄.
    function onAuctionCleared(uint64 auctionId, uint256 proceeds, uint256 blendedPrice) external;
    /// @notice v2: onlyAuctionHouse / onlySettlement. An unreleased lot that can no longer be fixed: every queued
    ///         borrower leaves it (`Dequeued`), untouched, and it counts as released with 0.
    function cancelLot(uint64 auctionId) external;

    // ── views ──
    /// @notice A market's parameters (reverts MarketNotFound for an unknown id).
    function marketParams(bytes32 id) external view returns (MarketParams memory);
    /// @notice A market's accounting (supply, borrows, fee receivables, collateral).
    function marketState(bytes32 id) external view returns (MarketState memory);
    /// @notice One borrower's position.
    function position(bytes32 id, address b) external view returns (Position memory);
    /// @notice A market's guardian overlay (bytes32(0) = the global one).
    function overlay(bytes32 id) external view returns (GuardianOverlay memory);
    /// @notice Collateral covered for a closure (the pool's capacity input).
    function coveredCollateral(bytes32 id, uint64 closureId) external view returns (uint128);
    /// @notice A borrower's debt with interest accrued to now (rounded up).
    function debtOf(bytes32 id, address b) external view returns (uint256);
    /// @notice HF = collateral value × LT / debt at the valuation price (rounded down).
    function healthFactor(bytes32 id, address b) external view returns (uint256);
    /// @notice Debt / collateral value (rounded up).
    function ltv(bytes32 id, address b) external view returns (uint256);
    /// @notice The LTV limit that applies to a new borrow right now.
    function borrowLimitLtv(bytes32 id, address b) external view returns (uint256);
    /// @notice Bell Check for the upcoming closure: SAFE / NEEDS_ACTION / COVERED, the cures (repay,
    ///        collateral) and the cover premium.
    function bellStatus(bytes32 id, address b)
        external
        view
        returns (BellStatus, uint256 cureRepay, uint256 cureCollateral, uint256 coverPremium);
    /// @notice Cash the market can lend or pay out: supply + fee receivables − borrows.
    function liquidity(bytes32 id) external view returns (uint256);
    /// @notice Current borrow rate (WAD per year) from the kinked model.
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
    /// @notice The contract wiring set at deployment.
    function wiring() external view returns (MarketWiring memory);
    /// @notice The governance timelock.
    function timelock() external view returns (address);
    /// @notice The CredenceGuardian.
    function guardian() external view returns (address);
    /// @notice Share of the treasury fee routed to the ProtocolReserve in `claimFees`.
    function reserveFeeShareBps() external view returns (uint16);
    /// @notice Every created market id, in creation order (for indexers).
    function marketIds() external view returns (bytes32[] memory);
    /// @notice A liquidation lot's state (quantity, proceeds, p̄, settlement progress).
    function lotInfo(uint64 auctionId) external view returns (LotInfo memory);
    /// @notice The borrowers in a lot.
    function lotBorrowers(uint64 auctionId) external view returns (address[] memory);
    /// @notice x_i of `b` in the lot (0 before `releaseLots`), and whether it has been settled.
    function lotPosition(uint64 auctionId, address b) external view returns (uint128 qty, bool settled);
    /// @notice D × (1 + r_b × days/365) for the upcoming closure (R-08), with interest accrued to now.
    function projectedDebt(bytes32 id, address b) external view returns (uint256);
    /// @notice The closureId that cover bought now would protect (closureInfo.closureId + 1).
    function upcomingClosureId(bytes32 id) external view returns (uint64);
    /// @notice Σ totalBorrowAssets over all markets (ProtocolReserve target, §8.10).
    function totalBorrowsAll() external view returns (uint256);
    /// @notice v2 (S3): Σ over all markets of the pool's fee receivable with interest accrued to now (R-09); the pool
    ///         counts it in its NAV.
    function poolFeeReceivable() external view returns (uint256);
    /// @notice v2 (S3): the pool's capacity input for one market (§9.5): the value at V_live of the collateral not
    ///         covered for the upcoming closure, and the safe LTV of that closure (with the haircut applied).
    function uncoveredExposure(bytes32 id)
        external
        view
        returns (bytes32 assetId, uint8 closureType, uint256 uncoveredValue, uint256 safeLtv);
}
