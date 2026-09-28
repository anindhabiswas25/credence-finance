// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    MarketParams,
    MarketState,
    Position,
    ClockState,
    ClockData,
    AuctionKind,
    MarketAction,
    KeeperJob
} from "../../libraries/Types.sol";
import {ICredenceErrors} from "../../libraries/Errors.sol";
import {ICredenceMarketEvents} from "../../libraries/Events.sol";
import {WadMath} from "../../libraries/WadMath.sol";
import {SharesMath} from "../../libraries/SharesMath.sol";
import {IUnderwriterPool} from "../../interfaces/IUnderwriterPool.sol";
import {IProtocolReserve} from "../../interfaces/IProtocolReserve.sol";
import {Layout, LotBook, LotEntry, MarketLib} from "./MarketLib.sol";
import {GasGuard} from "../../libraries/GasGuard.sol";

/// @title CredenceMarket liquidation, settlement, waterfall and fee sweep (§8.4.3, F-4.5, Architecture §3.6).
/// @dev External library: runs by DELEGATECALL in the market's storage.
library LiquidationLogic {
    using SafeERC20 for IERC20;
    using WadMath for uint256;
    using MarketLib for Layout;

    function flagForAuction(Layout storage $, bytes32 id, address[] calldata borrowers) external {
        MarketParams memory p = $.market(id);
        ClockState st = $.clock().poke(p.assetId);
        ClockData memory d = $.clock().closureInfo(p.assetId);
        AuctionKind kind;
        uint256 threshold = MarketLib.WAD;
        if (st == ClockState.REGULAR) {
            kind = AuctionKind.INTRADAY;
        } else if (st == ClockState.EXTENDED) {
            kind = AuctionKind.EMERGENCY;
            threshold = MarketLib.EMERGENCY_HF;
        } else if (
            st == ClockState.REOPEN && d.openPrintAt != 0
                && block.timestamp < uint256(d.openPrintAt) + MarketLib.REOPEN_QUEUE + d.phaseExtension
        ) {
            kind = AuctionKind.REOPEN;
        } else {
            revert ICredenceErrors.ActionNotAllowedInState(MarketAction.FLAG_FOR_AUCTION, st);
        }
        $.accrue(id);
        uint256 v = $.oracle().valuationPrice(p.assetId);
        uint64 auctionId;
        for (uint256 i; i < borrowers.length; ++i) {
            address b = borrowers[i];
            Position storage pos = $.pos[id][b];
            if (pos.auctionId != 0 || pos.borrowShares == 0) continue; // already queued: no-op, no tip
            // INV-LIQ-02: a covered position is never sold in EXTENDED
            if (kind == AuctionKind.EMERGENCY && pos.coverClosureId == d.closureId) continue;
            uint256 c = $.value(id, pos.collateral, v);
            if (c.healthFactorDown(p.lt, $.debtOf(id, pos)) >= threshold) continue;
            if (auctionId == 0) auctionId = $.lotFor(id, p.assetId, kind, d.closureId);
            $.join(auctionId, b, pos, 0);
            emit ICredenceMarketEvents.Flagged(id, b, auctionId, kind);
            if ($.lots[auctionId].borrowers.length == MarketLib.MAX_LOT_POSITIONS) auctionId = 0; // next tranche
            $.tip(KeeperJob.FLAG);
        }
    }

    /// @dev Sizes every queued position (F-4.5a / b through the engine), drops the ones that cured, and moves Σx to
    ///      the caller. INV-LIQ-01/02: only in the state its auction kind belongs to.
    function releaseLots(Layout storage $, uint64 auctionId) external returns (uint256 totalQty) {
        LotBook storage lot = $.lots[auctionId];
        if (lot.released) revert ICredenceErrors.LotAlreadyReleased(auctionId);
        lot.released = true;
        if (lot.borrowers.length == 0) {
            emit ICredenceMarketEvents.LotsReleased(auctionId, 0, 0);
            return 0; // everyone cured, or nobody was queued
        }
        bytes32 id = lot.marketId;
        MarketParams memory p = $.params[id];
        ClockState st = $.clock().poke(p.assetId);
        if (!_releaseAllowed(lot.kind, st)) {
            revert ICredenceErrors.ActionNotAllowedInState(MarketAction.FLAG_FOR_AUCTION, st);
        }
        $.accrue(id);
        uint256 v = $.oracle().valuationPrice(p.assetId);
        uint256 kappa = lot.kind == AuctionKind.PRECLOSE ? p.precloseKappa : $.engine().params().kappa;
        uint256 reserve = v.mulWadDown(MarketLib.WAD - kappa);
        for (uint256 i = lot.borrowers.length; i > 0; --i) {
            address b = lot.borrowers[i - 1];
            Position storage pos = $.pos[id][b];
            LotEntry storage e = $.entries[auctionId][b];
            uint256 x = _lotSize($, id, p, pos, lot.kind, v, reserve, e.targetLtv);
            if (x == 0) {
                $.leave(auctionId, id, b, pos); // cured before the lot was fixed
                continue;
            }
            e.qty = uint128(x);
            e.qtyBefore = pos.collateral;
            pos.collateral -= uint128(x);
            $.reduceCovered(id, pos, x);
            totalQty += x;
            ++lot.releasedCount;
            emit ICredenceMarketEvents.LotReleased(auctionId, b, x);
        }
        $.state[id].totalCollateral -= uint128(totalQty);
        lot.totalQty = uint128(totalQty);
        if (totalQty != 0) IERC20(p.collateralToken).safeTransfer(msg.sender, totalQty);
        emit ICredenceMarketEvents.LotsReleased(auctionId, totalQty, lot.releasedCount);
    }

    function onAuctionCleared(Layout storage $, uint64 auctionId, uint256 proceeds, uint256 blendedPrice)
        external
    {
        LotBook storage lot = $.lots[auctionId];
        if (!lot.released) revert ICredenceErrors.NotInLot(auctionId, address(0));
        if (lot.cleared) revert ICredenceErrors.LotAlreadyCleared(auctionId);
        lot.cleared = true;
        lot.proceeds = uint128(proceeds);
        lot.blendedPrice = uint128(blendedPrice);
        if (proceeds != 0) {
            IERC20($.params[lot.marketId].loanToken).safeTransferFrom(msg.sender, address(this), proceeds);
        }
        emit ICredenceMarketEvents.LotCleared(auctionId, proceeds, blendedPrice);
    }

    function settlePositions(Layout storage $, uint64 auctionId, address[] calldata borrowers) external {
        LotBook storage lot = $.lots[auctionId];
        if (!lot.cleared) revert ICredenceErrors.LotNotCleared(auctionId);
        bytes32 id = lot.marketId;
        MarketParams memory p = $.params[id];
        $.accrue(id);
        uint256 processed;
        for (uint256 i; i < borrowers.length; ++i) {
            LotEntry storage e = $.entries[auctionId][borrowers[i]];
            if (e.index == 0 || e.settled || e.qty == 0) continue;
            _settleOne($, auctionId, lot, e, id, p, borrowers[i]);
            ++processed;
        }
        if (processed == 0) return;
        if (lot.settledCount == lot.releasedCount) $.auctionHouse().lotSettled(auctionId);
        $.tip(KeeperJob.SETTLE);
    }

    function claimFees(Layout storage $, bytes32 id) external {
        MarketParams memory p = $.market(id);
        MarketState storage s = $.accrue(id);
        uint256 liq = MarketLib.liquidity(s);
        uint256 toPool = WadMath.min(s.poolFeeAccrued, liq);
        uint256 toTreasury = WadMath.min(s.treasuryFeeAccrued, liq - toPool);
        s.poolFeeAccrued -= uint128(toPool);
        s.treasuryFeeAccrued -= uint128(toTreasury);
        IERC20 token = IERC20(p.loanToken);
        if (toPool != 0) {
            token.safeTransfer($.w.pool, toPool);
            IUnderwriterPool($.w.pool).creditRiskFee(toPool);
        }
        if (toTreasury != 0) {
            uint256 toReserve = toTreasury * $.reserveFeeShareBps / MarketLib.BPS;
            if (toReserve != 0) {
                token.forceApprove($.w.reserve, toReserve);
                IProtocolReserve($.w.reserve).fund(toReserve);
            }
            token.safeTransfer($.w.treasury, toTreasury - toReserve);
        }
        emit ICredenceMarketEvents.FeesClaimed(id, toPool, toTreasury);
    }

    // ───────────── internals ─────────────

    function _releaseAllowed(AuctionKind k, ClockState st) internal pure returns (bool) {
        if (k == AuctionKind.PRECLOSE || k == AuctionKind.INTRADAY) return st == ClockState.REGULAR;
        if (k == AuctionKind.EMERGENCY) return st == ClockState.EXTENDED;
        return st == ClockState.REOPEN;
    }

    /// @dev x_i for one queued position; 0 = it cured and leaves the lot.
    function _lotSize(
        Layout storage $,
        bytes32 id,
        MarketParams memory p,
        Position storage pos,
        AuctionKind kind,
        uint256 v,
        uint256 reserve,
        uint64 targetLtv
    ) internal view returns (uint256 x) {
        uint256 debt = $.debtOf(id, pos);
        if (debt == 0 || pos.collateral == 0) return 0;
        uint256 c = $.value(id, pos.collateral, v);
        uint8 cd = $.dec[id].coll;
        uint8 ld = $.dec[id].loan;
        if (kind == AuctionKind.PRECLOSE) {
            uint256 dProj = $.projected(id, p.assetId, debt);
            if (dProj.ltvUp(c) <= targetLtv) return 0;
            x = $.engine().precloseLot(dProj, pos.collateral, v, reserve, targetLtv, p.precloseLambda, cd, ld);
        } else {
            if (c.healthFactorDown(p.lt, debt) >= MarketLib.WAD) return 0;
            x = $.engine()
                .liquidationLot(debt, pos.collateral, reserve, v, p.lt, MarketLib.H_STAR, p.penalty, cd, ld);
        }
        if (x > pos.collateral) x = pos.collateral;
    }

    struct Settle {
        uint256 proceeds;
        uint256 penalty;
        uint256 repaid;
        uint256 refund;
        uint256 shortfall;
    }

    /// @dev F-4.5d for one position (the same cases as risk-core `settle_position`); the last position of the lot
    ///      receives the rounding dust of the proceeds.
    function _settleOne(
        Layout storage $,
        uint64 auctionId,
        LotBook storage lot,
        LotEntry storage e,
        bytes32 id,
        MarketParams memory p,
        address b
    ) internal {
        Position storage pos = $.pos[id][b];
        Settle memory r;
        r.proceeds = lot.settledCount + 1 == lot.releasedCount
            ? lot.proceeds - lot.proceedsSettled
            : $.value(id, e.qty, lot.blendedPrice);
        uint256 debt = $.debtOf(id, pos);
        uint256 penFull =
            r.proceeds.mulWadDown(lot.kind == AuctionKind.PRECLOSE ? p.precloseLambda : p.penalty);
        if (e.qty < e.qtyBefore) {
            // partial: the position stays open (Architecture §4.5: D − (1 − λ)P)
            r.penalty = penFull;
            uint256 net = r.proceeds - penFull;
            r.repaid = WadMath.min(net, debt);
            r.refund = net - r.repaid;
        } else if (r.proceeds >= debt) {
            r.penalty = WadMath.min(penFull, r.proceeds - debt);
            r.repaid = debt;
            r.refund = r.proceeds - debt - r.penalty;
        } else {
            r.repaid = r.proceeds;
            r.shortfall = debt - r.proceeds;
        }
        e.settled = true;
        ++lot.settledCount;
        lot.proceedsSettled += uint128(r.proceeds);
        pos.auctionId = 0;

        MarketState storage s = $.state[id];
        if (r.repaid + r.shortfall >= debt) {
            // the whole debt is extinguished (repaid, or repaid + waterfall)
            s.totalBorrowShares -= pos.borrowShares;
            s.totalBorrowAssets = uint128(MarketLib.subFloor(s.totalBorrowAssets, debt));
            pos.borrowShares = 0;
        } else {
            uint256 sh = SharesMath.toSharesDown(r.repaid, s.totalBorrowAssets, s.totalBorrowShares);
            pos.borrowShares -= uint128(sh);
            s.totalBorrowShares -= uint128(sh);
            s.totalBorrowAssets = uint128(MarketLib.subFloor(s.totalBorrowAssets, r.repaid));
        }
        IERC20 token = IERC20(p.loanToken);
        if (r.penalty != 0) _splitPenalty($, token, r.penalty);
        if (r.refund != 0) token.safeTransfer(b, r.refund);
        if (r.shortfall != 0) _waterfall($, id, b, token, r.shortfall);
        emit ICredenceMarketEvents.PositionSettled(
            id, b, auctionId, e.qty, r.proceeds, r.penalty, r.shortfall, r.refund, $.debtOf(id, pos)
        );
    }

    /// @dev ⅓ pool, ⅓ reserve, the rest (⅓ + rounding) to the treasury. A failing reserve leaves its part with the
    ///      treasury, so a settlement never blocks.
    function _splitPenalty(Layout storage $, IERC20 token, uint256 pen) internal {
        uint256 third = pen / 3;
        uint256 toTreasury = pen - 2 * third;
        if (third != 0) {
            token.safeTransfer($.w.pool, third);
            uint256 g0 = gasleft();
            try IUnderwriterPool($.w.pool).creditPenalty(third) {}
            catch {
                GasGuard.check(g0);
            }
            token.forceApprove($.w.reserve, third);
            uint256 g1 = gasleft();
            try IProtocolReserve($.w.reserve).fund(third) {}
            catch {
                GasGuard.check(g1);
                toTreasury += third;
            }
            token.forceApprove($.w.reserve, 0);
        }
        token.safeTransfer($.w.treasury, toTreasury);
    }

    /// @dev §8.4.3 `_waterfall`: pool first (min(S, free cash)), then the reserve (min(rest, balance)); only the
    ///      remainder reduces senior supply (INV-WF-01). Amounts are what actually arrived (balance deltas).
    function _waterfall(Layout storage $, bytes32 id, address b, IERC20 token, uint256 s) internal {
        uint256 bal = token.balanceOf(address(this));
        uint256 g2 = gasleft();
        try IUnderwriterPool($.w.pool).payShortfall(s) {}
        catch {
            GasGuard.check(g2);
        }
        uint256 paidPool = WadMath.min(token.balanceOf(address(this)) - bal, s);
        uint256 paidReserve;
        if (paidPool < s) {
            bal = token.balanceOf(address(this));
            uint256 g3 = gasleft();
            try IProtocolReserve($.w.reserve).cover(s - paidPool) {}
            catch {
                GasGuard.check(g3);
            }
            paidReserve = WadMath.min(token.balanceOf(address(this)) - bal, s - paidPool);
        }
        uint256 loss = s - paidPool - paidReserve;
        if (loss != 0) {
            MarketState storage st = $.state[id];
            st.totalSupplyAssets = uint128(MarketLib.subFloor(st.totalSupplyAssets, loss));
        }
        emit ICredenceMarketEvents.Shortfall(id, b, s, paidPool, paidReserve, loss);
    }
}
