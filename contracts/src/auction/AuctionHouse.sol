// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    AuctionKind,
    AuctionPhase,
    Auction,
    Bid,
    Gda,
    ClockData,
    ClockState,
    MarketParams,
    LotInfo,
    MarketKind,
    KeeperJob
} from "../libraries/Types.sol";
import {GasGuard} from "../libraries/GasGuard.sol";
import {GdaLib} from "./GdaLib.sol";
import {IAuctionHouse} from "../interfaces/IAuctionHouse.sol";
import {ICredenceMarket} from "../interfaces/ICredenceMarket.sol";
import {IUnderwriterPool} from "../interfaces/IUnderwriterPool.sol";
import {IRiskEngine} from "../interfaces/IRiskEngine.sol";
import {IAssetClock} from "../interfaces/IAssetClock.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IKeeperTips} from "../interfaces/IKeeperTips.sol";
import {TokenProbe} from "../libraries/TokenProbe.sol";

/// @title AuctionHouse: every liquidation as a uniform-price batch (Build Guide §8.7, F-4.5c, R-04, R-05, R-19).
/// @notice Four kinds: REOPEN (sealed commit–reveal, 10% bond), INTRADAY, EMERGENCY and PRECLOSE (open, firm bids).
///         Lots of up to 256 positions (tranches beyond), at most 64 bids, clearing through `engine.clear`: everyone
///         pays p*, ties pro rata. Unsold quantity goes to the pool at R. Also runs the GDA resale of the pool's
///         backstop inventory (F-4.5e). One auction house per equity stack. Design choices: ADR-0110.
/// @dev Deadlines per auction = [lotFixAt, biddingStartAt, commitEnd (REOPEN) / biddingEnd, clearAt]. Offsets per
///      kind are timelock-configurable: REOPEN and INTRADAY / EMERGENCY count from their base (open print + phase
///      extension, or creation); PRECLOSE counts *back* from the close.
contract AuctionHouse is ReentrancyGuardTransient, IAuctionHouse {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant REOPEN_QUEUE = 120; // §8.4.3, market flag window after the open print
    uint8 internal constant GDA_BUY = 7; // `ActionNotAllowedInState` action code of gdaBuy (after MarketAction's 0–6)

    address public immutable timelock;
    ICredenceMarket public market;
    IUnderwriterPool public pool;
    IAssetClock public clock;
    IKeeperTips public tips;

    mapping(AuctionKind => uint40[4]) public timings;
    uint16 public maxBids = 64;
    uint128 public minNotional; // loan units ($100 on testnet, set at wiring)
    uint16 public bondBps = 1000; // R-04: 10% of maxNotional

    uint64 public nextAuctionId = 1;
    mapping(uint64 => Auction) internal _auctions;
    mapping(uint64 => mapping(address => Bid)) internal _bids;
    mapping(uint64 => address[]) internal _bidders;
    mapping(bytes32 key => uint64) internal _current; // joinable auction per (kind, market, closure)
    /// @dev REOPEN bookkeeping: auctions not yet cleared / not yet settled per (asset, closure), unsettled per epoch.
    mapping(bytes32 assetId => mapping(uint64 closureId => uint32)) internal _reopenUncleared;
    mapping(bytes32 assetId => mapping(uint64 closureId => uint32)) internal _reopenUnsettled;
    mapping(uint64 epochId => uint32) internal _epochUnsettled;
    bytes32 public venue;

    uint64 public nextGdaId = 1;
    mapping(uint64 => Gda) internal _gdas;

    event WiringInitialized(address market, address pool, address clock, address tips);

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert Unauthorized();
        _;
    }

    modifier onlyMarket() {
        if (msg.sender != address(market) || msg.sender == address(0)) revert Unauthorized();
        _;
    }

    modifier onlyPool() {
        if (msg.sender != address(pool) || msg.sender == address(0)) revert Unauthorized();
        _;
    }

    constructor(address timelock_) {
        if (timelock_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
        // §8.7.1 defaults
        timings[AuctionKind.REOPEN] = [uint40(120), 120, 300, 420];
        timings[AuctionKind.INTRADAY] = [uint40(15), 15, 60, 60];
        timings[AuctionKind.EMERGENCY] = [uint40(60), 60, 300, 300];
        timings[AuctionKind.PRECLOSE] = [uint40(300), 300, 30, 30]; // seconds before the close
    }

    /// @notice Once, by the timelock. `venue_` is the calendar of the stack (REOPEN epochs, R-10).
    function initializeWiring(
        address market_,
        address pool_,
        address clock_,
        address tips_,
        bytes32 venue_,
        uint128 minNotional_
    ) external onlyTimelock {
        if (address(market) != address(0)) revert AlreadyWired();
        if (market_ == address(0) || pool_ == address(0) || clock_ == address(0) || tips_ == address(0)) {
            revert ZeroAddress();
        }
        market = ICredenceMarket(market_);
        pool = IUnderwriterPool(pool_);
        clock = IAssetClock(clock_);
        tips = IKeeperTips(tips_);
        venue = venue_;
        minNotional = minNotional_;
        emit WiringInitialized(market_, pool_, clock_, tips_);
        emit LimitsSet(maxBids, minNotional_, bondBps);
    }

    /// @notice onlyTimelock: the deadline offsets of an auction kind, [lotFix, biddingStart,
    ///        commitEnd/biddingEnd, clear] (§8.7.1).
    function setTimings(AuctionKind k, uint40[4] calldata offsets) external onlyTimelock {
        bool pre = k == AuctionKind.PRECLOSE;
        // forward kinds: fix ≤ start ≤ end ≤ clear; PRECLOSE (before the close): fix ≥ start ≥ end ≥ clear
        if (pre
                ? !(offsets[0] >= offsets[1] && offsets[1] >= offsets[2] && offsets[2] >= offsets[3])
                : !(offsets[0] <= offsets[1] && offsets[1] <= offsets[2] && offsets[2] <= offsets[3])) {
            revert InvalidParam();
        }
        timings[k] = offsets;
        emit TimingsSet(k, offsets);
    }

    /// @notice onlyTimelock: bids per auction (≤ 64), minimum bid notional (loan units) and the REOPEN bond
    ///        (bps of maxNotional, R-04).
    function setLimits(uint16 maxBids_, uint128 minNotional_, uint16 bondBps_) external onlyTimelock {
        if (maxBids_ == 0 || maxBids_ > 64 || bondBps_ > BPS) revert InvalidParam();
        (maxBids, minNotional, bondBps) = (maxBids_, minNotional_, bondBps_);
        emit LimitsSet(maxBids_, minNotional_, bondBps_);
    }

    // ═════════════════════════════ market ═════════════════════════════

    /// @inheritdoc IAuctionHouse
    function getOrCreate(AuctionKind k, bytes32 marketId, bytes32 assetId, uint64 closureId)
        external
        onlyMarket
        returns (uint64 id)
    {
        bytes32 key = keccak256(abi.encode(k, marketId, closureId));
        id = _current[key];
        if (id != 0) {
            Auction storage a = _auctions[id];
            if (a.phase == AuctionPhase.QUEUE && block.timestamp < a.deadlines[0]) return id;
            // REOPEN / PRECLOSE have one schedule per closure: past lot fixing, nobody joins any more
            if (k == AuctionKind.REOPEN || k == AuctionKind.PRECLOSE) revert TooLate(a.deadlines[0]);
        }
        id = _create(k, marketId, assetId, closureId, 0, 0);
        _current[key] = id;
    }

    /// @inheritdoc IAuctionHouse
    function nextTranche(uint64 auctionId) external onlyMarket returns (uint64 id) {
        Auction storage a = _auctions[auctionId];
        if (a.phase != AuctionPhase.QUEUE) revert PhaseClosed(uint8(a.phase));
        a.full = true;
        id = _create(a.kind, a.marketId, a.assetId, a.closureId, a.tranche + 1, auctionId);
        _current[keccak256(abi.encode(a.kind, a.marketId, a.closureId))] = id;
    }

    /// @inheritdoc IAuctionHouse
    function lotSettled(uint64 auctionId) external onlyMarket {
        Auction storage a = _auctions[auctionId];
        if (a.phase != AuctionPhase.CLEARED || a.settled) revert PhaseClosed(uint8(a.phase));
        _markSettled(auctionId, a);
    }

    // ═════════════════════════════ keeper steps ═════════════════════════════

    /// @inheritdoc IAuctionHouse
    function fixLots(uint64 auctionId) external nonReentrant {
        Auction storage a = _auction(auctionId);
        if (a.phase != AuctionPhase.QUEUE) revert PhaseClosed(uint8(a.phase));
        if (block.timestamp < a.deadlines[0]) revert TooEarly(a.deadlines[0]);
        uint256 q;
        uint256 g = gasleft();
        try market.releaseLots(auctionId) returns (uint256 x) {
            q = x;
        } catch {
            // the clock left the state this kind needs (e.g. an INTRADAY lot fixed after the close): cancel, so the
            // queued positions are free again (ADR-0110)
            GasGuard.check(g);
            market.cancelLot(auctionId);
            a.phase = AuctionPhase.CANCELLED;
            _reopenCleared(a);
            _markSettled(auctionId, a);
            emit LotsFixed(auctionId, 0, 0, 0);
            _tip(KeeperJob.FIX_LOTS);
            return;
        }
        LotInfo memory info = market.lotInfo(auctionId);
        a.lot = uint128(q);
        a.positionCount = uint16(info.positions);
        a.reserve = uint128(_reserve(a, false));
        if (q == 0) {
            // everyone cured before fixing: an empty lot counts as cleared and settled (ADR-0107 §7)
            a.phase = AuctionPhase.CLEARED;
            _reopenCleared(a);
            _markSettled(auctionId, a);
            _maybeCompleteReopen(a.assetId, a.closureId);
        } else {
            a.phase = a.kind == AuctionKind.REOPEN ? AuctionPhase.COMMIT : AuctionPhase.OPEN_BIDDING;
        }
        emit LotsFixed(auctionId, q, a.reserve, a.positionCount);
        _tip(KeeperJob.FIX_LOTS);
    }

    /// @inheritdoc IAuctionHouse
    function clear(uint64 auctionId) external nonReentrant {
        Auction storage a = _auction(auctionId);
        if (a.phase != AuctionPhase.COMMIT && a.phase != AuctionPhase.OPEN_BIDDING) {
            revert PhaseClosed(uint8(a.phase));
        }
        if (block.timestamp < a.deadlines[3]) revert TooEarly(a.deadlines[3]);
        uint256 r = _reserve(a, true); // R-19: final for the open kinds
        a.reserve = uint128(r);
        MarketParams memory p = market.marketParams(a.marketId);
        (uint256 filled, uint256 paidBidders, uint256 bonds) = _clearBids(auctionId, a, p, r);
        if (bonds != 0) {
            IERC20(p.loanToken).safeTransfer(address(pool), bonds);
            pool.creditBond(bonds);
        }
        uint256 qPool = a.lot - filled;
        uint256 paidPool;
        if (qPool != 0) {
            IERC20(p.collateralToken).safeTransfer(address(pool), qPool);
            paidPool = pool.backstopBuy(auctionId, a.assetId, p.collateralToken, qPool, r);
        }
        uint256 proceeds = paidBidders + paidPool;
        uint256 blended =
            proceeds.mulDiv(10 ** IERC20Metadata(p.collateralToken).decimals() * _scale(p), a.lot);
        a.filled = uint128(filled);
        a.qPool = uint128(qPool);
        a.proceeds = uint128(proceeds);
        a.phase = AuctionPhase.CLEARED;
        IERC20(p.loanToken).forceApprove(address(market), proceeds);
        market.onAuctionCleared(auctionId, proceeds, blended);
        emit AuctionCleared(auctionId, a.pStar, filled, qPool, proceeds, blended, r);
        _reopenCleared(a);
        _maybeCompleteReopen(a.assetId, a.closureId);
        _tip(KeeperJob.CLEAR);
    }

    /// @inheritdoc IAuctionHouse
    function completeReopen(bytes32 assetId) external nonReentrant {
        // a NAV asset's REOPEN belongs to the SettlementAdapter (its REOPEN settlements, ADR-0111)
        if (clock.assetConfig(assetId).kind != MarketKind.EQUITY) revert WrongKind(uint8(MarketKind.NAV));
        ClockData memory d = clock.closureInfo(assetId);
        if (!d.reopenPending || d.openPrintAt == 0) revert ReopenNotPending(assetId);
        if (block.timestamp < uint256(d.openPrintAt) + REOPEN_QUEUE + d.phaseExtension) {
            revert TooEarly(uint40(uint256(d.openPrintAt) + REOPEN_QUEUE + d.phaseExtension));
        }
        if (_reopenUncleared[assetId][d.closureId] != 0) revert ReopenNotOver(assetId);
        clock.markReopenComplete(assetId, d.closureId);
        emit ReopenCompleted(assetId, d.closureId, d.venueEpoch);
        _tip(KeeperJob.CLEAR);
    }

    // ═════════════════════════════ bidding ═════════════════════════════

    /// @inheritdoc IAuctionHouse
    function commitBid(uint64 auctionId, bytes32 commitment, uint128 maxNotional) external nonReentrant {
        Auction storage a = _auction(auctionId);
        if (a.kind != AuctionKind.REOPEN) revert WrongKind(uint8(a.kind));
        _window(a, AuctionPhase.COMMIT, a.deadlines[1], a.deadlines[2]);
        if (maxNotional < minNotional) revert BidTooSmall(maxNotional, minNotional);
        Bid storage b = _newBid(auctionId, a);
        uint256 bond = uint256(maxNotional).mulDiv(bondBps, BPS, Math.Rounding.Ceil);
        b.commitment = commitment;
        b.maxNotional = maxNotional;
        b.escrow = uint128(bond);
        IERC20(market.marketParams(a.marketId).loanToken).safeTransferFrom(msg.sender, address(this), bond);
        emit BidCommitted(auctionId, msg.sender, commitment, maxNotional, bond);
    }

    /// @inheritdoc IAuctionHouse
    function revealBid(uint64 auctionId, uint128 qty, uint128 price, bytes32 salt) external nonReentrant {
        Auction storage a = _auction(auctionId);
        if (a.kind != AuctionKind.REOPEN) revert WrongKind(uint8(a.kind));
        _window(a, AuctionPhase.COMMIT, a.deadlines[2], a.deadlines[3]);
        Bid storage b = _bids[auctionId][msg.sender];
        if (b.commitment == bytes32(0)) revert NoBid(auctionId, msg.sender);
        if (b.revealed) revert AlreadyBid(auctionId, msg.sender);
        bytes32 c =
            keccak256(abi.encode(block.chainid, address(this), auctionId, msg.sender, qty, price, salt));
        if (c != b.commitment) revert BadReveal();
        // QA-02: a reveal below R can never fill; it stays unrevealed, so its bond is forfeited at clearing like a
        // non-reveal's (a free commit slot would otherwise be free griefing)
        if (price < a.reserve) return;
        MarketParams memory p = market.marketParams(a.marketId);
        uint256 notional = _value(qty, price, p, Math.Rounding.Ceil);
        if (notional > b.maxNotional) revert RevealAboveMaxNotional(notional, b.maxNotional);
        if (notional < minNotional) revert BidTooSmall(notional, minNotional);
        (b.qty, b.price, b.revealed) = (qty, price, true);
        // the bond counts toward the payment (R-04)
        if (notional > b.escrow) {
            uint256 more = notional - b.escrow;
            b.escrow = uint128(notional);
            IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), more);
        }
        emit BidRevealed(auctionId, msg.sender, qty, price, b.escrow);
    }

    /// @inheritdoc IAuctionHouse
    function placeBid(uint64 auctionId, uint128 qty, uint128 price) external nonReentrant {
        Auction storage a = _auction(auctionId);
        if (a.kind == AuctionKind.REOPEN) revert WrongKind(uint8(a.kind));
        _window(a, AuctionPhase.OPEN_BIDDING, a.deadlines[1], a.deadlines[2]);
        // QA-02: a bid below the reserve fixed with the lot can never fill, so it may not take one of the 64 slots
        if (price < a.reserve) revert BidBelowReserve();
        MarketParams memory p = market.marketParams(a.marketId);
        uint256 notional = _value(qty, price, p, Math.Rounding.Ceil);
        if (notional < minNotional || notional == 0) revert BidTooSmall(notional, minNotional);
        Bid storage b = _newBid(auctionId, a);
        (b.qty, b.price, b.escrow, b.revealed) = (qty, price, uint128(notional), true);
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), notional);
        emit BidPlaced(auctionId, msg.sender, qty, price, notional);
    }

    /// @inheritdoc IAuctionHouse
    function claim(uint64 auctionId) external nonReentrant {
        Auction storage a = _auction(auctionId);
        if (a.phase != AuctionPhase.CLEARED) revert PhaseClosed(uint8(a.phase));
        Bid storage b = _bids[auctionId][msg.sender];
        if (b.claimed || b.escrow == 0 || !b.revealed) revert NothingToClaim();
        b.claimed = true;
        MarketParams memory p = market.marketParams(a.marketId);
        uint256 pay = b.fill == 0 ? 0 : _value(b.fill, a.pStar, p, Math.Rounding.Ceil);
        uint256 refund = b.escrow - pay;
        if (b.fill != 0) IERC20(p.collateralToken).safeTransfer(msg.sender, b.fill);
        if (refund != 0) IERC20(p.loanToken).safeTransfer(msg.sender, refund);
        emit Claimed(auctionId, msg.sender, b.fill, refund);
    }

    // ═════════════════════════════ GDA (F-4.5e) ═════════════════════════════

    /// @inheritdoc IAuctionHouse
    function startGda(
        bytes32 assetId,
        address token,
        uint256 qty,
        uint256 k,
        uint256 decay,
        uint256 emissionPerSec
    ) external onlyPool returns (uint64 id) {
        if (qty == 0 || k == 0 || decay == 0 || emissionPerSec == 0) revert InvalidParam();
        id = nextGdaId++;
        _gdas[id] = Gda({
            assetId: assetId,
            token: token,
            qty: uint128(qty),
            sold: 0,
            k: uint128(k),
            decay: uint128(decay),
            emissionPerSec: uint128(emissionPerSec),
            start: uint40(block.timestamp),
            active: true
        });
        emit GdaStarted(id, assetId, token, qty, k, decay, emissionPerSec, uint40(block.timestamp));
    }

    /// @inheritdoc IAuctionHouse
    /// @dev S4 (QA-01, QA-03, ADR-0113): only while the asset's clock is REGULAR (live price, the market open), never
    ///      below (1 − κ) × V_live, and the pool books the sale before the tokens leave (a receive hook sees final NAV).
    function gdaBuy(uint64 gdaId, uint256 qty, uint256 maxCost) external nonReentrant returns (uint256 cost) {
        Gda storage g = _gdas[gdaId];
        if (!g.active) revert UnknownGda(gdaId);
        ClockState st = clock.poke(g.assetId);
        if (st != ClockState.REGULAR) revert ActionNotAllowedInState(GDA_BUY, st);
        _checkHolder(g.token, msg.sender);
        cost = gdaPrice(gdaId, qty);
        if (cost > maxCost) revert CostAboveMax(cost, maxCost);
        g.sold += uint128(qty);
        if (g.sold == g.qty) g.active = false;
        IERC20(_loanToken()).safeTransferFrom(msg.sender, address(pool), cost);
        pool.onGdaSale(g.assetId, qty, cost);
        IERC20(g.token).safeTransfer(msg.sender, qty);
        emit GdaBought(gdaId, msg.sender, qty, cost);
    }

    /// @inheritdoc IAuctionHouse
    function closeGda(uint64 gdaId) external onlyPool nonReentrant returns (uint256 unsold) {
        Gda storage g = _gdas[gdaId];
        if (!g.active) revert UnknownGda(gdaId);
        g.active = false;
        unsold = g.qty - g.sold;
        if (unsold != 0) IERC20(g.token).safeTransfer(address(pool), unsold);
        pool.onGdaClosed(g.assetId, unsold);
        emit GdaClosed(gdaId, unsold);
    }

    /// @inheritdoc IAuctionHouse
    /// @dev GdaLib.cost: the continuous GDA price, floored at qty × (1 − κ) × V (ADR-0113).
    function gdaPrice(uint64 gdaId, uint256 qty) public view returns (uint256) {
        Gda storage g = _gdas[gdaId];
        if (!g.active) revert UnknownGda(gdaId);
        uint256 floorPrice = _oracle().valuationPrice(g.assetId).mulDiv(WAD - _engine().params().kappa, WAD);
        return GdaLib.cost(g, qty, floorPrice, _loanScale());
    }

    // ═════════════════════════════ views ═════════════════════════════

    /// @inheritdoc IAuctionHouse
    function allReopenLotsSettled(bytes32 venue_, uint64 epochId) external view returns (bool) {
        if (venue_ != venue) revert WrongVenue(venue_);
        return _epochUnsettled[epochId] == 0;
    }

    /// @inheritdoc IAuctionHouse
    function reopenSettled(bytes32 assetId, uint64 closureId) external view returns (bool) {
        return _reopenUnsettled[assetId][closureId] == 0;
    }

    /// @inheritdoc IAuctionHouse
    function auction(uint64 auctionId) external view returns (Auction memory) {
        return _auctions[auctionId];
    }

    /// @inheritdoc IAuctionHouse
    function bid(uint64 auctionId, address bidder) external view returns (Bid memory) {
        return _bids[auctionId][bidder];
    }

    /// @inheritdoc IAuctionHouse
    function bidders(uint64 auctionId) external view returns (address[] memory) {
        return _bidders[auctionId];
    }

    /// @inheritdoc IAuctionHouse
    function gda(uint64 gdaId) external view returns (Gda memory) {
        return _gdas[gdaId];
    }

    /// @notice REOPEN auctions of (asset, closure) not yet cleared and not yet settled.
    function reopenOutstanding(bytes32 assetId, uint64 closureId)
        external
        view
        returns (uint32 uncleared, uint32 unsettled)
    {
        return (_reopenUncleared[assetId][closureId], _reopenUnsettled[assetId][closureId]);
    }

    // ═════════════════════════════ internals ═════════════════════════════

    function _auction(uint64 id) internal view returns (Auction storage a) {
        a = _auctions[id];
        if (a.phase == AuctionPhase.NONE) revert UnknownAuction(id);
    }

    /// @dev `parent` ≠ 0: a tranche with the parent's schedule, reference price and epoch (§8.7.1).
    function _create(
        AuctionKind k,
        bytes32 marketId,
        bytes32 assetId,
        uint64 closureId,
        uint32 tranche,
        uint64 parent
    ) internal returns (uint64 id) {
        id = nextAuctionId++;
        Auction storage a = _auctions[id];
        (a.kind, a.phase, a.marketId, a.assetId, a.closureId, a.tranche) =
        (k, AuctionPhase.QUEUE, marketId, assetId, closureId, tranche);
        if (parent != 0) {
            Auction storage pa = _auctions[parent];
            (a.deadlines, a.startPrice, a.venueEpoch) = (pa.deadlines, pa.startPrice, pa.venueEpoch);
        } else {
            ClockData memory d = clock.closureInfo(assetId);
            uint40[4] memory o = timings[k];
            if (k == AuctionKind.REOPEN) {
                if (d.openPrintAt == 0) revert ReopenNotPending(assetId);
                uint40 base = d.openPrintAt + d.phaseExtension;
                a.deadlines = [base + o[0], base + o[1], base + o[2], base + o[3]];
                a.venueEpoch = d.venueEpoch;
            } else if (k == AuctionKind.PRECLOSE) {
                uint40 close = d.nextCloseAt;
                if (close == 0 || block.timestamp + o[0] >= close) revert TooLate(close - o[0]);
                a.deadlines = [close - o[0], close - o[1], close - o[2], close - o[3]];
            } else {
                uint40 base = uint40(block.timestamp);
                a.deadlines = [base + o[0], base + o[1], base + o[2], base + o[3]];
                a.startPrice = uint128(_oracle().valuationPrice(assetId)); // V_start (R-19)
            }
        }
        if (k == AuctionKind.REOPEN) {
            ++_reopenUncleared[assetId][closureId];
            ++_reopenUnsettled[assetId][closureId];
            ++_epochUnsettled[a.venueEpoch];
        }
        emit AuctionCreated(id, k, marketId, assetId, closureId, a.venueEpoch, tranche, a.deadlines);
    }

    /// @dev R and its final value at clearing (R-19): REOPEN (1 − κ)·P°; INTRADAY / EMERGENCY (1 − κ)·min(V_start,
    ///      V_clear); PRECLOSE (1 − κ_pre)·min(V_fix, V_clear), V_fix taken at lot fixing.
    function _reserve(Auction storage a, bool atClear) internal returns (uint256) {
        if (a.kind == AuctionKind.REOPEN) {
            uint256 kappa = _engine().params().kappa;
            return uint256(clock.closureInfo(a.assetId).openPrint).mulDiv(WAD - kappa, WAD);
        }
        uint256 v = _oracle().valuationPrice(a.assetId);
        if (a.kind == AuctionKind.PRECLOSE && !atClear) a.startPrice = uint128(v); // V_fix
        uint256 base = atClear ? Math.min(v, a.startPrice) : a.startPrice;
        uint256 k = a.kind == AuctionKind.PRECLOSE
            ? market.marketParams(a.marketId).precloseKappa
            : _engine().params().kappa;
        return base.mulDiv(WAD - k, WAD);
    }

    /// @dev engine.clear over the revealed bids; sets fills and p*; returns (Σ fills, Σ payments, forfeited bonds).
    function _clearBids(uint64 id, Auction storage a, MarketParams memory p, uint256 r)
        internal
        returns (uint256 filled, uint256 paid, uint256 bonds)
    {
        address[] storage list = _bidders[id];
        uint256 n = list.length;
        uint256[] memory qtys = new uint256[](n);
        uint256[] memory prices = new uint256[](n);
        bytes32[] memory keys = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            Bid storage b = _bids[id][list[i]];
            if (b.revealed) (qtys[i], prices[i]) = (b.qty, b.price);
            keys[i] = keccak256(abi.encode(id, list[i]));
        }
        (uint256 pStar, uint256[] memory fills,) = _engine().clear(qtys, prices, keys, a.lot, r);
        a.pStar = uint128(pStar);
        for (uint256 i; i < n; ++i) {
            Bid storage b = _bids[id][list[i]];
            if (!b.revealed) {
                // an unrevealed commit forfeits its bond to the pool (R-04)
                bonds += b.escrow;
                emit BondForfeited(id, list[i], b.escrow);
                b.escrow = 0;
                continue;
            }
            if (fills[i] == 0) continue;
            b.fill = uint128(fills[i]);
            filled += fills[i];
            paid += _value(fills[i], pStar, p, Math.Rounding.Ceil);
        }
        if (filled > a.lot) revert InvalidParam(); // the engine never fills more than Q
    }

    function _newBid(uint64 id, Auction storage a) internal returns (Bid storage b) {
        b = _bids[id][msg.sender];
        if (b.escrow != 0 || b.commitment != bytes32(0)) revert AlreadyBid(id, msg.sender);
        if (a.bidCount >= maxBids) revert TooManyBids();
        _checkHolder(market.marketParams(a.marketId).collateralToken, msg.sender);
        ++a.bidCount;
        _bidders[id].push(msg.sender);
    }

    function _window(Auction storage a, AuctionPhase phase, uint40 from, uint40 to) internal view {
        if (a.phase != phase) revert PhaseClosed(uint8(a.phase));
        if (block.timestamp < from) revert TooEarly(from);
        if (block.timestamp >= to) revert TooLate(to);
    }

    /// @dev R-02 / §8.7.3.7: `canHold` if the collateral token exposes it, else a Robinhood Stock Token's blocklist
    ///      (ADR-0120); a token with neither accepts anyone.
    function _checkHolder(address token, address who) internal view {
        if (TokenProbe.blocked(token, who)) revert NotAllowlisted(who);
    }

    function _reopenCleared(Auction storage a) internal {
        if (a.kind == AuctionKind.REOPEN) --_reopenUncleared[a.assetId][a.closureId];
    }

    function _markSettled(uint64 id, Auction storage a) internal {
        a.settled = true;
        if (a.kind == AuctionKind.REOPEN) {
            --_reopenUnsettled[a.assetId][a.closureId];
            --_epochUnsettled[a.venueEpoch];
        }
        emit LotSettled(id);
    }

    /// @dev §8.7.3.6: the last REOPEN tranche of (asset, closure) cleared after the queue window → REOPEN is over.
    function _maybeCompleteReopen(bytes32 assetId, uint64 closureId) internal {
        if (_reopenUncleared[assetId][closureId] != 0) return;
        ClockData memory d = clock.closureInfo(assetId);
        if (!d.reopenPending || d.closureId != closureId || d.openPrintAt == 0) return;
        if (block.timestamp < uint256(d.openPrintAt) + REOPEN_QUEUE + d.phaseExtension) return;
        clock.markReopenComplete(assetId, closureId);
        emit ReopenCompleted(assetId, closureId, d.venueEpoch);
    }

    function _value(uint256 qty, uint256 price, MarketParams memory p, Math.Rounding rnd)
        internal
        view
        returns (uint256)
    {
        return qty.mulDiv(price, 10 ** IERC20Metadata(p.collateralToken).decimals() * _scale(p), rnd);
    }

    function _scale(MarketParams memory p) internal view returns (uint256) {
        return 10 ** (18 - IERC20Metadata(p.loanToken).decimals());
    }

    function _loanToken() internal view returns (address) {
        return pool.asset();
    }

    function _loanScale() internal view returns (uint256) {
        return 10 ** (18 - IERC20Metadata(_loanToken()).decimals());
    }

    function _engine() internal view returns (IRiskEngine) {
        return IRiskEngine(market.wiring().engine);
    }

    function _oracle() internal view returns (IOracleAdapter) {
        return IOracleAdapter(market.wiring().oracle);
    }

    function _tip(uint8 job) internal {
        uint256 g = gasleft();
        try tips.pay(msg.sender, job) {}
        catch {
            GasGuard.check(g);
        }
    }
}
