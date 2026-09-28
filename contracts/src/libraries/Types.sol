// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Credence shared types (Build Guide §8.1). Interfaces v1 (v0 + additive S2 types, ADR-0104).
/// @dev Every struct and enum that crosses a contract boundary lives here. Enum values are part of the ABI:
///      append only, never reorder.

// ─────────────────────────────── enums ───────────────────────────────

/// @dev Restrictiveness (AssetClock): CORP_ACTION > HALTED > CLOSED > REOPEN > EXTENDED > REGULAR.
///      The numeric enum order is NOT the restrictiveness order; use `ClockLib.rank`.
enum ClockState {
    REGULAR,
    EXTENDED,
    CLOSED,
    REOPEN,
    HALTED,
    CORP_ACTION
}

/// @dev A mid-week holiday closure (e.g. Tue close → Thu open) uses HOLIDAY_WEEKEND.
enum ClosureType {
    NONE,
    OVERNIGHT,
    WEEKEND,
    HOLIDAY_WEEKEND,
    HALT,
    CORP_ACTION
}

enum MarketKind {
    EQUITY,
    NAV
}

enum AuctionKind {
    REOPEN,
    INTRADAY,
    EMERGENCY,
    PRECLOSE
}

enum AuctionPhase {
    NONE,
    QUEUE,
    COMMIT,
    REVEAL,
    OPEN_BIDDING,
    CLEARED,
    CANCELLED
}

enum BellStatus {
    SAFE,
    NEEDS_ACTION,
    COVERED
}

/// @dev `Report.kind` values (CredencePriceFeed). Kept as uint8 in the signed struct.
library ReportKind {
    uint8 internal constant LIVE = 0;
    uint8 internal constant OPEN = 1;
    uint8 internal constant CLOSE = 2;
    uint8 internal constant NAV = 3;
    uint8 internal constant STATUS = 4;
}

/// @dev `Report.marketStatus` / `IPriceSource.latest().marketStatus` values.
library FeedMarketStatus {
    uint8 internal constant CLOSED = 0;
    uint8 internal constant PRE = 1;
    uint8 internal constant REGULAR = 2;
    uint8 internal constant POST = 3;
    uint8 internal constant OVERNIGHT = 4;
    uint8 internal constant HALTED = 5;
}

/// @dev `KeeperTips` job ids (§8.10).
library KeeperJob {
    uint8 internal constant ENFORCE_BELL = 0;
    uint8 internal constant FLAG = 1;
    uint8 internal constant FIX_LOTS = 2;
    uint8 internal constant CLEAR = 3;
    uint8 internal constant SETTLE = 4;
    uint8 internal constant OPEN_SETTLEMENT = 5;
    uint8 internal constant FINALIZE_SETTLEMENT = 6;
    uint8 internal constant EPOCH = 7;
}

/// @dev v1. `ActionNotAllowedInState(action, state)` action codes (the §8.2.2 permission matrix rows).
library MarketAction {
    uint8 internal constant BORROW = 0;
    uint8 internal constant WITHDRAW_COLLATERAL = 1;
    uint8 internal constant REPAY = 2;
    uint8 internal constant ADD_COLLATERAL = 3;
    uint8 internal constant BUY_COVER = 4;
    uint8 internal constant FLAG_FOR_AUCTION = 5;
    uint8 internal constant ENFORCE_BELL = 6;
}

/// @dev v1. `BellEnforced.outcome` values (§8.4.3 `enforceBell`).
library BellOutcome {
    uint8 internal constant SAFE = 0; // already at or below the safe LTV (no tip)
    uint8 internal constant ALREADY_COVERED = 1; // covered for the upcoming closure (no tip)
    uint8 internal constant AUTO_COVERED = 2; // auto-cover bought, premium added to debt
    uint8 internal constant PRECLOSE_THEN_COVER = 3; // above maxLtv + δ: pre-close sale to maxLtv, then cover (R-03)
    uint8 internal constant PRECLOSE_SALE = 4; // pre-close sale down to the safe LTV
}

// ─────────────────────────────── markets ───────────────────────────────

struct RateParams {
    uint64 r0; // WAD per year
    uint64 s1; // WAD per year
    uint64 s2; // WAD per year
    uint64 uKink; // WAD
}

struct MarketParams {
    address loanToken; // USDC
    address collateralToken; // tNVDA, tTBILL, …
    bytes32 assetId; // keccak256("NVDA:XNAS")
    MarketKind kind;
    uint64 maxLtv; // WAD, e.g. 0.75e18
    uint64 lt; // liquidation threshold, WAD
    uint64 penalty; // λ, WAD
    uint64 precloseKappa; // κ_preclose, WAD (R-06)
    uint64 precloseLambda; // λ_preclose, WAD (1%)
    uint128 supplyCap; // loan units
    uint128 borrowCap; // loan units
    RateParams rate; // kinked IRM
}

struct MarketState {
    uint128 totalSupplyAssets; // owed to the SeniorVault (senior share of interest included)
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 poolFeeAccrued; // receivable of the UnderwriterPool (R-09)
    uint128 treasuryFeeAccrued; // receivable of the Treasury (R-09)
    uint128 totalCollateral; // collateral token units held for positions
    uint40 lastAccrual;
    uint16 feePoolBps; // ρ_J
    uint16 feeTreasuryBps; // ρ_p
}

struct Position {
    uint128 collateral; // token units
    uint128 borrowShares;
    uint64 coverClosureId; // closureId this position is covered for (0 = none)
    uint64 lastBellClosureId; // closureId whose Bell it passed (SAFE or COVERED)
    uint64 auctionId; // non-zero while queued / in a lot
    bool autoCoverOptOut; // default false → auto-cover ON
}

struct GuardianOverlay {
    uint64 haircut; // WAD subtracted from maxLtv
    uint40 haircutUntil;
    bool borrowPaused;
    bool coverPaused;
}

/// @notice v1. Contract-to-contract wiring of `CredenceMarket`, set once through `initializeWiring` (§7.4).
/// @dev `engine` and `oracle` are replaceable later through the timelock (R-21); the rest are fixed.
struct MarketWiring {
    address clock;
    address oracle;
    address engine;
    address vault;
    address pool;
    address auctionHouse;
    address settlement;
    address reserve;
    address treasury;
    address tips;
}

/// @notice v1. Read-only view of a liquidation lot (`LotBook` in §8.4.1).
struct LotInfo {
    bytes32 marketId;
    AuctionKind kind;
    uint128 totalQty; // Σ x_i released to the auction house (0 until `releaseLots`)
    uint128 proceeds; // loan units received in `onAuctionCleared`
    uint128 blendedPrice; // p̄, WAD per token
    uint128 proceedsSettled; // loan units already attributed to settled positions
    uint32 positions; // borrowers in the lot
    uint32 settledCount;
    bool released;
    bool cleared;
}

/// @notice v1. One ERC-7540-style redeem request of the Senior Vault (R-17).
struct RedeemRequest {
    address owner;
    address receiver;
    uint128 shares; // escrowed in the vault until processed
    uint128 assets; // set when processed (share price at processing time); claimable
    bool processed;
    bool claimed;
}

// ─────────────────────────────── clock ───────────────────────────────

/// @notice One exchange session, precomputed off-chain in UTC unix seconds (§8.2.1).
/// @dev extOpen < open < close < extClose. For a weeknight, extClose == next session's extOpen.
struct Session {
    uint40 extOpen; // start of the extended window before `open` (overnight 24/5 or pre-market)
    uint40 open; // regular-session open
    uint40 close; // regular-session close (early-close days included)
    uint40 extClose; // end of post-market (or next extOpen if 24/5 runs through)
    ClosureType closureTypeAfter; // type of the closure that starts at `close`
}

struct AssetConfig {
    bytes32 venue;
    MarketKind kind;
    bool listed;
}

/// @notice Per-asset clock bookkeeping, returned by `IAssetClock.closureInfo`.
/// @dev "current closure" = the most recent closure (scheduled, halt or corporate action).
///      "next*" fields describe the next scheduled close of the calendar.
struct ClockData {
    ClockState state;
    ClosureType closureType; // of the current / most recent closure
    uint64 closureId; // ++ at every close, halt or corporate action (per asset)
    uint64 venueEpoch; // session index of the close that opened this closure (R-10)
    uint128 refPrice; // last regular close (WAD per token), frozen at close
    uint40 refTime;
    uint40 bellWindowAt; // nextCloseAt − 2h
    uint40 bellAt; // nextCloseAt − 15m
    uint40 closeAt; // start of the current / most recent closure
    uint40 reopenAt; // scheduled open that ends the current closure (0 = unknown)
    uint128 openPrint; // written once per closure at REOPEN
    uint40 openPrintAt;
    uint40 phaseExtension; // seconds added by sequencer-gap detection (R-20)
    uint32 sessionCursor; // calendar session index the clock is in
    uint32 closedSessions; // number of calendar sessions whose close has been processed
    uint40 nextCloseAt; // next scheduled regular close (0 = beyond calendar coverage)
    bool reopenPending; // a closure has started and its REOPEN is not complete
    bool corporateAction; // a corporate action is active (begin → confirm)
}

/// @notice A guardian restriction as seen by readers (the most restrictive active one).
struct Restriction {
    ClockState state;
    uint40 until;
}

// ─────────────────────────────── price layer ───────────────────────────────

/// @notice A signed price report (§8.3.1). The EIP-712 digest is defined in `ICredencePriceFeed`.
struct Report {
    bytes32 assetId;
    uint8 kind; // ReportKind: 0 LIVE, 1 OPEN, 2 CLOSE, 3 NAV, 4 STATUS
    uint128 price; // WAD per SHARE (the adapter applies sharesPerToken)
    uint40 observedAt; // exchange timestamp of the print (UTC seconds)
    uint40 sessionDate; // floor(sessionRegularOpenUtc / 86400): UTC day index of the session's regular open
    uint8 marketStatus; // FeedMarketStatus: 0 closed, 1 pre, 2 regular, 3 post, 4 overnight, 5 halted
    uint64 seq; // strictly increasing per (feed, asset)
}

struct FeedHealth {
    bool stale; // primary older than 60 s (REGULAR) / 300 s (EXTENDED); NAV: one missed USBANK strike (R-23)
    bool disagreement; // |p1 − p2| / min(p1, p2) > 1.5%, or the secondary is missing / stale
    bool severeDisagreement; // > 5% (both fresh)
    bool statusClosed; // primary marketStatus says closed while the calendar says open
    bool statusHalted; // either feed reports a single-stock halt
    bool issuerFrozen; // collateral token frozen / redemptions gated (or the probe failed)
    bool navInvalid; // NAV kind: two missed USBANK strikes (R-23), no NAV, or a one-step drop > 0.5%
}

/// @notice Per-asset price wiring of the OracleAdapter.
struct OracleConfig {
    address primary; // IPriceSource
    address secondary; // IPriceSource
    address dex; // ITwapSource, address(0) = none
    address token; // collateral token (frozen / redemptionsGated / sharesPerToken)
    MarketKind kind;
    uint128 sharesPerToken; // WAD, cached; changed only via CORP_ACTION
    uint128 minDepth; // WAD USD, ±2% DEX depth below which the TWAP is ignored
    bool listed;
}

// ─────────────────────────────── risk ───────────────────────────────

struct RiskParams {
    uint64 alpha; // 0.001e18
    uint64 kappa; // 0.03e18
    uint64 theta; // 1.00e18
    uint64 costOfCap; // 0.15e18 per year
    uint64 eta; // 4e18
    uint64 beta; // 0.975e18
    uint64 uMax; // 0.50e18
    uint64 minPremium; // loan units
    uint32 kStress; // 256
}

struct SigmaUpdate {
    bytes32 assetId;
    uint8 closureType;
    uint256 sigma; // WAD
    uint32 asOfDay; // UTC day index; strictly increasing per (asset, closureType)
    uint64 nonce;
}

// ─────────────────────────────── pool ───────────────────────────────

struct CoverRequest {
    bytes32 marketId;
    bytes32 assetId;
    address borrower;
    uint8 closureType;
    uint16 closureDays;
    uint64 closureId;
    uint64 epochId;
    uint256 collateralValue; // loan units at V_live
    uint256 debtProjected; // loan units, D × (1 + r_b × τ) (R-08)
}

/// @notice One venue closure of the UnderwriterPool (R-10). v2 (S3): the flows of the epoch are recorded, so
///         INV-POOL-01 can be checked from state and `EpochSettled` alone.
struct Epoch {
    uint64 epochId; // calendar session index of the close that starts the closure (venueEpoch)
    uint40 bellWindowAt; // close − 2 h
    uint40 bellAt; // close − 15 m (J snapshot, the Bell deadline)
    uint40 closeAt;
    uint40 reopenAt; // the next session's open
    EpochPhase phase;
    uint32 policies;
    uint128 premiums; // written for this epoch (unearned until settlement)
    uint128 riskFees; // credited while the epoch was open
    uint128 penalties;
    uint128 bonds;
    int128 backstopPnl; // realised GDA P&L while the epoch was open
    uint128 lossesPaid; // shortfalls paid while the epoch was open
    uint128 pendingLossReserve; // R-11: worst covered loss of assets whose REOPEN had not completed at settlement
    uint128 equityAtRisk; // J snapshot at the Bell deadline
    uint128 navBefore; // NAV when the epoch opened
    uint128 navAfter; // NAV at settlement (after the premiums are released, before withdrawals / deposits)
    uint128 sharePriceAfter; // WAD, written at settlement
    uint128 withdrawSharesQueued;
    uint128 withdrawAssetsReserved; // withdrawSharesQueued × sharePriceAfter, reserved at settlement
    uint128 depositAssetsQueued;
    uint128 depositSharesMinted; // minted at settlement, held by the pool until claimDeposit
}

enum EpochPhase {
    NONE,
    OPEN, // Bell window opened: covers are written against it
    SNAPSHOT, // Bell deadline passed: J is frozen
    SETTLED
}

/// @notice The pool's backstop inventory of one collateral token (R-12): valued at min(cost, V × (1 − κ)).
struct Inventory {
    address token;
    uint128 qty; // held by the pool or listed in a GDA
    uint128 cost; // loan units paid for `qty`
    uint128 inGda; // part of `qty` handed to the auction house for GDA resale
    uint64 gdaId; // the running GDA (0 = none)
}

// ─────────────────────────────── auctions ───────────────────────────────

/// @dev deadlines = [lotFixAt, biddingStartAt, commitEndOrBidEnd, clearAt]. For REOPEN:
///      [openPrintAt+2:00, openPrintAt+2:00, openPrintAt+5:00 (commit end), openPrintAt+7:00], all + ext.
struct Auction {
    AuctionKind kind;
    AuctionPhase phase;
    bytes32 marketId;
    bytes32 assetId;
    uint64 closureId;
    uint64 venueEpoch; // the pool epoch a REOPEN auction belongs to (R-10)
    uint32 tranche; // 0, 1, … for lots beyond 256 positions (same schedule)
    uint40[4] deadlines;
    uint128 lot; // Q, collateral units
    uint128 reserve; // R, WAD per token (final at clearing for the open kinds, R-19)
    uint128 pStar; // WAD per token
    uint128 filled; // collateral units sold to bidders
    uint128 qPool; // collateral units bought by the pool
    uint128 proceeds; // loan units
    uint128 startPrice; // V at creation (INTRADAY, EMERGENCY) or at lot fixing (PRECLOSE), WAD
    uint16 bidCount;
    uint16 positionCount;
    bool full; // no more positions join (a tranche follows)
    bool settled; // every position settled in the market, or an empty lot (ADR-0107 §7)
}

/// @notice One bid (sealed or open). `escrow` is the loan units held for it (bond included).
struct Bid {
    bytes32 commitment; // sealed bids only
    uint128 maxNotional; // sealed bids: declared at commit (R-04)
    uint128 qty;
    uint128 price; // WAD per token
    uint128 escrow;
    uint128 fill; // set at clearing
    bool revealed; // open bids: true when placed
    bool claimed;
}

/// @notice A continuous GDA over the pool's backstop inventory (F-4.5e).
struct Gda {
    bytes32 assetId;
    address token;
    uint128 qty; // initial
    uint128 sold;
    uint128 k; // WAD
    uint128 decay; // λ_d, WAD per second
    uint128 emissionPerSec; // r_e, token units per second
    uint40 start;
    bool active;
}
