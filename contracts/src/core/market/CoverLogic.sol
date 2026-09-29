// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    MarketParams,
    Position,
    ClockState,
    ClockData,
    ClosureType,
    BellStatus,
    CoverRequest,
    MarketAction,
    BellOutcome,
    KeeperJob,
    AuctionKind
} from "../../libraries/Types.sol";
import {ICredenceErrors} from "../../libraries/Errors.sol";
import {ICredenceMarketEvents} from "../../libraries/Events.sol";
import {WadMath} from "../../libraries/WadMath.sol";
import {IUnderwriterPool} from "../../interfaces/IUnderwriterPool.sol";
import {Layout, MarketLib} from "./MarketLib.sol";
import {GasGuard} from "../../libraries/GasGuard.sol";

/// @dev The market's self-call used by the Bell's auto-cover, so a failed quote falls back to a sale.
interface IAutoCover {
    /// @notice The market's self-call that writes an auto-cover inside `enforceBell` (try/catch boundary);
    ///        only the market itself may call it.
    function autoCover(bytes32 id, address b) external;
}

/// @title CredenceMarket Gap Cover and Bell logic (§8.4.3 `buyCover`, `enforceBell`, R-03, R-08).
/// @dev External library: runs by DELEGATECALL in the market's storage.
library CoverLogic {
    using SafeERC20 for IERC20;
    using WadMath for uint256;
    using MarketLib for Layout;

    /// @dev `auto_` = the Bell's auto-cover: allowed in [bellAt, close), the premium is always added to debt, and
    ///      R-03 lets a position above maxLtv + δ be covered once its pre-close sale is queued.
    function buyCover(Layout storage $, bytes32 id, address b, uint256 maxPremium, bool addToDebt, bool auto_)
        public
        returns (uint256 premium)
    {
        MarketParams memory p = $.market(id);
        ClockState st = $.clock().poke(p.assetId);
        ClockData memory d = $.clock().closureInfo(p.assetId);
        // INV-COV-01: a borrower buys in REGULAR before bellAt; the Bell's auto-cover runs in [bellAt, close)
        if (st != ClockState.REGULAR || d.bellAt == 0 || (block.timestamp >= d.bellAt && !auto_)) {
            revert ICredenceErrors.ActionNotAllowedInState(MarketAction.BUY_COVER, st);
        }
        if (auto_ && block.timestamp >= d.nextCloseAt) revert ICredenceErrors.CoverWindowClosed();
        if ($.coverPaused(id)) revert ICredenceErrors.CoverWindowClosed();
        Position storage pos = $.pos[id][b];
        uint64 upcoming = d.closureId + 1;
        if (pos.coverClosureId == upcoming) revert ICredenceErrors.AlreadyCovered(upcoming);
        if (pos.auctionId != 0 && !auto_) revert ICredenceErrors.PositionInAuction(pos.auctionId);
        $.accrue(id);
        uint256 debt = $.debtOf(id, pos);
        if (debt == 0) revert ICredenceErrors.NoDebt();
        CoverRequest memory req = coverRequest($, id, p, b, pos, d, debt);
        if (!auto_) {
            uint256 cur = debt.ltvUp(req.collateralValue);
            uint256 coverable = $.coverableLtv(id, p);
            if (cur > coverable) revert ICredenceErrors.LtvAboveCoverable(cur, coverable);
        }
        // v2 (ADR-0110): one pool computation; the pool checks `premium ≤ maxPremium` and capacity, then the market
        // pays it in the same transaction.
        address pool = $.w.pool;
        uint64 policyId;
        (policyId, premium) = IUnderwriterPool(pool).writeCover(req, maxPremium);
        if (premium > maxPremium) revert ICredenceErrors.PremiumAboveMax(premium, maxPremium);
        IERC20 token = IERC20(p.loanToken);
        if (addToDebt) {
            $.mintDebt(id, p, pos, premium);
            token.safeTransfer(pool, premium);
        } else {
            token.safeTransferFrom(b, pool, premium);
        }
        pos.coverClosureId = upcoming;
        $.covered[id][upcoming] += pos.collateral;
        emit ICredenceMarketEvents.CoverBought(id, b, upcoming, policyId, premium, addToDebt, auto_);
        if (auto_) emit ICredenceMarketEvents.AutoCoverApplied(id, b, upcoming, premium, $.debtOf(id, pos));
    }

    /// @dev §8.4.3 `enforceBell`: `bellAt ≤ now < closeAt` in REGULAR. SAFE and already-covered borrowers are
    ///      skipped with no event and no tip (ADR-0104); one tip per processed borrower.
    function enforceBell(Layout storage $, bytes32 id, address[] calldata borrowers) external {
        MarketParams memory p = $.market(id);
        ClockState st = $.clock().poke(p.assetId);
        if (st != ClockState.REGULAR || !$.clock().isAfterBellDeadline(p.assetId)) {
            revert ICredenceErrors.ActionNotAllowedInState(MarketAction.ENFORCE_BELL, st);
        }
        $.accrue(id);
        uint64 upcoming = $.upcoming(p.assetId);
        // J3 (ADR-0114): no foreign code runs inside this loop, so the pool may cache the uncovered bound for it
        IUnderwriterPool($.w.pool).beginBellBatch();
        for (uint256 i; i < borrowers.length; ++i) {
            address b = borrowers[i];
            Position storage pos = $.pos[id][b];
            if (pos.borrowShares == 0 || pos.auctionId != 0 || pos.lastBellClosureId >= upcoming) continue;
            if (pos.coverClosureId == upcoming) continue;
            (uint8 status,,) = bellCheck($, id, p, b);
            if (status != uint8(BellStatus.NEEDS_ACTION)) continue;
            uint8 outcome = _cure($, id, p, b, pos, upcoming);
            pos.lastBellClosureId = upcoming;
            emit ICredenceMarketEvents.BellEnforced(id, b, upcoming, outcome);
            $.tip(KeeperJob.ENFORCE_BELL);
        }
        IUnderwriterPool($.w.pool).endBellBatch();
    }

    /// @dev The market's `bellStatus` view.
    function bellStatusView(Layout storage $, bytes32 id, address b)
        external
        view
        returns (BellStatus status, uint256 cureRepay, uint256 cureCollateral, uint256 coverPremium)
    {
        MarketParams memory p = $.market(id);
        Position storage pos = $.pos[id][b];
        ClockData memory d = $.clock().closureInfo(p.assetId);
        if (pos.coverClosureId == d.closureId + 1) return (BellStatus.COVERED, 0, 0, 0);
        uint8 st;
        uint256 cureValue;
        (st, cureRepay, cureValue) = bellCheck($, id, p, b);
        status = BellStatus(st);
        if (status != BellStatus.NEEDS_ACTION) return (status, 0, 0, 0);
        uint256 v = $.oracle().valuationPrice(p.assetId);
        cureCollateral = cureValue == type(uint256).max
            ? cureValue
            : WadMath.mulDivUp(cureValue, 10 ** $.dec[id].coll * WadMath.WAD, v * 10 ** $.dec[id].loan);
        uint256 g0 = gasleft();
        try IUnderwriterPool($.w.pool)
            .previewCover(coverRequest($, id, p, b, pos, d, $.debtView(id, b))) returns (
            uint256 prem, uint256
        ) {
            coverPremium = prem;
        } catch {
            GasGuard.check(g0);
        }
    }

    /// @dev (status, cureRepay, cureCollateralValue) for the upcoming closure: engine.bellStatus at V and D_proj.
    function bellCheck(Layout storage $, bytes32 id, MarketParams memory p, address b)
        internal
        view
        returns (uint8, uint256, uint256)
    {
        uint256 debt = $.debtView(id, b);
        if (debt == 0) return (uint8(BellStatus.SAFE), 0, 0);
        (,, ClosureType t) = $.clock().closureWindow(p.assetId);
        uint256 c = $.valueNow(id, p.assetId, $.pos[id][b].collateral);
        return $.engine()
            .bellStatus(
                p.assetId, uint8(t), c, $.projected(id, p.assetId, debt), $.maxLtvEff(id, p.maxLtv), 0, false
            );
    }

    function coverRequest(
        Layout storage $,
        bytes32 id,
        MarketParams memory p,
        address b,
        Position storage pos,
        ClockData memory d,
        uint256 debt
    ) internal view returns (CoverRequest memory) {
        (,, ClosureType t) = $.clock().closureWindow(p.assetId);
        return CoverRequest({
            marketId: id,
            assetId: p.assetId,
            borrower: b,
            closureType: uint8(t),
            closureDays: uint16($.closureDays(p.assetId)),
            closureId: d.closureId + 1,
            epochId: d.sessionCursor, // venueEpoch of the upcoming closure (R-10)
            collateralValue: $.valueNow(id, p.assetId, pos.collateral),
            debtProjected: $.projected(id, p.assetId, debt)
        });
    }

    /// @dev The Bell's cure for one NEEDS_ACTION borrower: auto-cover, a pre-close sale down to maxLtv then cover
    ///      (R-03), or a pre-close sale down to the safe LTV.
    function _cure(
        Layout storage $,
        bytes32 id,
        MarketParams memory p,
        address b,
        Position storage pos,
        uint64 upcoming
    ) internal returns (uint8) {
        bool coverOn = !pos.autoCoverOptOut && !$.coverPaused(id);
        uint256 cur = $.debtOf(id, pos).ltvUp($.valueNow(id, p.assetId, pos.collateral));
        uint256 maxEff = $.maxLtvEff(id, p.maxLtv);
        if (coverOn && cur <= $.coverableLtv(id, p)) {
            if (_tryAutoCover(id, b)) return BellOutcome.AUTO_COVERED;
        } else if (coverOn) {
            _joinPreclose($, id, p, b, pos, upcoming, maxEff);
            if (_tryAutoCover(id, b)) return BellOutcome.PRECLOSE_THEN_COVER;
        }
        _joinPreclose($, id, p, b, pos, upcoming, $.safeLtv(p.assetId, maxEff));
        return BellOutcome.PRECLOSE_SALE;
    }

    function _tryAutoCover(bytes32 id, address b) internal returns (bool) {
        uint256 g1 = gasleft();
        try IAutoCover(address(this)).autoCover(id, b) {
            return true;
        } catch (bytes memory reason) {
            GasGuard.checkOwn(g1, reason); // a deep out-of-gas must not turn an auto-cover into a sale
            return false;
        }
    }

    function _joinPreclose(
        Layout storage $,
        bytes32 id,
        MarketParams memory p,
        address b,
        Position storage pos,
        uint64 upcoming,
        uint256 target
    ) internal {
        if (pos.auctionId != 0) {
            $.entries[pos.auctionId][b].targetLtv = uint64(target);
            return;
        }
        uint64 auctionId = $.lotFor(id, p.assetId, AuctionKind.PRECLOSE, upcoming);
        $.join(auctionId, b, pos, uint64(target));
    }
}
