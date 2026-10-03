// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketParams, Position, ClockState, FeedHealth, MarketAction} from "../../libraries/Types.sol";
import {ICredenceErrors} from "../../libraries/Errors.sol";
import {ICredenceMarketEvents} from "../../libraries/Events.sol";
import {WadMath} from "../../libraries/WadMath.sol";
import {IOracleAdapter} from "../../interfaces/IOracleAdapter.sol";
import {Layout, MarketLib} from "./MarketLib.sol";

/// @title CredenceMarket borrow and collateral-withdrawal logic (§8.4.3 `borrow`, `withdrawCollateral`).
/// @dev External library: runs by DELEGATECALL in the market's storage.
library BorrowLogic {
    using SafeERC20 for IERC20;
    using WadMath for uint256;
    using MarketLib for Layout;

    /// @dev `withCover`: the limit is maxLtv (borrowWithCover buys cover in the same transaction).
    function borrow(Layout storage $, bytes32 id, address b, uint256 assets, address to, bool withCover)
        external
    {
        if (assets == 0) revert ICredenceErrors.ZeroAmount();
        if (to == address(0)) revert ICredenceErrors.ZeroAddress();
        MarketParams memory p = $.market(id);
        ClockState st = $.clock().poke(p.assetId);
        if (st == ClockState.REOPEN || st == ClockState.CORP_ACTION) {
            revert ICredenceErrors.ActionNotAllowedInState(MarketAction.BORROW, st);
        }
        if (withCover && st != ClockState.REGULAR) {
            revert ICredenceErrors.ActionNotAllowedInState(MarketAction.BUY_COVER, st);
        }
        if ($.overlay[id].borrowPaused || $.overlay[bytes32(0)].borrowPaused) {
            revert ICredenceErrors.BorrowPaused(id);
        }
        IOracleAdapter orc = $.oracle();
        if (orc.stressFlag(p.assetId)) revert ICredenceErrors.BorrowPaused(id);
        FeedHealth memory h = orc.feedHealth(p.assetId);
        if (h.disagreement) revert ICredenceErrors.BorrowPaused(id);
        Position storage pos = $.pos[id][b];
        if (pos.auctionId != 0) revert ICredenceErrors.PositionInAuction(pos.auctionId);
        $.accrue(id);
        uint256 d = $.debtOf(id, pos) + assets;
        uint256 shares = $.mintDebt(id, p, pos, assets);
        uint256 c = $.value(id, pos.collateral, orc.valuationPrice(p.assetId));
        uint256 lim;
        bool safeRule;
        if (withCover) lim = $.maxLtvEff(id, p.maxLtv);
        else (lim, safeRule) = $.limit(id, p, st, pos);
        if (safeRule) d = $.projected(id, p.assetId, d);
        uint256 ltvAfter = d.ltvUp(c);
        if (ltvAfter > lim) revert ICredenceErrors.LtvAboveLimit(ltvAfter, lim);
        IERC20(p.loanToken).safeTransfer(to, assets);
        emit ICredenceMarketEvents.Borrow(id, b, to, assets, shares);
    }

    /// @notice Library body of `CredenceMarket.withdrawCollateral` (runs by DELEGATECALL in the market's
    ///        storage).
    function withdrawCollateral(Layout storage $, bytes32 id, address b, uint256 amount, address to)
        external
    {
        if (amount == 0) revert ICredenceErrors.ZeroAmount();
        if (to == address(0)) revert ICredenceErrors.ZeroAddress();
        MarketParams memory p = $.market(id);
        Position storage pos = $.pos[id][b];
        if (pos.auctionId != 0) revert ICredenceErrors.PositionInAuction(pos.auctionId);
        if (amount > pos.collateral) revert ICredenceErrors.InvalidParam();
        $.accrue(id);
        uint256 debt = $.debtOf(id, pos);
        if (debt != 0) {
            // With no debt nothing is at risk, so an empty position can always leave (ADR-0107).
            ClockState st = $.clock().poke(p.assetId);
            if (st == ClockState.REOPEN || st == ClockState.CORP_ACTION) {
                revert ICredenceErrors.ActionNotAllowedInState(MarketAction.WITHDRAW_COLLATERAL, st);
            }
            uint256 cAfter = $.valueNow(id, p.assetId, pos.collateral - amount);
            (uint256 lim, bool safeRule) = $.limit(id, p, st, pos);
            uint256 d = safeRule ? $.projected(id, p.assetId, debt) : debt;
            uint256 ltvAfter = d.ltvUp(cAfter);
            if (ltvAfter > lim) revert ICredenceErrors.LtvAboveLimit(ltvAfter, lim);
            if (st == ClockState.REGULAR) {
                uint256 hf = cAfter.healthFactorDown(p.lt, debt);
                if (hf < MarketLib.WITHDRAW_MIN_HF) {
                    revert ICredenceErrors.HealthFactorTooLow(hf, MarketLib.WITHDRAW_MIN_HF);
                }
            }
        }
        pos.collateral -= uint128(amount);
        $.state[id].totalCollateral -= uint128(amount);
        $.reduceCovered(id, pos, amount);
        IERC20(p.collateralToken).safeTransfer(to, amount);
        emit ICredenceMarketEvents.CollateralWithdrawn(id, b, to, amount);
    }
}
