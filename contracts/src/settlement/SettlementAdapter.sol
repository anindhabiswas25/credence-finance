// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    AuctionKind,
    ClockData,
    KeeperJob,
    MarketKind,
    MarketParams,
    MarketWiring,
    Settlement,
    SettlementStatus
} from "../libraries/Types.sol";
import {WadMath} from "../libraries/WadMath.sol";
import {GasGuard} from "../libraries/GasGuard.sol";
import {ISettlementAdapter} from "../interfaces/ISettlementAdapter.sol";
import {ISolverVenue} from "../interfaces/ISolverVenue.sol";
import {ICredenceMarket} from "../interfaces/ICredenceMarket.sol";
import {IUnderwriterPool} from "../interfaces/IUnderwriterPool.sol";
import {IAssetClock} from "../interfaces/IAssetClock.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IKeeperTips} from "../interfaces/IKeeperTips.sol";

/// @title SettlementAdapter: T+0 liquidation of Treasury-fund collateral (Build Guide §8.8, Architecture §3.8).
/// @notice The NAV stack's replacement for the auction house. `openSettlement` flags the listed HF < 1 positions of a
///         NAV market into one lot, which the market sizes with F-4.5a at κ_nav = 0.5 % and releases here; the lot is
///         offered to allowlisted solvers for `window()` (15 min) on `venues()[0]` with floor = NAV × 99.5 %.
///         `finalize` sells to the best solver, or, with no bid, has the pool advance qty × floor against a fund
///         redemption (`fallbackAdvance`), and then settles every position of the lot in the market. If the fund gates
///         redemptions or is frozen, the oracle marks it `issuerFrozen`, the clock goes HALTED and `openSettlement`
///         reverts (repay stays open). ADR-0111.
/// @dev A settlement id is the market's lot id (the market asks `getOrCreate` for it). Lots exist only inside
///      `openSettlement`: a direct `market.flagForAuction` on the NAV market reverts, so no lot is ever left unreleased.
///      Tips the market pays this contract (FLAG, SETTLE) are forwarded to the keeper that caused them.
contract SettlementAdapter is ISettlementAdapter, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using WadMath for uint256;

    /// @notice κ_nav (§8.8): the NAV lot's reserve discount, floor = NAV × (1 − κ_nav).
    uint256 public constant KAPPA_NAV = 0.005e18;
    /// @notice Borrowers per `openSettlement` (one market lot, ADR-0110 §8).
    uint256 public constant MAX_POSITIONS = 128;
    /// @notice The market's REOPEN queue after the open print (§8.4.3).
    uint256 public constant REOPEN_QUEUE = 120;
    uint40 public constant MIN_WINDOW = 5 minutes;
    uint40 public constant MAX_WINDOW = 1 days;

    address public immutable timelock;
    address public market;
    address public pool;
    IKeeperTips public tips;
    uint40 public window = 15 minutes;
    uint64 public nextSettlementId = 1;
    address[] internal _venues;

    mapping(uint64 settlementId => Settlement) internal _settlements;
    mapping(bytes32 assetId => mapping(uint64 closureId => uint256)) public openReopenSettlements;

    /// @dev The NAV market being flagged by `openSettlement` (0 outside it) and the lot created for it.
    bytes32 internal transient _opening;
    uint64 internal transient _pending;

    event WiringInitialized(address market, address pool, address tips);

    constructor(address timelock_) {
        if (timelock_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert Unauthorized();
        _;
    }

    modifier onlyMarket() {
        if (msg.sender != market || market == address(0)) revert Unauthorized();
        _;
    }

    /// @notice Once, by the timelock: the NAV market and pool, the keeper tips, and the venues (first = active).
    function initializeWiring(address market_, address pool_, address tips_, address[] calldata venues_)
        external
        onlyTimelock
    {
        if (market != address(0)) revert AlreadyWired();
        if (market_ == address(0) || pool_ == address(0) || tips_ == address(0)) revert ZeroAddress();
        market = market_;
        pool = pool_;
        tips = IKeeperTips(tips_);
        emit WiringInitialized(market_, pool_, tips_);
        _setVenues(venues_);
    }

    /// @inheritdoc ISettlementAdapter
    function setVenues(address[] calldata venues_) external onlyTimelock {
        _setVenues(venues_);
    }

    /// @inheritdoc ISettlementAdapter
    function setWindow(uint40 window_) external onlyTimelock {
        if (window_ < MIN_WINDOW || window_ > MAX_WINDOW) revert InvalidParam();
        window = window_;
        emit WindowSet(window_);
    }

    // ═════════════════════════════ keeper ═════════════════════════════

    /// @inheritdoc ISettlementAdapter
    function openSettlement(bytes32 marketId, address[] calldata borrowers)
        external
        nonReentrant
        returns (uint64 id)
    {
        if (borrowers.length == 0) revert ZeroAmount();
        if (borrowers.length > MAX_POSITIONS) revert TooManyPositions(borrowers.length, MAX_POSITIONS);
        if (_venues.length == 0) revert NoVenue();
        ICredenceMarket m = ICredenceMarket(market);
        MarketParams memory p = m.marketParams(marketId);
        if (p.kind != MarketKind.NAV) revert WrongKind(uint8(p.kind));

        // 1. flag: the market checks the clock state (INV-LIQ-01) and HF < 1, and asks getOrCreate for the lot
        IERC20 loan = IERC20(p.loanToken);
        uint256 bal = loan.balanceOf(address(this));
        _opening = marketId;
        m.flagForAuction(marketId, borrowers);
        id = _pending;
        (_opening, _pending) = (bytes32(0), 0);
        if (id == 0) revert NothingToSettle(marketId);

        // 2. release: F-4.5a at κ_nav, the tokens come here
        uint256 qty = m.releaseLots(id);
        if (qty == 0) revert NothingToSettle(marketId); // cannot happen: HF < 1 was checked in this transaction
        _forward(loan, bal);

        // 3. the solver window
        MarketWiring memory w = m.wiring();
        uint256 floorPrice = IOracleAdapter(w.oracle).valuationPrice(p.assetId).mulWadDown(1e18 - KAPPA_NAV);
        Settlement storage s = _settlements[id];
        address venue = _venues[0];
        uint40 endsAt = uint40(block.timestamp) + window;
        s.token = p.collateralToken;
        s.venue = venue;
        s.status = SettlementStatus.OPEN;
        s.openedAt = uint40(block.timestamp);
        s.endsAt = endsAt;
        s.positions = uint32(m.lotBorrowers(id).length);
        s.qty = uint128(qty);
        s.floorPrice = uint128(floorPrice);
        if (s.kind == AuctionKind.REOPEN) ++openReopenSettlements[s.assetId][s.closureId];
        IERC20(p.collateralToken).safeTransfer(venue, qty);
        ISolverVenue(venue).open(id, p.collateralToken, qty, floorPrice, endsAt);
        emit SettlementOpened(id, marketId, venue, qty, floorPrice, endsAt);
        _tip(KeeperJob.OPEN_SETTLEMENT);
    }

    /// @inheritdoc ISettlementAdapter
    function finalize(uint64 id) external nonReentrant {
        Settlement storage s = _settlements[id];
        if (s.status == SettlementStatus.NONE) revert UnknownSettlement(id);
        if (s.status != SettlementStatus.OPEN) revert SettlementNotOpen(id);
        if (block.timestamp < s.endsAt) revert TooEarly(s.endsAt);
        ICredenceMarket m = ICredenceMarket(market);
        IERC20 loan = IERC20(m.marketParams(s.marketId).loanToken);

        (bool filled, uint256 proceeds) = ISolverVenue(s.venue).finalize(id);
        uint256 price;
        if (filled) {
            address solver;
            (solver, price) = ISolverVenue(s.venue).best(id);
            s.status = SettlementStatus.FILLED;
            s.solver = solver;
            emit SettlementFilled(id, solver, s.qty, proceeds);
        } else {
            // §8.8 step 3: no bid → the pool advances qty × floor and waits for the redemption itself
            s.status = SettlementStatus.ADVANCED;
            uint256 bal = loan.balanceOf(address(this));
            IERC20(s.token).safeTransfer(pool, s.qty);
            uint256 requestId = IUnderwriterPool(pool).fallbackAdvance(s.marketId, s.qty, s.floorPrice);
            proceeds = loan.balanceOf(address(this)) - bal;
            // p̄ from what actually arrived (≤ qty × floor if the pool's free cash was short), rounded down, so the
            // market's per-position proceeds never add up to more than it received
            price = _priceDown(proceeds, s.qty, s.token, loan);
            s.requestId = requestId;
            emit FallbackAdvanced(id, s.qty, s.floorPrice, requestId);
        }
        s.price = uint128(price);
        s.proceeds = uint128(proceeds);
        if (s.kind == AuctionKind.REOPEN) --openReopenSettlements[s.assetId][s.closureId];
        emit SettlementFinalized(id, filled, s.solver, price, proceeds, s.requestId);

        // proceeds to the market, then F-4.5d for every position of the lot
        loan.forceApprove(address(m), proceeds);
        m.onAuctionCleared(id, proceeds, price);
        uint256 bal2 = loan.balanceOf(address(this));
        m.settlePositions(id, m.lotBorrowers(id));
        _forward(loan, bal2);
        _tip(KeeperJob.FINALIZE_SETTLEMENT);
    }

    /// @inheritdoc ISettlementAdapter
    function completeReopen(bytes32 assetId) external nonReentrant {
        IAssetClock clock = IAssetClock(ICredenceMarket(market).wiring().clock);
        if (clock.assetConfig(assetId).kind != MarketKind.NAV) revert WrongKind(uint8(MarketKind.EQUITY));
        ClockData memory d = clock.closureInfo(assetId);
        if (!d.reopenPending || d.openPrintAt == 0) revert ReopenNotPending(assetId);
        uint256 queueEnd = uint256(d.openPrintAt) + REOPEN_QUEUE + d.phaseExtension;
        if (block.timestamp < queueEnd) revert TooEarly(uint40(queueEnd));
        if (openReopenSettlements[assetId][d.closureId] != 0) revert ReopenNotOver(assetId);
        clock.markReopenComplete(assetId, d.closureId);
        emit NavReopenCompleted(assetId, d.closureId);
    }

    // ═════════════════════════════ market callbacks ═════════════════════════════

    /// @inheritdoc ISettlementAdapter
    function getOrCreate(AuctionKind k, bytes32 marketId, bytes32 assetId, uint64 closureId)
        external
        onlyMarket
        returns (uint64 id)
    {
        if (_opening != marketId || marketId == bytes32(0)) revert Unauthorized();
        id = _pending;
        if (id != 0) return id;
        id = nextSettlementId++;
        Settlement storage s = _settlements[id];
        s.marketId = marketId;
        s.assetId = assetId;
        s.kind = k;
        s.closureId = closureId;
        _pending = id;
    }

    /// @inheritdoc ISettlementAdapter
    function nextTranche(uint64) external view onlyMarket returns (uint64) {
        return 0;
    }

    /// @inheritdoc ISettlementAdapter
    function lotSettled(uint64 id) external onlyMarket {
        Settlement storage s = _settlements[id];
        s.settled = true;
        emit SettlementPositionsSettled(id, s.positions);
    }

    // ═════════════════════════════ views ═════════════════════════════

    /// @inheritdoc ISettlementAdapter
    function venues() external view returns (address[] memory) {
        return _venues;
    }

    /// @inheritdoc ISettlementAdapter
    function kappaNav() external pure returns (uint256) {
        return KAPPA_NAV;
    }

    /// @inheritdoc ISettlementAdapter
    function settlement(uint64 id) external view returns (Settlement memory) {
        return _settlements[id];
    }

    // ═════════════════════════════ internals ═════════════════════════════

    function _setVenues(address[] calldata v) internal {
        for (uint256 i; i < v.length; ++i) {
            if (v[i] == address(0)) revert ZeroAddress();
        }
        _venues = v;
        emit VenuesSet(v);
    }

    /// @dev p̄ = proceeds / qty in WAD per token, rounded down.
    function _priceDown(uint256 proceeds, uint256 qty, address token, IERC20 loan)
        internal
        view
        returns (uint256)
    {
        return proceeds.mulDivDown(
            10 ** IERC20Metadata(token).decimals() * 1e18,
            qty * 10 ** IERC20Metadata(address(loan)).decimals()
        );
    }

    /// @dev Tips the market paid this contract since `bal` (FLAG, SETTLE) go to the keeper.
    function _forward(IERC20 loan, uint256 bal) internal {
        uint256 now_ = loan.balanceOf(address(this));
        if (now_ > bal) loan.safeTransfer(msg.sender, now_ - bal);
    }

    function _tip(uint8 job) internal {
        uint256 g = gasleft();
        try tips.pay(msg.sender, job) {}
        catch {
            GasGuard.check(g);
        }
    }
}
