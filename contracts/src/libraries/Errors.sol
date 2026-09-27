// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClockState} from "./Types.sol";

/// @title Credence error catalogue (Build Guide Appendix C). Interfaces v0.
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

    // ── vault / pool (S2–S3) ──
    error RequestNotFound(uint256 requestId);
    error NotRequestOwner(uint256 requestId);
    error EpochNotSettleable(uint64 epochId);
    error EpochAlreadySettled(uint64 epochId);
    error EpochNotSettled(uint64 epochId);
    error WithdrawWindowClosed(uint64 epochId);

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
}
