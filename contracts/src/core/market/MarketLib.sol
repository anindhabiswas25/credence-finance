// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {
    MarketParams,
    MarketState,
    Position,
    GuardianOverlay,
    MarketWiring,
    ClockState,
    ClockData,
    ClosureType,
    AuctionKind
} from "../../libraries/Types.sol";
import {ICredenceErrors} from "../../libraries/Errors.sol";
import {ICredenceMarketEvents} from "../../libraries/Events.sol";
import {WadMath} from "../../libraries/WadMath.sol";
import {SharesMath} from "../../libraries/SharesMath.sol";
import {KinkedRateModel} from "../KinkedRateModel.sol";
import {IAssetClock} from "../../interfaces/IAssetClock.sol";
import {IOracleAdapter} from "../../interfaces/IOracleAdapter.sol";
import {IRiskEngine} from "../../interfaces/IRiskEngine.sol";
import {IAuctionHouse} from "../../interfaces/IAuctionHouse.sol";
import {IKeeperTips} from "../../interfaces/IKeeperTips.sol";
import {GasGuard} from "../../libraries/GasGuard.sol";

/// @dev Decimals of a market's tokens, cached at creation.
struct Decimals {
    uint8 coll;
    uint8 loan;
}

/// @dev One borrower's entry in a lot. `index` is 1-based into `LotBook.borrowers` (0 = not a member).
struct LotEntry {
    uint128 qty; // x_i, set by releaseLots
    uint128 qtyBefore; // q_i at release
    uint64 targetLtv; // PRECLOSE: the LTV the lot is sized down to
    uint32 index;
    bool settled;
}

/// @dev §8.4.1 `LotBook`.
struct LotBook {
    bytes32 marketId;
    AuctionKind kind;
    uint128 totalQty;
    uint128 proceeds;
    uint128 blendedPrice;
    uint128 proceedsSettled;
    uint32 releasedCount; // positions with x_i > 0
    uint32 settledCount;
    bool released;
    bool cleared;
    address[] borrowers;
}

/// @dev The whole storage of `CredenceMarket`, shared by reference with its logic libraries (§8.4.1).
struct Layout {
    MarketWiring w;
    uint16 reserveFeeShareBps;
    bytes32[] ids;
    mapping(bytes32 id => MarketParams) params;
    mapping(bytes32 id => MarketState) state;
    mapping(bytes32 id => Decimals) dec;
    mapping(bytes32 id => mapping(address borrower => Position)) pos;
    mapping(bytes32 id => mapping(uint64 closureId => uint128)) covered;
    mapping(bytes32 id => GuardianOverlay) overlay;
    mapping(uint64 auctionId => LotBook) lots;
    mapping(uint64 auctionId => mapping(address borrower => LotEntry)) entries;
}

/// @title Shared internal helpers of CredenceMarket and its logic libraries (accrual, debt, limits, lots).
/// @dev Internal functions only: each consumer inlines what it uses.
library MarketLib {
    using WadMath for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant DELTA_COVER = 0.005e18; // R-03
    uint256 internal constant COVER_LT_GAP = 0.02e18; // R-03: δ never above LT − 2 pp
    uint256 internal constant H_STAR = 1.1e18; // §12.2
    uint256 internal constant EMERGENCY_HF = 0.92e18; // §12.2
    uint256 internal constant WITHDRAW_MIN_HF = 1.05e18; // §12.2
    uint256 internal constant REOPEN_QUEUE = 120; // §8.4.3
    uint256 internal constant FALLBACK_CLOSURE_DAYS = 4; // R-07: a 3-day holiday weekend
    uint256 internal constant MAX_LOT_POSITIONS = 200;
    uint256 internal constant MAX_MARKETS = 64;

    // ───────────── wiring ─────────────

    function clock(Layout storage $) internal view returns (IAssetClock) {
        return IAssetClock($.w.clock);
    }

    function oracle(Layout storage $) internal view returns (IOracleAdapter) {
        return IOracleAdapter($.w.oracle);
    }

    function engine(Layout storage $) internal view returns (IRiskEngine) {
        return IRiskEngine($.w.engine);
    }

    function auctionHouse(Layout storage $) internal view returns (IAuctionHouse) {
        return IAuctionHouse($.w.auctionHouse != address(0) ? $.w.auctionHouse : $.w.settlement);
    }

    function market(Layout storage $, bytes32 id) internal view returns (MarketParams storage p) {
        p = $.params[id];
        if (p.loanToken == address(0)) revert ICredenceErrors.MarketNotFound(id);
    }

    function tip(Layout storage $, uint8 job) internal {
        uint256 g0 = gasleft();
        try IKeeperTips($.w.tips).pay(msg.sender, job) {}
        catch {
            GasGuard.check(g0);
        }
    }

    // ───────────── accrual (R-09) ─────────────

    /// @dev §8.4.3 `_accrue`: internal math only. The senior share of interest goes into supply immediately; the
    ///      pool and treasury shares accrue as fee receivables.
    function accrue(Layout storage $, bytes32 id) internal returns (MarketState storage s) {
        s = $.state[id];
        uint256 dt = block.timestamp - s.lastAccrual;
        if (dt == 0) return s;
        s.lastAccrual = uint40(block.timestamp);
        uint256 b = s.totalBorrowAssets;
        if (b == 0) return s;
        (uint256 i, uint256 fp, uint256 ft) = interest($, id, s, dt);
        if (i == 0) return s;
        s.totalBorrowAssets = uint128(b + i);
        s.poolFeeAccrued += uint128(fp);
        s.treasuryFeeAccrued += uint128(ft);
        s.totalSupplyAssets += uint128(i - fp - ft);
        emit ICredenceMarketEvents.Accrued(id, i, fp, ft);
    }

    function interest(Layout storage $, bytes32 id, MarketState memory s, uint256 dt)
        internal
        view
        returns (uint256 i, uint256 fp, uint256 ft)
    {
        uint256 r = KinkedRateModel.rate(
            KinkedRateModel.utilization(s.totalBorrowAssets, s.totalSupplyAssets), $.params[id].rate
        );
        i = KinkedRateModel.interest(s.totalBorrowAssets, r, dt);
        fp = i * s.feePoolBps / BPS;
        ft = i * s.feeTreasuryBps / BPS;
    }

    function accruedView(Layout storage $, bytes32 id) internal view returns (MarketState memory s) {
        s = $.state[id];
        uint256 dt = block.timestamp - s.lastAccrual;
        if (dt == 0 || s.totalBorrowAssets == 0) return s;
        (uint256 i, uint256 fp, uint256 ft) = interest($, id, s, dt);
        s.totalBorrowAssets += uint128(i);
        s.poolFeeAccrued += uint128(fp);
        s.treasuryFeeAccrued += uint128(ft);
        s.totalSupplyAssets += uint128(i - fp - ft);
        s.lastAccrual = uint40(block.timestamp);
    }

    function borrowRate(Layout storage $, bytes32 id) internal view returns (uint256) {
        MarketState memory s = accruedView($, id);
        return KinkedRateModel.rate(
            KinkedRateModel.utilization(s.totalBorrowAssets, s.totalSupplyAssets), $.params[id].rate
        );
    }

    /// @dev Cash attributable to the market: S + F_pool + F_treasury − B (≥ 0 by INV-MKT-02).
    function liquidity(MarketState memory s) internal pure returns (uint256) {
        uint256 cash = uint256(s.totalSupplyAssets) + s.poolFeeAccrued + s.treasuryFeeAccrued;
        return cash > s.totalBorrowAssets ? cash - s.totalBorrowAssets : 0;
    }

    // ───────────── debt and value ─────────────

    /// @dev Debt from the stored (accrued-in-this-tx) state, rounded up.
    function debtOf(Layout storage $, bytes32 id, Position storage pos) internal view returns (uint256) {
        MarketState storage s = $.state[id];
        return SharesMath.toAssetsUp(pos.borrowShares, s.totalBorrowAssets, s.totalBorrowShares);
    }

    function debtView(Layout storage $, bytes32 id, address b) internal view returns (uint256) {
        MarketState memory s = accruedView($, id);
        return SharesMath.toAssetsUp($.pos[id][b].borrowShares, s.totalBorrowAssets, s.totalBorrowShares);
    }

    function value(Layout storage $, bytes32 id, uint256 q, uint256 v) internal view returns (uint256) {
        Decimals storage d = $.dec[id];
        return WadMath.collateralValue(q, v, d.coll, d.loan);
    }

    function valueNow(Layout storage $, bytes32 id, bytes32 asset, uint256 q)
        internal
        view
        returns (uint256)
    {
        return value($, id, q, oracle($).valuationPrice(asset));
    }

    function subFloor(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    /// @dev Mint borrow shares for `assets` (rounded up) against liquidity and the borrow cap.
    function mintDebt(
        Layout storage $,
        bytes32 id,
        MarketParams memory p,
        Position storage pos,
        uint256 assets
    ) internal returns (uint256 shares) {
        MarketState storage s = $.state[id];
        uint256 liq = liquidity(s);
        if (assets > liq) revert ICredenceErrors.InsufficientLiquidity(assets, liq);
        uint256 after_ = s.totalBorrowAssets + assets;
        if (after_ > p.borrowCap) revert ICredenceErrors.CapExceeded(after_, p.borrowCap);
        shares = SharesMath.toSharesUp(assets, s.totalBorrowAssets, s.totalBorrowShares);
        s.totalBorrowAssets = uint128(after_);
        s.totalBorrowShares += uint128(shares);
        pos.borrowShares += uint128(shares);
    }

    // ───────────── limits (§8.2.2, R-03, R-07, R-08) ─────────────

    function maxLtvEff(Layout storage $, bytes32 id, uint256 maxLtv) internal view returns (uint256) {
        uint256 cut;
        GuardianOverlay storage o = $.overlay[id];
        if (o.haircutUntil > block.timestamp) cut = o.haircut;
        GuardianOverlay storage g = $.overlay[bytes32(0)];
        if (g.haircutUntil > block.timestamp && g.haircut > cut) cut = g.haircut;
        return maxLtv > cut ? maxLtv - cut : 0;
    }

    function coverableLtv(Layout storage $, bytes32 id, MarketParams memory p)
        internal
        view
        returns (uint256)
    {
        return WadMath.min(maxLtvEff($, id, p.maxLtv) + DELTA_COVER, uint256(p.lt) - COVER_LT_GAP);
    }

    function coverPaused(Layout storage $, bytes32 id) internal view returns (bool) {
        return $.overlay[id].coverPaused || $.overlay[bytes32(0)].coverPaused;
    }

    function upcoming(Layout storage $, bytes32 asset) internal view returns (uint64) {
        return clock($).closureInfo(asset).closureId + 1;
    }

    function safeLtv(Layout storage $, bytes32 asset, uint256 maxEff) internal view returns (uint256) {
        (,, ClosureType t) = clock($).closureWindow(asset);
        return WadMath.min(maxEff, engine($).safeLtv(asset, uint8(t), maxEff, 0));
    }

    function closureDays(Layout storage $, bytes32 asset) internal view returns (uint256 days_) {
        days_ = FALLBACK_CLOSURE_DAYS;
        uint256 g1 = gasleft();
        try clock($).closureDays(asset) returns (uint256 n) {
            days_ = n;
        } catch {
            GasGuard.check(g1);
        }
    }

    /// @dev D_proj = D × (1 + r_b × days / 365) over the in-progress or next closure (R-07, R-08).
    function projected(Layout storage $, bytes32 id, bytes32 asset, uint256 debt)
        internal
        view
        returns (uint256)
    {
        return KinkedRateModel.projected(debt, borrowRate($, id), closureDays($, asset));
    }

    /// @dev Borrow limit for the permission matrix (§8.2.2): maxLtv in REGULAR before the Bell window (or when
    ///      covered for the upcoming closure), otherwise the closure's safe LTV. `safeRule` = compare projected debt.
    function limit(Layout storage $, bytes32 id, MarketParams memory p, ClockState st, Position storage pos)
        internal
        view
        returns (uint256 lim, bool safeRule)
    {
        uint256 maxEff = maxLtvEff($, id, p.maxLtv);
        if (st == ClockState.REGULAR) {
            ClockData memory d = clock($).closureInfo(p.assetId);
            if (d.bellWindowAt == 0 || block.timestamp < d.bellWindowAt) return (maxEff, false);
            if (pos.coverClosureId == d.closureId + 1) return (maxEff, false);
        } else if (st == ClockState.REOPEN || st == ClockState.CORP_ACTION) {
            return (0, true);
        }
        return (safeLtv($, p.assetId, maxEff), true);
    }

    // ───────────── lots ─────────────

    function lotFor(Layout storage $, bytes32 id, bytes32 asset, AuctionKind kind, uint64 closureId)
        internal
        returns (uint64 auctionId)
    {
        auctionId = auctionHouse($).getOrCreate(kind, id, asset, closureId);
        LotBook storage lot = $.lots[auctionId];
        if (lot.borrowers.length == 0 && lot.marketId == bytes32(0)) {
            lot.marketId = id;
            lot.kind = kind;
        } else if (lot.marketId != id || lot.kind != kind) {
            revert ICredenceErrors.InvalidParam();
        }
        if (lot.released) revert ICredenceErrors.LotAlreadyReleased(auctionId);
    }

    function join(Layout storage $, uint64 auctionId, address b, Position storage pos, uint64 targetLtv)
        internal
    {
        LotBook storage lot = $.lots[auctionId];
        if (lot.borrowers.length >= MAX_LOT_POSITIONS) {
            revert ICredenceErrors.TooManyPositions(lot.borrowers.length + 1, MAX_LOT_POSITIONS);
        }
        lot.borrowers.push(b);
        $.entries[auctionId][b] = LotEntry({
            qty: 0, qtyBefore: 0, targetLtv: targetLtv, index: uint32(lot.borrowers.length), settled: false
        });
        pos.auctionId = auctionId;
    }

    /// @dev Remove `b` from an unreleased lot (swap and pop).
    function leave(Layout storage $, uint64 auctionId, bytes32 id, address b, Position storage pos) internal {
        LotBook storage lot = $.lots[auctionId];
        uint256 idx = $.entries[auctionId][b].index - 1;
        uint256 last = lot.borrowers.length - 1;
        if (idx != last) {
            address moved = lot.borrowers[last];
            lot.borrowers[idx] = moved;
            $.entries[auctionId][moved].index = uint32(idx + 1);
        }
        lot.borrowers.pop();
        delete $.entries[auctionId][b];
        pos.auctionId = 0;
        emit ICredenceMarketEvents.Dequeued(id, b, auctionId);
    }

    function reduceCovered(Layout storage $, bytes32 id, Position storage pos, uint256 amount) internal {
        uint64 cid = pos.coverClosureId;
        if (cid == 0) return;
        uint128 cov = $.covered[id][cid];
        $.covered[id][cid] = cov > amount ? cov - uint128(amount) : 0;
    }
}
