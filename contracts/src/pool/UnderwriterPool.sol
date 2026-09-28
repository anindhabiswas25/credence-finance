// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    CoverRequest,
    Epoch,
    EpochPhase,
    Inventory,
    Session,
    ClockData,
    KeeperJob
} from "../libraries/Types.sol";
import {PackedInt} from "../libraries/PackedInt.sol";
import {PoolLib} from "./PoolLib.sol";
import {GasGuard} from "../libraries/GasGuard.sol";
import {IUnderwriterPool} from "../interfaces/IUnderwriterPool.sol";
import {ICredenceMarket} from "../interfaces/ICredenceMarket.sol";
import {IRiskEngine} from "../interfaces/IRiskEngine.sol";
import {IAuctionHouse} from "../interfaces/IAuctionHouse.sol";
import {IAssetClock} from "../interfaces/IAssetClock.sol";
import {ICalendarStore} from "../interfaces/ICalendarStore.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IKeeperTips} from "../interfaces/IKeeperTips.sol";

/// @title UnderwriterPool: junior first-loss capital of one lending stack (Build Guide §8.6, R-09..R-13).
/// @notice Sells Gap Cover per venue closure (an **epoch**, R-10), earns premiums, risk fees, ⅓ of penalties and
///         forfeited bonds, pays every shortfall first, and buys unsold auction lots at the reserve (backstop), which
///         it resells by GDA. Shares (`cfUP-EQ` / `cfUP-NAV`) are a plain transferable ERC-20; escrowed withdrawal
///         shares and minted-but-unclaimed deposit shares sit in this contract. Design choices: ADR-0110.
/// @dev Units: `nav`, cash, premiums in loan-token units; share price in WAD of loan units per share scaled to 18
///      decimals (1e18 = one loan-token unit of 18-decimal value per share, i.e. $1 per share for USDC). Shares have 18
///      decimals; virtual shares / assets (S, 1) protect the first deposit.
contract UnderwriterPool is ERC20, ReentrancyGuardTransient, IUnderwriterPool {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint40 internal constant BELL_WINDOW = 2 hours; // §8.2.2
    uint40 internal constant BELL_DEADLINE = 15 minutes;
    uint256 internal constant GDA_START_MARKUP = 1.02e18; // F-4.5e: k = 1.02 × V
    uint256 internal constant GDA_DECAY = 8_022_536_812_036; // ln 2 / 86,400 s (WAD per second): half-life 24 h
    uint256 internal constant GDA_EMISSION_PERIOD = 3 days; // r_e = inventory / 3 days
    uint256 internal constant MAX_WITHDRAW_EPOCHS = 64; // scanned for FIFO priority

    // ───────────── configuration ─────────────
    address public immutable timelock;
    IERC20 internal immutable _asset;
    bytes32 public immutable venue;
    uint256 internal immutable _scale; // S = 10^(18 − loan decimals)

    address public market;
    address public auctionHouse;
    address public settlement;
    IAssetClock public clock;
    ICalendarStore public calendar;
    IKeeperTips public tips;
    /// @notice Minimum time after an epoch's scheduled reopen before it can settle (REOPEN auctions: 7 min + ext).
    uint40 public settleDelay = 10 minutes;
    /// @notice Epochs below this calendar index predate the pool and count as settled.
    uint64 public startEpoch;

    // ───────────── epochs ─────────────
    mapping(uint64 epochId => Epoch) internal _epochs;
    uint64 internal _active;
    bool internal _hasActive;
    /// @dev The aggregate K-loss vector of `_vecEpoch` (4 × uint64 per word). A new epoch overwrites it (ADR-0110 §4).
    uint256[] internal _lossVec;
    uint64 internal _vecEpoch;
    bool internal _vecSet;
    uint64 public nextPolicyId = 1;
    /// @dev R-11: Σ over an epoch's policies on an asset of max_j L_{p,j}.
    mapping(uint64 epochId => mapping(bytes32 assetId => uint256)) internal _worstCovered;
    mapping(uint64 epochId => bytes32[]) internal _epochAssets;
    mapping(uint64 epochId => mapping(bytes32 assetId => uint256)) internal _lossReserve;
    uint256 internal _totalLossReserve;

    // ───────────── underwriter queues ─────────────
    mapping(uint64 epochId => mapping(address owner => uint256)) internal _depositOf;
    uint256 internal _queuedDeposits; // Σ depositAssetsQueued of unsettled epochs
    mapping(uint64 epochId => mapping(address owner => uint256)) internal _withdrawOf;
    mapping(uint64 epochId => mapping(address owner => uint256)) internal _withdrawPaid;
    mapping(uint64 epochId => uint256) internal _epochPaid;
    mapping(uint64 epochId => uint32) internal _withdrawers;
    uint256 internal _reservedUnpaid; // Σ reserved − paid over settled epochs
    uint64[] internal _withdrawEpochs; // settled epochs with reserved withdrawals, oldest first
    uint256 internal _withdrawHead;

    // ───────────── backstop inventory ─────────────
    mapping(bytes32 assetId => Inventory) internal _inventory;
    bytes32[] internal _inventoryAssets;

    event WiringInitialized(
        address market, address auctionHouse, address settlement, address clock, address tips
    );
    event SettleDelaySet(uint40 delay);

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert Unauthorized();
        _;
    }

    modifier onlyMarket() {
        if (msg.sender != market || market == address(0)) revert Unauthorized();
        _;
    }

    modifier onlyAuctionHouse() {
        if (msg.sender != auctionHouse || auctionHouse == address(0)) revert Unauthorized();
        _;
    }

    constructor(address timelock_, IERC20 asset_, bytes32 venue_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {
        if (timelock_ == address(0) || address(asset_) == address(0)) revert ZeroAddress();
        if (venue_ == bytes32(0)) revert WrongVenue(venue_);
        timelock = timelock_;
        _asset = asset_;
        venue = venue_;
        _scale = 10 ** (18 - IERC20Metadata(address(asset_)).decimals());
    }

    /// @notice Once, by the timelock. `settlement_` is the NAV stack's adapter (0 on the equity stack). Epochs before
    ///         the first one whose Bell window has not opened yet count as settled.
    function initializeWiring(
        address market_,
        address auctionHouse_,
        address settlement_,
        address clock_,
        address tips_
    ) external onlyTimelock {
        if (market != address(0)) revert AlreadyWired();
        if (market_ == address(0) || clock_ == address(0) || tips_ == address(0)) revert ZeroAddress();
        if (auctionHouse_ == address(0) && settlement_ == address(0)) revert ZeroAddress();
        market = market_;
        auctionHouse = auctionHouse_;
        settlement = settlement_;
        clock = IAssetClock(clock_);
        calendar = ICalendarStore(IAssetClock(clock_).calendar());
        tips = IKeeperTips(tips_);
        startEpoch = _nextUnopened(uint40(block.timestamp));
        emit WiringInitialized(market_, auctionHouse_, settlement_, clock_, tips_);
    }

    function setSettleDelay(uint40 d) external onlyTimelock {
        if (d > 1 days) revert InvalidParam();
        settleDelay = d;
        emit SettleDelaySet(d);
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    // ═════════════════════════════ underwriters ═════════════════════════════

    /// @inheritdoc IUnderwriterPool
    function deposit(uint256 assets, address receiver)
        external
        nonReentrant
        returns (uint256 sharesOrTicket)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        (uint64 e, bool queue) = _depositEpoch();
        if (queue) {
            // the NAV is read before the cash arrives, so queued cash never moves the price
            _asset.safeTransferFrom(msg.sender, address(this), assets);
            _depositOf[e][receiver] += assets;
            _epochs[e].depositAssetsQueued += uint128(assets);
            _queuedDeposits += assets;
            emit DepositQueued(e, receiver, assets);
            return 0;
        }
        uint256 n = nav();
        sharesOrTicket = assets.mulDiv(totalSupply() + _scale, n + 1);
        if (sharesOrTicket == 0) revert ZeroAmount();
        _asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, sharesOrTicket);
        emit Deposited(msg.sender, receiver, assets, sharesOrTicket);
    }

    /// @inheritdoc IUnderwriterPool
    function requestWithdraw(uint256 shares) external nonReentrant returns (uint64 epochId) {
        if (shares == 0) revert ZeroAmount();
        uint256 bal = balanceOf(msg.sender);
        if (bal < shares) revert InsufficientShares(bal, shares);
        epochId = _nextUnopened(uint40(block.timestamp));
        _transfer(msg.sender, address(this), shares);
        if (_withdrawOf[epochId][msg.sender] == 0) ++_withdrawers[epochId];
        _withdrawOf[epochId][msg.sender] += shares;
        _epochs[epochId].withdrawSharesQueued += uint128(shares);
        emit WithdrawRequested(epochId, msg.sender, shares);
    }

    /// @inheritdoc IUnderwriterPool
    function claimWithdraw(uint64 epochId) external nonReentrant returns (uint256 assets) {
        Epoch storage ep = _epochs[epochId];
        if (ep.phase != EpochPhase.SETTLED) revert EpochNotSettled(epochId);
        uint256 shares = _withdrawOf[epochId][msg.sender];
        if (shares == 0) revert NothingToClaim();
        uint256 owed = shares.mulDiv(ep.withdrawAssetsReserved, ep.withdrawSharesQueued)
            - _withdrawPaid[epochId][msg.sender];
        if (owed == 0) revert NothingToClaim();
        // FIFO (§8.6.3): older epochs' unpaid withdrawals have priority on the cash
        uint256 cash = _asset.balanceOf(address(this));
        uint256 older = _olderUnpaid(epochId);
        uint256 avail = cash > _queuedDeposits + older ? cash - _queuedDeposits - older : 0;
        assets = Math.min(owed, avail);
        if (assets == 0) revert NothingToClaim();
        _withdrawPaid[epochId][msg.sender] += assets;
        _epochPaid[epochId] += assets;
        _reservedUnpaid -= assets;
        _asset.safeTransfer(msg.sender, assets);
        emit WithdrawClaimed(epochId, msg.sender, assets, owed - assets);
    }

    /// @inheritdoc IUnderwriterPool
    function claimDeposit(uint64 epochId) external nonReentrant returns (uint256 shares) {
        Epoch storage ep = _epochs[epochId];
        if (ep.phase != EpochPhase.SETTLED) revert EpochNotSettled(epochId);
        uint256 a = _depositOf[epochId][msg.sender];
        if (a == 0) revert NothingToClaim();
        _depositOf[epochId][msg.sender] = 0;
        shares = a.mulDiv(ep.depositSharesMinted, ep.depositAssetsQueued);
        _transfer(address(this), msg.sender, shares);
        emit DepositClaimed(epochId, msg.sender, shares);
    }

    // ═════════════════════════════ cover ═════════════════════════════

    /// @inheritdoc IUnderwriterPool
    function previewCover(CoverRequest calldata r) external view returns (uint256 premium, uint256 uAfter) {
        (premium, uAfter,,) = _quote(r, _currentVector(r.epochId), _equity(r.epochId));
    }

    /// @inheritdoc IUnderwriterPool
    function writeCover(CoverRequest calldata r, uint256 maxPremium)
        external
        onlyMarket
        nonReentrant
        returns (uint64 policyId, uint256 premium)
    {
        uint64 e = r.epochId;
        _ensureOpen(e);
        Epoch storage ep = _epochs[e];
        if (block.timestamp >= ep.closeAt) revert CoverWindowClosed();
        if (ep.phase == EpochPhase.OPEN && block.timestamp >= ep.bellAt) _snapshot(e, ep);
        uint256[] memory current = _currentVector(e);
        uint256 uAfter;
        uint256 worst;
        uint256[] memory add;
        (premium, uAfter, worst, add) = _quote(r, current, _equity(e));
        if (premium > maxPremium) revert PremiumAboveMax(premium, maxPremium);
        if (current.length == 0) current = new uint256[](add.length); // first policy of the epoch
        uint256 k = add.length * PackedInt.U64_PER_WORD;
        uint256[] memory sum = PackedInt.addU64(current, add, k);
        _storeVector(e, sum);
        uint256 w = PackedInt.maxU64(add, k);
        if (_worstCovered[e][r.assetId] == 0) _epochAssets[e].push(r.assetId);
        _worstCovered[e][r.assetId] += w == 0 ? 1 : w; // ≥ 1 marks the asset as covered in this epoch
        ep.premiums += uint128(premium);
        ++ep.policies;
        policyId = nextPolicyId++;
        emit CoverWritten(policyId, r.marketId, r.borrower, e, r.assetId, premium, uAfter, worst);
    }

    // ═════════════════════════════ income ═════════════════════════════

    /// @inheritdoc IUnderwriterPool
    function creditRiskFee(uint256 assets) external onlyMarket {
        (uint64 e, bool a) = (_active, _hasActive);
        if (a) _epochs[e].riskFees += uint128(assets);
        emit RiskFeeCredited(a ? e : 0, assets);
    }

    /// @inheritdoc IUnderwriterPool
    function creditPenalty(uint256 assets) external onlyMarket {
        (uint64 e, bool a) = (_active, _hasActive);
        if (a) _epochs[e].penalties += uint128(assets);
        emit PenaltyCredited(a ? e : 0, assets);
    }

    /// @inheritdoc IUnderwriterPool
    function creditBond(uint256 assets) external onlyAuctionHouse {
        (uint64 e, bool a) = (_active, _hasActive);
        if (a) _epochs[e].bonds += uint128(assets);
        emit BondCredited(a ? e : 0, assets);
    }

    // ═════════════════════════════ losses and backstop ═════════════════════════════

    /// @inheritdoc IUnderwriterPool
    function payShortfall(uint256 s) external onlyMarket nonReentrant returns (uint256 paid) {
        paid = Math.min(s, freeCash());
        (uint64 e, bool a) = (_active, _hasActive);
        if (a) _epochs[e].lossesPaid += uint128(paid);
        if (paid != 0) _asset.safeTransfer(msg.sender, paid);
        emit ShortfallPaid(a ? e : 0, s, paid);
    }

    /// @inheritdoc IUnderwriterPool
    function backstopBuy(uint64 auctionId, bytes32 assetId, address token, uint256 qty, uint256 price)
        external
        onlyAuctionHouse
        nonReentrant
        returns (uint256 paid)
    {
        uint256 value = qty.mulDiv(price, 10 ** IERC20Metadata(token).decimals() * _scale);
        paid = Math.min(value, freeCash());
        Inventory storage inv = _inventory[assetId];
        if (inv.token == address(0)) {
            inv.token = token;
            _inventoryAssets.push(assetId);
        } else if (inv.token != token) {
            revert InvalidParam();
        }
        inv.qty += uint128(qty);
        inv.cost += uint128(paid);
        if (paid != 0) _asset.safeTransfer(msg.sender, paid);
        emit BackstopBought(_hasActive ? _active : 0, assetId, qty, price, paid);
        auctionId; // identifies the auction in the auction house's own events
    }

    /// @inheritdoc IUnderwriterPool
    function resellInventory(bytes32 assetId) external nonReentrant returns (uint64 gdaId) {
        Inventory storage inv = _inventory[assetId];
        if (inv.gdaId != 0) revert GdaRunning(inv.gdaId);
        uint256 free = inv.qty - inv.inGda;
        if (free == 0) revert NoInventory(assetId);
        uint256 v = _oracle().valuationPrice(assetId);
        uint256 k = v.mulDiv(GDA_START_MARKUP, WAD);
        uint256 emission = free / GDA_EMISSION_PERIOD;
        if (emission == 0) emission = 1;
        inv.inGda = uint128(inv.qty);
        IERC20(inv.token).safeTransfer(auctionHouse, free);
        gdaId = IAuctionHouse(auctionHouse).startGda(assetId, inv.token, free, k, GDA_DECAY, emission);
        inv.gdaId = gdaId;
        emit InventoryListed(assetId, gdaId, free);
        _tip();
    }

    /// @notice Ends a running GDA whose emission period is over (or at once, by the timelock); unsold tokens return.
    function closeResale(bytes32 assetId) external nonReentrant {
        Inventory storage inv = _inventory[assetId];
        uint64 g = inv.gdaId;
        if (g == 0) revert NoInventory(assetId);
        if (
            msg.sender != timelock
                && block.timestamp < IAuctionHouse(auctionHouse).gda(g).start + GDA_EMISSION_PERIOD
        ) {
            revert TooEarly(uint40(IAuctionHouse(auctionHouse).gda(g).start + GDA_EMISSION_PERIOD));
        }
        IAuctionHouse(auctionHouse).closeGda(g); // calls back onGdaClosed
    }

    /// @inheritdoc IUnderwriterPool
    function onGdaSale(bytes32 assetId, uint256 qty, uint256 proceeds) external onlyAuctionHouse {
        Inventory storage inv = _inventory[assetId];
        uint256 costPart = uint256(inv.cost).mulDiv(qty, inv.qty);
        inv.qty -= uint128(qty);
        inv.inGda -= uint128(qty);
        inv.cost -= uint128(costPart);
        if (inv.inGda == 0) inv.gdaId = 0;
        int256 pnl = int256(proceeds) - int256(costPart);
        if (_hasActive) _epochs[_active].backstopPnl += int128(pnl);
        emit InventorySold(assetId, qty, proceeds, pnl);
    }

    /// @inheritdoc IUnderwriterPool
    function onGdaClosed(bytes32 assetId, uint256 qty) external onlyAuctionHouse {
        Inventory storage inv = _inventory[assetId];
        inv.inGda -= uint128(qty);
        inv.gdaId = 0;
    }

    /// @inheritdoc IUnderwriterPool
    function fallbackAdvance(bytes32, uint256, uint256) external pure returns (uint256) {
        revert NotImplemented(); // S4 (NAV settlement)
    }

    // ═════════════════════════════ lifecycle ═════════════════════════════

    /// @inheritdoc IUnderwriterPool
    function openEpoch(bytes32 venue_) external nonReentrant {
        if (venue_ != venue) revert WrongVenue(venue_);
        (uint64 e, bool inWindow) = _bellWindowEpoch(uint40(block.timestamp));
        if (!inWindow) revert NotInBellWindow(0, 0);
        if (_epochs[e].phase != EpochPhase.NONE) revert EpochStillOpen(e);
        _open(e);
        _tip();
    }

    /// @inheritdoc IUnderwriterPool
    function snapshotEpoch(uint64 epochId) external nonReentrant {
        Epoch storage ep = _epochs[epochId];
        if (!_hasActive || _active != epochId || ep.phase != EpochPhase.OPEN) revert EpochNotOpen(epochId);
        if (block.timestamp < ep.bellAt) revert SnapshotTooEarly(ep.bellAt);
        _snapshot(epochId, ep);
        _tip();
    }

    /// @inheritdoc IUnderwriterPool
    function settleEpoch(uint64 epochId) external nonReentrant {
        Epoch storage ep = _epochs[epochId];
        if (ep.phase == EpochPhase.SETTLED || epochId < startEpoch) revert EpochAlreadySettled(epochId);
        if (ep.phase == EpochPhase.NONE) {
            // never opened (no cover): settle it on its own schedule so its queues are processed
            if (_hasActive && _active < epochId) revert EpochStillOpen(_active);
            _setTimes(epochId, ep);
            ep.navBefore = uint128(nav());
        } else if (!_hasActive || _active != epochId) {
            revert EpochNotOpen(epochId);
        }
        if (ep.reopenAt == 0 || block.timestamp < uint256(ep.reopenAt) + settleDelay) {
            revert EpochNotReady(epochId, 1);
        }
        if (auctionHouse != address(0) && !IAuctionHouse(auctionHouse).allReopenLotsSettled(venue, epochId)) {
            revert EpochNotReady(epochId, 2);
        }
        // R-11: an asset whose REOPEN has not completed keeps its worst covered loss in reserve
        bytes32[] storage assets = _epochAssets[epochId];
        uint256 reserve;
        for (uint256 i; i < assets.length; ++i) {
            if (!_reopenDone(assets[i], epochId)) {
                uint256 x = _worstCovered[epochId][assets[i]];
                _lossReserve[epochId][assets[i]] = x;
                reserve += x;
            }
        }
        _totalLossReserve += reserve;
        ep.pendingLossReserve = uint128(reserve);
        if (_hasActive && _active == epochId) _hasActive = false; // releases the premiums into NAV
        ep.phase = EpochPhase.SETTLED;

        uint256 navAfter = nav();
        uint256 price = _price(navAfter, totalSupply());
        ep.navAfter = uint128(navAfter);
        ep.sharePriceAfter = uint128(price);
        emit EpochSettled(
            epochId,
            ep.premiums,
            ep.riskFees,
            ep.penalties,
            ep.bonds,
            ep.backstopPnl,
            ep.lossesPaid,
            reserve,
            navAfter,
            price
        );
        _processQueues(epochId, ep, price);
        _tip();
    }

    /// @inheritdoc IUnderwriterPool
    function releaseLossReserve(uint64 epochId, bytes32 assetId) external nonReentrant {
        uint256 x = _lossReserve[epochId][assetId];
        if (x == 0 || !_reopenDone(assetId, epochId)) revert ReserveNotReleasable(epochId, assetId);
        _lossReserve[epochId][assetId] = 0;
        _totalLossReserve -= x;
        emit LossReserveReleased(epochId, assetId, x);
    }

    // ═════════════════════════════ views ═════════════════════════════

    /// @inheritdoc IUnderwriterPool
    function nav() public view returns (uint256) {
        uint256 plus = _asset.balanceOf(address(this)) + PoolLib.feeReceivable(market)
            + PoolLib.inventoryValue(_inventory, _inventoryAssets, market, _scale);
        uint256 minus = unearnedPremiums() + _totalLossReserve + _queuedDeposits + _reservedUnpaid;
        return plus > minus ? plus - minus : 0;
    }

    /// @inheritdoc IUnderwriterPool
    function sharePrice() external view returns (uint256) {
        return _price(nav(), totalSupply());
    }

    /// @inheritdoc IUnderwriterPool
    function utilisation(uint64 epochId) external view returns (uint256 u) {
        (, u,) = _capacity(_currentVector(epochId), _zeros(), _equity(epochId), bytes32(0), 0);
    }

    /// @inheritdoc IUnderwriterPool
    function capacityHeadroom(uint64 epochId) external view returns (uint256) {
        uint256 j = _equity(epochId);
        (,, uint256 worst) = _capacity(_currentVector(epochId), _zeros(), j, bytes32(0), 0);
        uint256 cap = j.mulDiv(_engine().params().uMax, WAD);
        return cap > worst ? cap - worst : 0;
    }

    /// @inheritdoc IUnderwriterPool
    function epoch(uint64 epochId) external view returns (Epoch memory) {
        return _epochs[epochId];
    }

    /// @inheritdoc IUnderwriterPool
    function currentEpoch(bytes32 venue_) external view returns (uint64) {
        if (venue_ != venue) revert WrongVenue(venue_);
        if (_hasActive) return _active;
        return _nextUnopened(uint40(block.timestamp));
    }

    /// @inheritdoc IUnderwriterPool
    function activeEpoch() external view returns (uint64, bool) {
        return (_active, _hasActive);
    }

    /// @inheritdoc IUnderwriterPool
    function freeCash() public view returns (uint256) {
        uint256 cash = _asset.balanceOf(address(this));
        uint256 held = _queuedDeposits + _reservedUnpaid;
        return cash > held ? cash - held : 0;
    }

    /// @inheritdoc IUnderwriterPool
    function unearnedPremiums() public view returns (uint256) {
        return _hasActive ? _epochs[_active].premiums : 0;
    }

    /// @inheritdoc IUnderwriterPool
    function pendingLossReserve() external view returns (uint256) {
        return _totalLossReserve;
    }

    /// @inheritdoc IUnderwriterPool
    function inventory(bytes32 assetId) external view returns (Inventory memory) {
        return _inventory[assetId];
    }

    /// @inheritdoc IUnderwriterPool
    function pendingDeposit(uint64 epochId, address owner) external view returns (uint256) {
        return _depositOf[epochId][owner];
    }

    /// @inheritdoc IUnderwriterPool
    function pendingWithdraw(uint64 epochId, address owner) external view returns (uint256, uint256) {
        return (_withdrawOf[epochId][owner], _withdrawPaid[epochId][owner]);
    }

    /// @inheritdoc IUnderwriterPool
    function lossReserve(uint64 epochId, bytes32 assetId) external view returns (uint256) {
        return _lossReserve[epochId][assetId];
    }

    /// @notice The aggregate K-loss vector of the active epoch (empty if none has a policy).
    function lossVector() external view returns (uint256[] memory) {
        return _currentVector(_active);
    }

    function inventoryAssets() external view returns (bytes32[] memory) {
        return _inventoryAssets;
    }

    function worstCovered(uint64 epochId, bytes32 assetId) external view returns (uint256) {
        return _worstCovered[epochId][assetId];
    }

    function reservedUnpaid() external view returns (uint256) {
        return _reservedUnpaid;
    }

    function queuedDeposits() external view returns (uint256) {
        return _queuedDeposits;
    }

    // ═════════════════════════════ internals: epochs ═════════════════════════════

    function _open(uint64 e) internal {
        if (_hasActive) revert EpochStillOpen(_active);
        if (e < startEpoch) revert EpochAlreadySettled(e);
        Epoch storage ep = _epochs[e];
        _setTimes(e, ep);
        ep.phase = EpochPhase.OPEN;
        ep.navBefore = uint128(nav());
        (_active, _hasActive) = (e, true);
        emit EpochOpened(
            e,
            venue,
            ep.bellWindowAt,
            ep.bellAt,
            ep.closeAt,
            ep.reopenAt,
            ep.navBefore,
            ep.withdrawSharesQueued
        );
    }

    /// @dev writeCover opens the epoch itself when the keeper has not (the Bell window must be open).
    function _ensureOpen(uint64 e) internal {
        if (_hasActive) {
            if (_active != e) revert PolicyEpochMismatch(e, _active);
            return;
        }
        (uint64 w, bool inWindow) = _bellWindowEpoch(uint40(block.timestamp));
        if (!inWindow || w != e) revert EpochNotOpen(e);
        if (_epochs[e].phase != EpochPhase.NONE) revert EpochNotOpen(e);
        _open(e);
    }

    function _snapshot(uint64 e, Epoch storage ep) internal {
        uint256 j = nav();
        ep.equityAtRisk = uint128(j);
        ep.phase = EpochPhase.SNAPSHOT;
        uint256[] memory v = _currentVector(e);
        emit EpochSnapshotted(
            e, j, v.length == 0 ? 0 : PackedInt.maxU64(v, v.length * PackedInt.U64_PER_WORD)
        );
    }

    function _setTimes(uint64 e, Epoch storage ep) internal {
        ICalendarStore cal = calendar;
        uint256 n = cal.sessionCount(venue);
        if (e >= n) revert NoCalendarCoverage(venue);
        Session memory s = cal.session(venue, e);
        ep.epochId = e;
        ep.closeAt = s.close;
        ep.bellWindowAt = s.close - BELL_WINDOW;
        ep.bellAt = s.close - BELL_DEADLINE;
        ep.reopenAt = e + 1 < n ? cal.session(venue, e + 1).open : 0;
    }

    function _processQueues(uint64 e, Epoch storage ep, uint256 price) internal {
        uint256 w = ep.withdrawSharesQueued;
        uint256 reserved;
        if (w != 0) {
            reserved = w.mulDiv(price, WAD * _scale);
            _burn(address(this), w);
            ep.withdrawAssetsReserved = uint128(reserved);
            _reservedUnpaid += reserved;
            _withdrawEpochs.push(e);
        }
        uint256 d = ep.depositAssetsQueued;
        uint256 minted;
        if (d != 0) {
            minted = d.mulDiv(WAD * _scale, price);
            _queuedDeposits -= d;
            ep.depositSharesMinted = uint128(minted);
            _mint(address(this), minted);
        }
        emit EpochQueuesProcessed(e, w, reserved, d, minted);
    }

    /// @dev Unpaid reserved withdrawals of settled epochs older than `e`. Epochs whose remainder is rounding dust
    ///      (≤ 1 unit per withdrawer) are skipped and the head moves past them.
    function _olderUnpaid(uint64 e) internal view returns (uint256 sum) {
        uint256 n = _withdrawEpochs.length;
        for (uint256 i = _withdrawHead; i < n && i < _withdrawHead + MAX_WITHDRAW_EPOCHS; ++i) {
            uint64 x = _withdrawEpochs[i];
            if (x >= e) break;
            uint256 left = _epochs[x].withdrawAssetsReserved - _epochPaid[x];
            if (left > _withdrawers[x]) sum += left;
        }
    }

    function _depositEpoch() internal view returns (uint64 e, bool queue) {
        if (_hasActive) return (_active, true);
        uint40 t = uint40(block.timestamp);
        (uint64 w, bool inWindow) = _bellWindowEpoch(t);
        if (inWindow) return (w, w >= startEpoch);
        // after a close and before that closure settles (or its reopen + delay passes, if it was never opened)
        uint64 c = _lastClosed(t);
        if (c == type(uint64).max || c < startEpoch) return (0, false);
        Epoch storage ep = _epochs[c];
        if (ep.phase == EpochPhase.SETTLED) return (0, false);
        uint40 reopen =
            c + 1 < calendar.sessionCount(venue) ? calendar.session(venue, c + 1).open : type(uint40).max;
        if (uint256(t) < uint256(reopen) + settleDelay || ep.depositAssetsQueued != 0) return (c, true);
        return (0, false);
    }

    /// @dev The epoch whose Bell window [close − 2 h, close) contains `t`.
    function _bellWindowEpoch(uint40 t) internal view returns (uint64 e, bool inWindow) {
        (uint256 i, bool found) = calendar.findSession(venue, t);
        if (!found) return (0, false);
        Session memory s = calendar.session(venue, i);
        if (t >= s.close - BELL_WINDOW && t < s.close) return (uint64(i), true);
        return (uint64(i), false);
    }

    /// @dev The first epoch whose Bell window has not opened at `t`.
    function _nextUnopened(uint40 t) internal view returns (uint64) {
        (uint256 i, bool found) = calendar.findSession(venue, t);
        if (!found) revert NoCalendarCoverage(venue);
        return t >= calendar.session(venue, i).close - BELL_WINDOW ? uint64(i + 1) : uint64(i);
    }

    /// @dev The latest session whose close is ≤ t (type(uint64).max if none).
    function _lastClosed(uint40 t) internal view returns (uint64) {
        (uint256 i, bool found) = calendar.findSession(venue, t);
        if (!found) {
            uint256 n = calendar.sessionCount(venue);
            return n == 0 ? type(uint64).max : uint64(n - 1);
        }
        if (t >= calendar.session(venue, i).close) return uint64(i);
        return i == 0 ? type(uint64).max : uint64(i - 1);
    }

    /// @dev An asset's REOPEN for epoch `e` is over: no closure of it at or after `e` is still pending, and its
    ///      REOPEN lots have settled.
    function _reopenDone(bytes32 assetId, uint64 e) internal view returns (bool) {
        ClockData memory d = clock.closureInfo(assetId);
        if (d.reopenPending && d.venueEpoch >= e) return false;
        return auctionHouse == address(0) || IAuctionHouse(auctionHouse).reopenSettled(assetId, d.closureId);
    }

    // ═════════════════════════════ internals: capacity ═════════════════════════════

    function _quote(CoverRequest calldata r, uint256[] memory current, uint256 j)
        internal
        view
        returns (uint256 premium, uint256 uAfter, uint256 worst, uint256[] memory add)
    {
        IRiskEngine eng = _engine();
        add = eng.coverLossVector(r.assetId, r.closureType, r.collateralValue, r.debtProjected);
        if (current.length == 0) current = new uint256[](add.length);
        bool ok;
        (ok, uAfter, worst) = PoolLib.capacity(market, eng, current, add, j, r.marketId, r.collateralValue);
        if (!ok) revert CapacityExceeded(uAfter, eng.params().uMax);
        (premium,,) = eng.quoteCover(
            r.assetId, r.closureType, r.closureDays, r.collateralValue, r.debtProjected, uAfter
        );
    }

    function _capacity(
        uint256[] memory current,
        uint256[] memory add,
        uint256 j,
        bytes32 skipId,
        uint256 skipValue
    ) internal view returns (bool, uint256, uint256) {
        return PoolLib.capacity(market, _engine(), current, add, j, skipId, skipValue);
    }

    function _currentVector(uint64 e) internal view returns (uint256[] memory v) {
        if (!_vecSet || _vecEpoch != e) return v; // empty = zeros
        v = _lossVec;
    }

    function _storeVector(uint64 e, uint256[] memory v) internal {
        uint256 n = v.length;
        if (_lossVec.length != n) {
            delete _lossVec;
            for (uint256 i; i < n; ++i) {
                _lossVec.push(v[i]);
            }
        } else {
            for (uint256 i; i < n; ++i) {
                _lossVec[i] = v[i];
            }
        }
        (_vecEpoch, _vecSet) = (e, true);
    }

    function _zeros() internal pure returns (uint256[] memory z) {}

    /// @dev J: the Bell-deadline snapshot once taken, else the live NAV.
    function _equity(uint64 e) internal view returns (uint256) {
        Epoch storage ep = _epochs[e];
        if (_hasActive && _active == e && ep.phase == EpochPhase.SNAPSHOT) return ep.equityAtRisk;
        return nav();
    }

    // ═════════════════════════════ internals: NAV ═════════════════════════════

    /// @dev WAD price per share (18 decimals): (nav + 1) × S × 1e18 / (supply + S).
    function _price(uint256 n, uint256 supply) internal view returns (uint256) {
        return (n + 1).mulDiv(_scale * WAD, supply + _scale);
    }

    function _engine() internal view returns (IRiskEngine) {
        return IRiskEngine(ICredenceMarket(market).wiring().engine);
    }

    function _oracle() internal view returns (IOracleAdapter) {
        return IOracleAdapter(ICredenceMarket(market).wiring().oracle);
    }

    function _tip() internal {
        uint256 g = gasleft();
        try tips.pay(msg.sender, KeeperJob.EPOCH) {}
        catch {
            GasGuard.check(g);
        }
    }
}
