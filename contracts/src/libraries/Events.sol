// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {
    ClockState,
    ClosureType,
    MarketKind,
    AuctionKind,
    MarketParams,
    RiskParams,
    OracleConfig,
    MarketWiring
} from "./Types.sol";

/// @title Credence event catalogue (Build Guide Appendix B). Interfaces v1 (v0 + appended events, ADR-0104).
/// @dev One events-interface per component. Each component interface inherits its events-interface, so the
///      exported ABI of `I<Component>` carries its events. Implementations emit them as `emit Name(...)`.
///      Events not fully specified in Appendix B ("…") are defined here and are frozen with v0.

interface ICalendarStoreEvents {
    event SessionsAppended(bytes32 indexed venue, uint256 fromIndex, uint256 count, uint40 coverageEnd);
}

interface IAssetClockEvents {
    event StateChanged(bytes32 indexed asset, ClockState from, ClockState to, uint64 closureId);
    event ClosureStarted(
        bytes32 indexed asset,
        uint64 closureId,
        uint64 venueEpoch,
        ClosureType t,
        uint256 refPrice,
        uint40 reopenAt
    );
    event OpenPrint(bytes32 indexed asset, uint64 closureId, uint256 price, bool fallbackUsed);
    event ReopenComplete(bytes32 indexed asset, uint64 closureId);
    event Restricted(bytes32 indexed asset, ClockState s, uint40 until);
    event PhaseExtended(uint40 gap);
    /// @dev Not in Appendix B; added in v0.
    event AssetListed(bytes32 indexed asset, bytes32 venue, MarketKind kind);
    event ReferenceUpdated(bytes32 indexed asset, uint64 closureId, uint256 refPrice, uint40 refTime);
    event CorporateActionBegun(bytes32 indexed asset, uint64 closureId);
    event CorporateActionConfirmed(bytes32 indexed asset, uint256 sharesPerToken);
    event WiringInitialized(
        address oracle, address sequencerHealth, address auctionHouse, address settlement
    );
    event OracleSet(address oracle);
}

interface IPriceFeedEvents {
    /// @dev v1 (R-25): `marketStatus` (FeedMarketStatus) appended, so `price_point.status` can be indexed.
    ///      The topic0 differs from v0's 5-argument event.
    event ReportAccepted(
        bytes32 indexed asset, uint8 kind, uint256 price, uint40 observedAt, uint64 seq, uint8 marketStatus
    );
    event CommitteeChanged(address[] signers, uint8 threshold);
}

interface IOracleAdapterEvents {
    event AssetSourcesSet(bytes32 indexed asset, OracleConfig config);
    event SharesPerTokenChanged(bytes32 indexed asset, uint256 oldValue, uint256 newValue);
    event ClockSet(address clock);
}

interface ISequencerHealthEvents {
    event ClockSet(address clock);
}

interface ICredenceMarketEvents {
    event MarketCreated(bytes32 indexed id, MarketParams p);
    event Accrued(bytes32 indexed id, uint256 interest, uint256 poolFee, uint256 treasuryFee);
    event CollateralAdded(bytes32 indexed id, address indexed owner, address caller, uint256 amt);
    event CollateralWithdrawn(bytes32 indexed id, address indexed owner, address to, uint256 amt);
    event Borrow(bytes32 indexed id, address indexed owner, address to, uint256 assets, uint256 shares);
    event Repay(bytes32 indexed id, address indexed owner, address payer, uint256 assets, uint256 shares);
    event CoverBought(
        bytes32 indexed id,
        address indexed owner,
        uint64 closureId,
        uint64 policyId,
        uint256 premium,
        bool addedToDebt,
        bool auto_
    );
    event BellEnforced(bytes32 indexed id, address indexed owner, uint64 closureId, uint8 outcome);
    event Flagged(bytes32 indexed id, address indexed owner, uint64 auctionId, AuctionKind kind);
    event LotReleased(uint64 indexed auctionId, address indexed owner, uint256 qty);
    /// @dev v2 (ADR-0110): replaces v1's `PositionSettled(auctionId, owner, proceeds, penalty, repaid, refund)`.
    event PositionSettled(
        bytes32 indexed marketId,
        address indexed borrower,
        uint64 indexed auctionId,
        uint256 collateralSold,
        uint256 proceeds,
        uint256 penalty,
        uint256 shortfall,
        uint256 refund,
        uint256 debtAfter
    );
    event Shortfall(
        bytes32 indexed id,
        address indexed owner,
        uint256 s,
        uint256 paidPool,
        uint256 paidReserve,
        uint256 seniorLoss
    );
    event FeesClaimed(bytes32 indexed id, uint256 pool, uint256 treasury);
    event CapsSet(bytes32 indexed id, uint128 supplyCap, uint128 borrowCap);
    event RiskParamsSet(bytes32 indexed id, uint64 maxLtv, uint64 lt, uint64 penalty);
    event FeeSplitSet(bytes32 indexed id, uint16 poolBps, uint16 treasuryBps);
    event OverlayApplied(
        bytes32 indexed id, uint64 haircut, uint40 haircutUntil, bool borrowPaused, bool coverPaused
    );
    event AutoCoverSet(bytes32 indexed id, address indexed owner, bool enabled);
    // v1 additions (S2)
    event MarketWired(MarketWiring w);
    event EngineSet(address engine);
    event OracleSet(address oracle);
    event ReserveFeeShareSet(uint16 bps);
    event LotsReleased(uint64 indexed auctionId, uint256 totalQty, uint256 positions);
    event LotCleared(uint64 indexed auctionId, uint256 proceeds, uint256 blendedPrice);
    event Dequeued(bytes32 indexed id, address indexed owner, uint64 auctionId);
    // v2 additions (S3)
    event AutoCoverApplied(
        bytes32 indexed marketId,
        address indexed borrower,
        uint64 closureId,
        uint256 premium,
        uint256 debtAfter
    );
}

interface ISeniorVaultEvents {
    event RedeemRequested(uint256 indexed id, address owner, uint256 shares);
    event RedeemProcessed(uint256 indexed id, uint256 assets);
    event RedeemClaimed(uint256 indexed id, address receiver, uint256 assets);
    event Allocated(bytes32 indexed id, int256 delta);
    event CapSet(bytes32 indexed id, uint256 cap);
    event SupplyQueueSet(bytes32[] ids);
    event WithdrawQueueSet(bytes32[] ids);
    // v1 additions (S2)
    event AllocatorSet(address allocator);
    // S5 (QA-11, ADR-0117)
    event MarketDisabled(bytes32 indexed id);
}

/// @dev v2 (S3, ADR-0110): every pool state change the indexer projects carries its result, so handlers need no
///      state reads (Guide §10.3).
interface IUnderwriterPoolEvents {
    event EpochOpened(
        uint64 indexed epochId,
        bytes32 venue,
        uint40 bellWindowAt,
        uint40 bellAt,
        uint40 closeAt,
        uint40 reopenAt,
        uint256 navBefore,
        uint256 withdrawSharesQueued
    );
    event EpochSnapshotted(uint64 indexed epochId, uint256 equityAtRisk, uint256 worstLoss);
    event EpochSettled(
        uint64 indexed epochId,
        uint256 premiums,
        uint256 riskFees,
        uint256 penalties,
        uint256 bonds,
        int256 backstopPnl,
        uint256 lossesPaid,
        uint256 pendingLossReserve,
        uint256 navAfter,
        uint256 sharePriceAfter
    );
    event EpochQueuesProcessed(
        uint64 indexed epochId,
        uint256 sharesBurned,
        uint256 assetsReserved,
        uint256 depositAssets,
        uint256 sharesMinted
    );
    event CoverWritten(
        uint64 indexed policyId,
        bytes32 indexed marketId,
        address indexed borrower,
        uint64 epochId,
        bytes32 assetId,
        uint256 premium,
        uint256 uAfter,
        uint256 worstLoss
    );
    event Deposited(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event DepositQueued(uint64 indexed epochId, address indexed owner, uint256 assets);
    event DepositClaimed(uint64 indexed epochId, address indexed owner, uint256 shares);
    event WithdrawRequested(uint64 indexed epochId, address indexed owner, uint256 shares);
    event WithdrawClaimed(uint64 indexed epochId, address indexed owner, uint256 assets, uint256 stillOwed);
    event ShortfallPaid(uint64 indexed epochId, uint256 requested, uint256 paid);
    event RiskFeeCredited(uint64 indexed epochId, uint256 assets);
    event PenaltyCredited(uint64 indexed epochId, uint256 assets);
    event BondCredited(uint64 indexed epochId, uint256 assets);
    event BackstopBought(
        uint64 indexed epochId, bytes32 indexed assetId, uint256 qty, uint256 price, uint256 paid
    );
    event InventoryListed(bytes32 indexed assetId, uint64 gdaId, uint256 qty);
    event InventorySold(bytes32 indexed assetId, uint256 qty, uint256 proceeds, int256 realisedPnl);
    event LossReserveReleased(uint64 indexed epochId, bytes32 indexed assetId, uint256 amount);
    // v3 (S4, ADR-0111): NAV-stack pool advances (fallbackAdvance) and their fund redemptions
    event RedemptionRequested(
        uint64 indexed epochId,
        uint256 indexed requestId,
        bytes32 indexed marketId,
        address fund,
        uint256 qty,
        uint256 cost
    );
    event RedemptionClaimed(uint64 indexed epochId, uint256 indexed requestId, uint256 assets, int256 pnl);
    event ConcentrationLimitSet(uint64 maxAssetShare);
}

/// @dev v2 (S3, ADR-0110): see IUnderwriterPoolEvents.
interface IAuctionHouseEvents {
    event AuctionCreated(
        uint64 indexed id,
        AuctionKind kind,
        bytes32 indexed marketId,
        bytes32 assetId,
        uint64 closureId,
        uint64 venueEpoch,
        uint32 tranche,
        uint40[4] deadlines
    );
    event LotsFixed(uint64 indexed id, uint256 lot, uint256 reserve, uint256 positions);
    event BidCommitted(
        uint64 indexed id, address indexed bidder, bytes32 commitment, uint256 maxNotional, uint256 bond
    );
    event BidRevealed(uint64 indexed id, address indexed bidder, uint256 qty, uint256 price, uint256 escrow);
    event BidPlaced(uint64 indexed id, address indexed bidder, uint256 qty, uint256 price, uint256 escrow);
    event AuctionCleared(
        uint64 indexed id,
        uint256 pStar,
        uint256 filled,
        uint256 qPool,
        uint256 proceeds,
        uint256 blendedPrice,
        uint256 reserve
    );
    event BondForfeited(uint64 indexed id, address indexed bidder, uint256 bond);
    event Claimed(uint64 indexed id, address indexed bidder, uint256 tokens, uint256 refund);
    event LotSettled(uint64 indexed id);
    event ReopenCompleted(bytes32 indexed assetId, uint64 closureId, uint64 venueEpoch);
    event GdaStarted(
        uint64 indexed gdaId,
        bytes32 indexed assetId,
        address token,
        uint256 qty,
        uint256 k,
        uint256 decay,
        uint256 emissionPerSec,
        uint40 start
    );
    event GdaBought(uint64 indexed gdaId, address indexed buyer, uint256 qty, uint256 cost);
    event GdaClosed(uint64 indexed gdaId, uint256 unsold);
    event TimingsSet(AuctionKind indexed kind, uint40[4] offsets);
    event LimitsSet(uint16 maxBids, uint128 minNotional, uint16 bondBps);
}

interface ISettlementEvents {
    event SettlementOpened(
        uint64 indexed id,
        bytes32 indexed marketId,
        address venue,
        uint256 qty,
        uint256 floorPrice,
        uint40 endsAt
    );
    event SolverBid(uint64 indexed id, address indexed solver, uint256 price);
    event SettlementFilled(uint64 indexed id, address indexed solver, uint256 qty, uint256 proceeds);
    event FallbackAdvanced(uint64 indexed id, uint256 qty, uint256 price, uint256 requestId);
    // v3 (S4, ADR-0111)
    /// @notice Emitted by `finalize` for every settlement: filled by a solver or advanced by the pool.
    event SettlementFinalized(
        uint64 indexed id, bool filled, address solver, uint256 price, uint256 proceeds, uint256 requestId
    );
    /// @notice Every position of the settlement's lot was settled in the market.
    event SettlementPositionsSettled(uint64 indexed id, uint256 positions);
    event NavReopenCompleted(bytes32 indexed assetId, uint64 closureId);
    event VenuesSet(address[] venues);
    event WindowSet(uint40 window);
    // SolverAuction
    event SolverWindowOpened(
        uint64 indexed id, address token, uint256 qty, uint256 floorPrice, uint40 endsAt
    );
    event SolverRefunded(uint64 indexed id, address indexed solver, uint256 amount, bool pushed);
    event SolverSet(address indexed solver, bool allowed);
    event RefundWithdrawn(address indexed solver, uint256 amount);
}

interface IRiskEngineEvents {
    event ScenarioSetUpdated(bytes32 asset, uint8 closureType, bytes32 hash, uint32 n);
    event SigmaUpdated(bytes32 asset, uint8 closureType, uint256 sigma);
    event ParamsUpdated(RiskParams p);
    event JointColumnUpdated(bytes32 asset, bytes32 hash);
    event SigmaFloorSet(bytes32 asset, uint8 closureType, uint256 floor);
}

interface ISigmaOracleEvents {
    event SigmaSubmitted(
        bytes32 indexed asset, uint8 closureType, uint256 sigma, uint32 asOfDay, uint64 nonce
    );
    event CommitteeChanged(address[] signers, uint8 threshold);
}

interface IKeeperTipsEvents {
    event TipPaid(address indexed keeper, uint8 indexed job, uint256 amount);
    event TipSkipped(address indexed keeper, uint8 indexed job, uint256 owed);
    event TipSet(uint8 indexed job, uint256 amount);
    event PayerSet(address payer, bool allowed);
}

interface ITreasuryEvents {
    event TipsFunded(uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
}

interface IProtocolReserveEvents {
    event ReserveCovered(uint256 requested, uint256 paid);
    event ReserveFunded(uint256 amount, uint256 overflowToTreasury);
    event TargetSizeSet(uint256 target);
    // v1 additions (S2)
    event TargetBpsSet(uint16 bps);
    event MarketSet(address market);
}

interface IGuardianEvents {
    /// @dev Appendix B names this `BorrowPaused`, which clashes with the Appendix C error of the same name.
    event BorrowPausedByGuardian(bytes32 id);
    event UnpauseScheduled(bytes32 id, uint40 executableAt);
    event BorrowUnpaused(bytes32 id);
    event HaircutRaised(bytes32 id, uint64 bps, uint40 until);
    event CoverPaused(address target);
    event CoverUnpaused(address target);
    event AssetHalted(bytes32 asset, uint40 until);
    event ClosedExtended(bytes32 asset, uint40 until);
    // v1 additions (S2)
    event CoverUnpauseScheduled(address target, uint40 executableAt);
    event GuardianWired(address[] markets, address clock);
}

interface ICollateralTokenEvents {
    event RatioChanged(uint256 oldRatio, uint256 newRatio);
    event FrozenSet(bool frozen);
    event ComplianceSet(address compliance);
    event IssuerTransferred(address indexed previousIssuer, address indexed newIssuer);
    event MinterSet(address indexed minter, uint256 cap);
}

interface INavFundEvents {
    event NavPublished(uint256 navPerShare, uint40 at);
    event RedemptionsGatedSet(bool gated);
    event RedeemRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 shares
    );
    event RedeemFulfilled(uint256 indexed requestId, uint256 shares, uint256 assets);
    event Redeemed(uint256 indexed requestId, address indexed receiver, uint256 assets);
}

interface IComplianceEvents {
    event AllowlistSet(address indexed account, bool allowed);
    event OperatorSet(address indexed operator, bool allowed);
}

interface IFaucetEvents {
    event Dripped(address indexed to, address indexed token, uint256 amount);
    event DripConfigured(address indexed token, uint256 amount, bool requiresAllowlist);
}
