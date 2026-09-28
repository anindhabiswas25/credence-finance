// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    MarketParams,
    MarketState,
    Position,
    GuardianOverlay,
    BellStatus,
    MarketWiring,
    LotInfo,
    ClockData,
    AuctionKind,
    ClosureType
} from "../libraries/Types.sol";
import {WadMath} from "../libraries/WadMath.sol";
import {SharesMath} from "../libraries/SharesMath.sol";
import {ICredenceMarket} from "../interfaces/ICredenceMarket.sol";
import {IRiskEngine} from "../interfaces/IRiskEngine.sol";
import {Layout, LotBook, LotEntry, Decimals, MarketLib} from "./market/MarketLib.sol";
import {BorrowLogic} from "./market/BorrowLogic.sol";
import {CoverLogic} from "./market/CoverLogic.sol";
import {LiquidationLogic} from "./market/LiquidationLogic.sol";
import {GasGuard} from "../libraries/GasGuard.sol";

/// @title CredenceMarket: a singleton of isolated lending markets keyed by marketId (Build Guide §8.4, R-21).
/// @notice Only the Senior Vault supplies. Borrowers post collateral, borrow, repay and buy Gap Cover. Every risk
///         check is delegated to the AssetClock, the OracleAdapter and the Risk Engine, except `repay` and
///         `addCollateral`, which call nothing external but the token (P2, INV-REPAY-01/02). Immutable, no proxy.
/// @dev The logic lives in three linked external libraries (BorrowLogic, CoverLogic, LiquidationLogic) that run by
///      DELEGATECALL in this contract's storage (`Layout`), to stay under the 24 KB code-size limit (ADR-0107).
///      Money-flow conventions with the other money contracts (ADR-0107):
///      - premiums, risk fees and penalty shares to the Underwriter Pool are pushed (transfer), then notified
///        (`writeCover` / `creditRiskFee` / `creditPenalty`);
///      - the ProtocolReserve pulls (`fund`, after an exact approval); `cover` and `payShortfall` push to the market,
///        and the market counts what actually arrived (balance delta);
///      - auction proceeds are pulled from the auction house / settlement adapter in `onAuctionCleared`;
///      - a failing pool, reserve or tip call never blocks a settlement.
contract CredenceMarket is ICredenceMarket, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using WadMath for uint256;
    using MarketLib for Layout;

    /// @notice R-03: cover is allowed up to maxLtv + 0.50 pp, never above LT − 2 pp.
    uint256 public constant DELTA_COVER = MarketLib.DELTA_COVER;
    /// @notice Target health factor after a liquidation (§12.2).
    uint256 public constant H_STAR = MarketLib.H_STAR;
    /// @notice EXTENDED-hours emergency line (§12.2).
    uint256 public constant EMERGENCY_HF = MarketLib.EMERGENCY_HF;
    /// @notice Minimum HF after `withdrawCollateral` in REGULAR (§12.2).
    uint256 public constant WITHDRAW_MIN_HF = MarketLib.WITHDRAW_MIN_HF;

    address public immutable timelock;
    address public immutable guardian;
    address internal immutable deployer;

    Layout internal $;

    constructor(address timelock_, address guardian_) {
        if (timelock_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
        guardian = guardian_;
        deployer = msg.sender;
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert Unauthorized();
        _;
    }

    modifier onlyAuction() {
        if (msg.sender == address(0) || (msg.sender != $.w.auctionHouse && msg.sender != $.w.settlement)) {
            revert Unauthorized();
        }
        _;
    }

    // ═════════════════════════════ governance ═════════════════════════════

    /// @inheritdoc ICredenceMarket
    function initializeWiring(MarketWiring calldata w) external {
        if (msg.sender != deployer) revert Unauthorized();
        if ($.w.clock != address(0)) revert AlreadyWired();
        if (
            w.clock == address(0) || w.oracle == address(0) || w.engine == address(0) || w.vault == address(0)
                || w.pool == address(0) || w.reserve == address(0) || w.treasury == address(0)
                || w.tips == address(0) || (w.auctionHouse == address(0) && w.settlement == address(0))
        ) revert ZeroAddress();
        $.w = w;
        emit MarketWired(w);
    }

    /// @inheritdoc ICredenceMarket
    function setEngine(address engine) external onlyTimelock {
        if (engine == address(0)) revert ZeroAddress();
        $.w.engine = engine;
        emit EngineSet(engine);
    }

    /// @inheritdoc ICredenceMarket
    function setOracle(address oracle) external onlyTimelock {
        if (oracle == address(0)) revert ZeroAddress();
        $.w.oracle = oracle;
        emit OracleSet(oracle);
    }

    /// @inheritdoc ICredenceMarket
    function setReserveFeeShare(uint16 bps) external onlyTimelock {
        if (bps > MarketLib.BPS) revert InvalidParam();
        $.reserveFeeShareBps = bps;
        emit ReserveFeeShareSet(bps);
    }

    /// @inheritdoc ICredenceMarket
    /// @dev marketId = keccak256(loanToken, collateralToken, assetId): stable when risk parameters change.
    function createMarket(MarketParams calldata p) external onlyTimelock returns (bytes32 id) {
        if ($.w.clock == address(0)) revert NotWired();
        if (p.loanToken == address(0) || p.collateralToken == address(0)) revert ZeroAddress();
        id = keccak256(abi.encode(p.loanToken, p.collateralToken, p.assetId));
        if ($.params[id].loanToken != address(0)) revert MarketExists(id);
        if ($.ids.length >= MarketLib.MAX_MARKETS) revert InvalidParam();
        if (p.rate.uKink == 0 || p.rate.uKink >= 1e18) revert InvalidParam();
        if (p.precloseKappa >= 1e18 || p.precloseLambda >= 1e18) revert InvalidRiskParams();
        _checkRiskParams(p.maxLtv, p.lt, p.penalty);
        _checkPreclose(p.precloseKappa, p.precloseLambda, p.maxLtv);
        $.params[id] = p;
        $.dec[id] =
            Decimals(IERC20Metadata(p.collateralToken).decimals(), IERC20Metadata(p.loanToken).decimals());
        MarketState storage s = $.state[id];
        s.lastAccrual = uint40(block.timestamp);
        s.feePoolBps = 1000; // ρ_J 10% (§12.2)
        s.feeTreasuryBps = 1000; // ρ_p 10%
        $.ids.push(id);
        emit MarketCreated(id, p);
    }

    /// @inheritdoc ICredenceMarket
    function setCaps(bytes32 id, uint128 supplyCap, uint128 borrowCap) external onlyTimelock {
        MarketParams storage p = $.market(id);
        p.supplyCap = supplyCap;
        p.borrowCap = borrowCap;
        emit CapsSet(id, supplyCap, borrowCap);
    }

    /// @inheritdoc ICredenceMarket
    /// @dev Also confirms (clears) a guardian haircut: the new maxLtv is what the timelock wants (§8.11).
    function setRiskParams(bytes32 id, uint64 maxLtv, uint64 lt, uint64 penalty) external onlyTimelock {
        MarketParams storage p = $.market(id);
        _checkRiskParams(maxLtv, lt, penalty);
        _checkPreclose(p.precloseKappa, p.precloseLambda, maxLtv);
        $.accrue(id);
        p.maxLtv = maxLtv;
        p.lt = lt;
        p.penalty = penalty;
        GuardianOverlay storage o = $.overlay[id];
        o.haircut = 0;
        o.haircutUntil = 0;
        emit RiskParamsSet(id, maxLtv, lt, penalty);
    }

    /// @inheritdoc ICredenceMarket
    function setFeeSplit(bytes32 id, uint16 poolBps, uint16 treasuryBps) external onlyTimelock {
        $.market(id);
        if (uint256(poolBps) + treasuryBps > 3000) revert InvalidParam();
        MarketState storage s = $.accrue(id);
        s.feePoolBps = poolBps;
        s.feeTreasuryBps = treasuryBps;
        emit FeeSplitSet(id, poolBps, treasuryBps);
    }

    /// @inheritdoc ICredenceMarket
    /// @dev The guardian contract enforces its own delays (unpause after 6 h). Here: a live haircut can only rise,
    ///      and it is at most 10 pp for at most 7 days (§8.11). Id 0 is the global overlay (ADR-0104).
    function applyOverlay(bytes32 id, GuardianOverlay calldata o) external {
        if (msg.sender != guardian) revert Unauthorized();
        if (id != bytes32(0)) $.market(id);
        GuardianOverlay storage cur = $.overlay[id];
        if (o.haircut != cur.haircut || o.haircutUntil != cur.haircutUntil) {
            uint64 live = cur.haircutUntil > block.timestamp ? cur.haircut : 0;
            if (o.haircut > 0.1e18 || o.haircutUntil > block.timestamp + 7 days || o.haircut < live) {
                revert OverlayNotRiskReducing();
            }
        }
        $.overlay[id] = o;
        emit OverlayApplied(id, o.haircut, o.haircutUntil, o.borrowPaused, o.coverPaused);
    }

    function _checkRiskParams(uint64 maxLtv, uint64 lt, uint64 penalty) internal view {
        if (maxLtv == 0 || lt >= 1e18 || penalty >= 1e18 || uint256(lt) < uint256(maxLtv) + 0.03e18) {
            revert InvalidRiskParams();
        }
        // listing precondition (§9.6 a): H*(1 − κ)(1 − λ) > LT
        uint256 kappa = IRiskEngine($.w.engine).params().kappa;
        if (MarketLib.H_STAR.mulWadDown(1e18 - kappa).mulWadDown(1e18 - penalty) <= lt) {
            revert IncompatibleRiskParams();
        }
    }

    /// @dev §9.6 b: (1 − λ_pre)(1 − κ_pre) > LTV_safe for any LTV_safe ≤ maxLtv.
    function _checkPreclose(uint64 kappaPre, uint64 lambdaPre, uint64 maxLtv) internal pure {
        if (uint256(1e18 - lambdaPre).mulWadDown(1e18 - kappaPre) <= maxLtv) revert IncompatibleRiskParams();
    }

    // ═════════════════════════════ senior vault ═════════════════════════════

    /// @inheritdoc ICredenceMarket
    function supply(bytes32 id, uint256 assets) external nonReentrant {
        if (msg.sender != $.w.vault) revert Unauthorized();
        if (assets == 0) revert ZeroAmount();
        MarketParams storage p = $.market(id);
        MarketState storage s = $.accrue(id);
        uint256 after_ = s.totalSupplyAssets + assets;
        if (after_ > p.supplyCap) revert CapExceeded(after_, p.supplyCap);
        s.totalSupplyAssets = uint128(after_);
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    /// @inheritdoc ICredenceMarket
    function withdrawSupply(bytes32 id, uint256 assets, address to) external nonReentrant {
        if (msg.sender != $.w.vault) revert Unauthorized();
        MarketParams storage p = $.market(id);
        MarketState storage s = $.accrue(id);
        uint256 liq = MarketLib.liquidity(s);
        if (assets > liq) revert InsufficientLiquidity(assets, liq);
        s.totalSupplyAssets -= uint128(assets);
        IERC20(p.loanToken).safeTransfer(to, assets);
    }

    // ═════════════════════════════ borrower ═════════════════════════════

    /// @inheritdoc ICredenceMarket
    /// @dev Any state. No external call but the token, and a try/catch read of the clock for the dequeue rule (a
    ///      failure leaves the position queued, which is harmless).
    function addCollateral(bytes32 id, address onBehalf, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (onBehalf == address(0)) revert ZeroAddress();
        MarketParams storage p = $.market(id);
        IERC20(p.collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        Position storage pos = $.pos[id][onBehalf];
        pos.collateral += uint128(amount);
        $.state[id].totalCollateral += uint128(amount);
        if (pos.coverClosureId != 0) $.covered[id][pos.coverClosureId] += uint128(amount);
        emit CollateralAdded(id, onBehalf, msg.sender, amount);
        _tryDequeue(id, onBehalf, pos);
    }

    /// @inheritdoc ICredenceMarket
    /// @dev Any state. Accrual is internal math; no oracle or engine call (INV-REPAY-01). Pass `assets` to pay
    ///      exactly that amount (shares burned round down) or `shares` (e.g. all of them) to close the debt.
    function repay(bytes32 id, address onBehalf, uint256 assets, uint256 shares)
        external
        nonReentrant
        returns (uint256 repaid)
    {
        if ((assets == 0) == (shares == 0)) revert InvalidParam();
        MarketParams storage p = $.market(id);
        MarketState storage s = $.accrue(id);
        Position storage pos = $.pos[id][onBehalf];
        if (pos.borrowShares == 0) revert NoDebt();
        if (shares == 0) {
            shares = SharesMath.toSharesDown(assets, s.totalBorrowAssets, s.totalBorrowShares);
            repaid = assets;
        } else {
            repaid = SharesMath.toAssetsUp(shares, s.totalBorrowAssets, s.totalBorrowShares);
        }
        if (shares > pos.borrowShares) revert InvalidParam();
        if (shares == 0 || repaid == 0) revert ZeroAmount();
        pos.borrowShares -= uint128(shares);
        s.totalBorrowShares -= uint128(shares);
        s.totalBorrowAssets = uint128(MarketLib.subFloor(s.totalBorrowAssets, repaid));
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), repaid);
        emit Repay(id, onBehalf, msg.sender, repaid, shares);
        _tryDequeue(id, onBehalf, pos);
    }

    /// @inheritdoc ICredenceMarket
    function borrow(bytes32 id, uint256 assets, address to) external nonReentrant {
        BorrowLogic.borrow($, id, msg.sender, assets, to, false);
    }

    /// @inheritdoc ICredenceMarket
    function borrowWithCover(bytes32 id, uint256 assets, address to, uint256 maxPremium)
        external
        nonReentrant
    {
        BorrowLogic.borrow($, id, msg.sender, assets, to, true);
        CoverLogic.buyCover($, id, msg.sender, maxPremium, true, false);
    }

    /// @inheritdoc ICredenceMarket
    function buyCover(bytes32 id, uint256 maxPremium, bool addToDebt) external nonReentrant {
        CoverLogic.buyCover($, id, msg.sender, maxPremium, addToDebt, false);
    }

    /// @notice The Bell's auto-cover (§8.4.3 `enforceBell`), as a self-call so a failed quote or capacity check
    ///         falls back to a pre-close sale. Callable only by this contract.
    function autoCover(bytes32 id, address b) external {
        if (msg.sender != address(this)) revert Unauthorized();
        CoverLogic.buyCover($, id, b, type(uint256).max, true, true);
    }

    /// @inheritdoc ICredenceMarket
    function withdrawCollateral(bytes32 id, uint256 amount, address to) external nonReentrant {
        BorrowLogic.withdrawCollateral($, id, msg.sender, amount, to);
    }

    /// @inheritdoc ICredenceMarket
    function setAutoCover(bytes32 id, bool enabled) external {
        $.market(id);
        $.pos[id][msg.sender].autoCoverOptOut = !enabled;
        emit AutoCoverSet(id, msg.sender, enabled);
    }

    // ═════════════════════════════ keepers ═════════════════════════════

    /// @inheritdoc ICredenceMarket
    function enforceBell(bytes32 id, address[] calldata borrowers) external nonReentrant {
        CoverLogic.enforceBell($, id, borrowers);
    }

    /// @inheritdoc ICredenceMarket
    function flagForAuction(bytes32 id, address[] calldata borrowers) external nonReentrant {
        LiquidationLogic.flagForAuction($, id, borrowers);
    }

    /// @inheritdoc ICredenceMarket
    function settlePositions(uint64 auctionId, address[] calldata borrowers) external nonReentrant {
        LiquidationLogic.settlePositions($, auctionId, borrowers);
    }

    /// @inheritdoc ICredenceMarket
    function claimFees(bytes32 id) external nonReentrant {
        LiquidationLogic.claimFees($, id);
    }

    // ═════════════════════════════ auction callbacks ═════════════════════════════

    /// @inheritdoc ICredenceMarket
    function releaseLots(uint64 auctionId) external nonReentrant onlyAuction returns (uint256) {
        return LiquidationLogic.releaseLots($, auctionId);
    }

    /// @inheritdoc ICredenceMarket
    function cancelLot(uint64 auctionId) external nonReentrant onlyAuction {
        LiquidationLogic.cancelLot($, auctionId);
    }

    /// @inheritdoc ICredenceMarket
    function onAuctionCleared(uint64 auctionId, uint256 proceeds, uint256 blendedPrice)
        external
        nonReentrant
        onlyAuction
    {
        LiquidationLogic.onAuctionCleared($, auctionId, proceeds, blendedPrice);
    }

    // ═════════════════════════════ views ═════════════════════════════

    /// @inheritdoc ICredenceMarket
    function marketParams(bytes32 id) external view returns (MarketParams memory) {
        return $.market(id);
    }

    /// @inheritdoc ICredenceMarket
    /// @dev Interest is accrued virtually to `block.timestamp`.
    function marketState(bytes32 id) external view returns (MarketState memory) {
        $.market(id);
        return $.accruedView(id);
    }

    /// @inheritdoc ICredenceMarket
    function position(bytes32 id, address b) external view returns (Position memory) {
        return $.pos[id][b];
    }

    /// @inheritdoc ICredenceMarket
    function overlay(bytes32 id) external view returns (GuardianOverlay memory) {
        return $.overlay[id];
    }

    /// @inheritdoc ICredenceMarket
    function coveredCollateral(bytes32 id, uint64 closureId) external view returns (uint128) {
        return $.covered[id][closureId];
    }

    /// @inheritdoc ICredenceMarket
    function debtOf(bytes32 id, address b) external view returns (uint256) {
        return $.debtView(id, b);
    }

    /// @inheritdoc ICredenceMarket
    function healthFactor(bytes32 id, address b) external view returns (uint256) {
        MarketParams storage p = $.market(id);
        return $.valueNow(id, p.assetId, $.pos[id][b].collateral).healthFactorDown(p.lt, $.debtView(id, b));
    }

    /// @inheritdoc ICredenceMarket
    function ltv(bytes32 id, address b) external view returns (uint256) {
        MarketParams storage p = $.market(id);
        return $.debtView(id, b).ltvUp($.valueNow(id, p.assetId, $.pos[id][b].collateral));
    }

    /// @inheritdoc ICredenceMarket
    function borrowLimitLtv(bytes32 id, address b) external view returns (uint256 lim) {
        MarketParams memory p = $.market(id);
        (lim,) = $.limit(id, p, $.clock().previewState(p.assetId), $.pos[id][b]);
    }

    /// @inheritdoc ICredenceMarket
    /// @dev Status and cures for the upcoming closure at V and projected debt (R-08). `cureCollateral` is in
    ///      collateral tokens; `coverPremium` is the pool's quote (0 when not NEEDS_ACTION or unavailable).
    function bellStatus(bytes32 id, address b) external view returns (BellStatus, uint256, uint256, uint256) {
        return CoverLogic.bellStatusView($, id, b);
    }

    /// @inheritdoc ICredenceMarket
    function liquidity(bytes32 id) external view returns (uint256) {
        $.market(id);
        return MarketLib.liquidity($.accruedView(id));
    }

    /// @inheritdoc ICredenceMarket
    function borrowRate(bytes32 id) external view returns (uint256) {
        $.market(id);
        return $.borrowRate(id);
    }

    /// @inheritdoc ICredenceMarket
    function projectedDebt(bytes32 id, address b) external view returns (uint256) {
        return $.projected(id, $.market(id).assetId, $.debtView(id, b));
    }

    /// @inheritdoc ICredenceMarket
    function upcomingClosureId(bytes32 id) external view returns (uint64) {
        return $.upcoming($.market(id).assetId);
    }

    /// @inheritdoc ICredenceMarket
    function totalBorrowsAll() external view returns (uint256 total) {
        for (uint256 i; i < $.ids.length; ++i) {
            total += $.accruedView($.ids[i]).totalBorrowAssets;
        }
    }

    /// @inheritdoc ICredenceMarket
    function uncoveredExposure(bytes32 id)
        external
        view
        returns (bytes32 assetId, uint8 closureType, uint256 uncoveredValue, uint256 safeLtv)
    {
        MarketParams memory p = $.market(id);
        assetId = p.assetId;
        (,, ClosureType t) = $.clock().closureWindow(assetId);
        closureType = uint8(t);
        uint256 total = $.state[id].totalCollateral;
        uint256 cov = $.covered[id][$.upcoming(assetId)];
        if (total > cov) uncoveredValue = $.valueNow(id, assetId, total - cov);
        safeLtv = $.safeLtv(assetId, $.maxLtvEff(id, p.maxLtv));
    }

    /// @inheritdoc ICredenceMarket
    function wiring() external view returns (MarketWiring memory) {
        return $.w;
    }

    /// @inheritdoc ICredenceMarket
    function reserveFeeShareBps() external view returns (uint16) {
        return $.reserveFeeShareBps;
    }

    /// @inheritdoc ICredenceMarket
    function marketIds() external view returns (bytes32[] memory) {
        return $.ids;
    }

    /// @inheritdoc ICredenceMarket
    function lotInfo(uint64 auctionId) external view returns (LotInfo memory) {
        LotBook storage l = $.lots[auctionId];
        return LotInfo({
            marketId: l.marketId,
            kind: l.kind,
            totalQty: l.totalQty,
            proceeds: l.proceeds,
            blendedPrice: l.blendedPrice,
            proceedsSettled: l.proceedsSettled,
            positions: uint32(l.borrowers.length),
            settledCount: l.settledCount,
            released: l.released,
            cleared: l.cleared
        });
    }

    /// @inheritdoc ICredenceMarket
    function lotBorrowers(uint64 auctionId) external view returns (address[] memory) {
        return $.lots[auctionId].borrowers;
    }

    /// @inheritdoc ICredenceMarket
    function lotPosition(uint64 auctionId, address b) external view returns (uint128 qty, bool settled) {
        LotEntry storage e = $.entries[auctionId][b];
        return (e.qty, e.settled);
    }

    // ═════════════════════════════ internals ═════════════════════════════

    /// @dev §8.4.3 dequeue rule for repay / addCollateral: a REOPEN-queued position whose HF at the open print is
    ///      back to ≥ 1 leaves the queue before the lot is fixed. A clock read only, wrapped in try/catch.
    function _tryDequeue(bytes32 id, address b, Position storage pos) internal {
        uint64 auctionId = pos.auctionId;
        if (auctionId == 0) return;
        LotBook storage lot = $.lots[auctionId];
        if (lot.released || lot.kind != AuctionKind.REOPEN) return;
        MarketParams storage p = $.params[id];
        uint256 g0 = gasleft();
        try $.clock().closureInfo(p.assetId) returns (ClockData memory d) {
            if (d.openPrint == 0) return;
            uint256 c = $.value(id, pos.collateral, d.openPrint);
            if (c.healthFactorDown(p.lt, $.debtOf(id, pos)) >= 1e18) $.leave(auctionId, id, b, pos);
        } catch {
            GasGuard.check(g0);
        }
    }
}
