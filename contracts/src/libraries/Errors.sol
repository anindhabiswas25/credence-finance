// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClockState} from "./Types.sol";

/// @title Credence error catalogue (Build Guide Appendix C). Interfaces v1 (v0 + appended errors).
/// @dev Every Credence interface inherits this, so every ABI can decode every Credence revert.
///      Custom errors only; no revert strings anywhere in the protocol.
interface ICredenceErrors {
    // ── access / wiring ──
    error Unauthorized();
    error AlreadyWired();
    error NotWired();
    error ZeroAddress();
    error InvalidParam();
    error ArrayLengthMismatch();

    // ── clock permission matrix (Appendix C) ──
    error ActionNotAllowedInState(uint8 action, ClockState s);

    // ── calendar ──
    error EmptySessions();
    error SessionNotIncreasing(uint256 index);
    error SessionOutOfOrder(uint256 index);
    error SessionIndexOutOfRange(uint256 index);
    error InvalidClosureType(uint256 index);
    error UnknownVenue(bytes32 venue);

    // ── asset clock ──
    error AssetNotListed(bytes32 assetId);
    error AssetAlreadyListed(bytes32 assetId);
    error InvalidRestriction(ClockState s);
    error RestrictionNotTighter(ClockState s, uint40 until, uint40 current);
    error RestrictionTooLong(uint40 until, uint40 maxUntil);
    error NoCalendarCoverage(bytes32 venue);
    error WrongClosure(uint64 current, uint64 given);
    error ReopenNotPending(bytes32 assetId);
    error CorporateActionActive(bytes32 assetId);
    error CorporateActionNotActive(bytes32 assetId);
    error ClosureOpenEnded(bytes32 assetId);

    // ── price feed ──
    error EmptyReports();
    error StaleReport(bytes32 assetId, uint64 seq, uint64 storedSeq);
    error NotEnoughSigners(uint256 got, uint256 need);
    error SignersNotSorted();
    error UnknownSigner(address signer);
    error InvalidSignature();
    error ReportFromFuture(uint40 observedAt, uint256 blockTime);
    error ZeroPrice();
    error InvalidReportKind(uint8 kind);
    error InvalidMarketStatus(uint8 status);
    error InvalidCommittee();

    // ── oracle adapter ──
    error NoPrice(bytes32 assetId);
    error NoReferencePrice(bytes32 assetId);
    error SharesPerTokenChangeTooLarge(uint256 current, uint256 proposed);

    // ── market (S2) ──
    error MarketNotFound(bytes32 id);
    error MarketExists(bytes32 id);
    error InvalidRiskParams();
    error LtvAboveLimit(uint256 ltv, uint256 limit);
    error LtvAboveCoverable(uint256 ltv, uint256 max);
    error CoverWindowClosed();
    error AlreadyCovered(uint64 closureId);
    error CapacityExceeded(uint256 uAfter, uint256 uMax);
    error PremiumAboveMax(uint256 premium, uint256 max);
    error BorrowPaused(bytes32 id);
    error NotLiquidatable();
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error CapExceeded(uint256 amount, uint256 cap);
    error HealthFactorTooLow(uint256 hf, uint256 min);
    error NoDebt();
    error ZeroAmount();
    // v1 additions (S2)
    error PositionInAuction(uint64 auctionId);
    error NotInLot(uint64 auctionId, address borrower);
    error LotNotCleared(uint64 auctionId);
    error LotAlreadyReleased(uint64 auctionId);
    error LotAlreadyCleared(uint64 auctionId);
    error TooManyPositions(uint256 n, uint256 max);
    error OverlayNotRiskReducing();
    error IncompatibleRiskParams();

    // ── vault / pool (S2–S3) ──
    error RequestNotFound(uint256 requestId);
    error NotRequestOwner(uint256 requestId);
    error EpochNotSettleable(uint64 epochId);
    error EpochAlreadySettled(uint64 epochId);
    error EpochNotSettled(uint64 epochId);
    error WithdrawWindowClosed(uint64 epochId);
    // v1 additions (S2)
    error RequestAlreadyProcessed(uint256 requestId);
    error RequestNotProcessed(uint256 requestId);
    error RequestAlreadyClaimed(uint256 requestId);
    error UnknownMarket(bytes32 id);
    error QueueTooLong(uint256 n, uint256 max);

    // ── auctions / settlement (S3–S4) ──
    error PhaseClosed(uint8 phase);
    error BadReveal();
    error BidBelowReserve();
    error TooManyBids();
    error BidTooSmall(uint256 notional, uint256 min);
    error RevealAboveMaxNotional(uint256 notional, uint256 maxNotional);
    error NothingToClaim();
    error NotAllowlisted(address account);
    error SolverBidTooLow(uint256 price, uint256 min);

    // ── tokens (testnet assets) ──
    error TokenFrozen();
    error TransferNotAllowed(address from, address to);
    error RedemptionsGated();
    error RequestNotClaimable(uint256 requestId);
    error FaucetCooldown(address account, uint40 availableAt);
    error FaucetTokenNotConfigured(address token);

    // ── sigma oracle ──
    error SigmaNotNewer(uint32 asOfDay, uint32 lastAsOfDay);

    // ── governance (v1, S2) ──
    error UnpauseNotScheduled(bytes32 key);
    error UnpauseNotReady(bytes32 key, uint40 executableAt);
    error HaircutTooLarge(uint64 bps, uint64 max);
    error HaircutNotHigher(uint64 bps, uint64 current);
    error UntilTooLate(uint40 until, uint40 maxUntil);
    error UntilInPast(uint40 until);

    // ── gas (v1.1, S3; ADR-0109) ──
    /// @notice A guarded try-call failed because the caller supplied too little gas (not because the callee reverted).
    error InsufficientGas();

    // ── pool (v2, S3; ADR-0110) ──
    error WrongVenue(bytes32 venue);
    error NotInBellWindow(uint40 bellWindowAt, uint40 closeAt);
    error EpochNotOpen(uint64 epochId);
    error EpochStillOpen(uint64 epochId); // an earlier epoch is unsettled
    error EpochNotReady(uint64 epochId, uint8 reason); // settleEpoch preconditions (§8.6.3), see UnderwriterPool
    error SnapshotTooEarly(uint40 bellAt);
    error PolicyEpochMismatch(uint64 given, uint64 active);
    error InsufficientShares(uint256 have, uint256 want);
    error NothingQueued(uint64 epochId);
    error ClaimOrder(uint64 olderEpochId); // FIFO: an older epoch still has unpaid withdrawals
    error NoInventory(bytes32 assetId);
    error GdaRunning(uint64 gdaId);
    error ReserveNotReleasable(uint64 epochId, bytes32 assetId);
    error NotImplemented(); // fallbackAdvance until S4

    // ── auction house (v2, S3; ADR-0110) ──
    error UnknownAuction(uint64 auctionId);
    error WrongKind(uint8 kind);
    error TooEarly(uint40 at);
    error TooLate(uint40 at);
    error LotNotFixed(uint64 auctionId);
    error AlreadyBid(uint64 auctionId, address bidder);
    error NoBid(uint64 auctionId, address bidder);
    error ReopenNotOver(bytes32 assetId);
    error UnknownGda(uint64 gdaId);
    error GdaInsufficient(uint256 available, uint256 wanted);
    error CostAboveMax(uint256 cost, uint256 maxCost);

    // ── NAV settlement and hardening (v3, S4; ADR-0111, ADR-0112) ──
    error ConcentrationExceeded(bytes32 assetId, uint256 worstAfter, uint256 cap);
    error NothingToSettle(bytes32 marketId);
    error UnknownSettlement(uint64 settlementId);
    error SettlementNotOpen(uint64 settlementId);
    error NoVenue();
    error UnknownRedemption(uint256 requestId);
    error SeqStepTooLarge(bytes32 assetId, uint64 seq, uint64 storedSeq);
}
