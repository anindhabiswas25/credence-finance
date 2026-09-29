// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Inventory, Session, MarketKind, MarketParams, RedemptionClaim} from "../libraries/Types.sol";
import {IUnderwriterPoolEvents} from "../libraries/Events.sol";
import {INavFund} from "../interfaces/INavFund.sol";
import {IAuctionHouse} from "../interfaces/IAuctionHouse.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {ICalendarStore} from "../interfaces/ICalendarStore.sol";
import {GasGuard} from "../libraries/GasGuard.sol";
import {ICredenceMarket} from "../interfaces/ICredenceMarket.sol";
import {IRiskEngine} from "../interfaces/IRiskEngine.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";

/// @title UnderwriterPool logic: capacity inputs (§9.5), NAV marks (R-09, R-12), GDA listing (F-4.5e) and the NAV
///        stack's redemption claims (§8.6.1, §8.8).
/// @dev External library (linked, runs by DELEGATECALL in the pool's context, so `msg.sender` of its calls is the pool)
///      to keep the pool under the 24 KB code-size limit.
library PoolLib {
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant GDA_START_MARKUP = 1.02e18; // F-4.5e: k = 1.02 × V
    uint256 internal constant GDA_DECAY = 8_022_536_812_036; // ln 2 / 86,400 s (WAD per second): half-life 24 h
    uint256 internal constant GDA_EMISSION_PERIOD = 3 days; // r_e = inventory / 3 days

    uint256 internal constant WAD = 1e18;
    uint40 internal constant BELL_WINDOW = 2 hours; // §8.2.2
    uint40 internal constant BELL_DEADLINE = 15 minutes;

    // ───────────── calendar (epochs = venue sessions, R-10) ─────────────

    /// @notice Epoch `e`'s times: Bell window, Bell deadline, close, and the next session's open (0 if unknown).
    function epochTimes(ICalendarStore cal, bytes32 venue, uint64 e)
        external
        view
        returns (uint40 bellWindowAt, uint40 bellAt, uint40 closeAt, uint40 reopenAt)
    {
        uint256 n = cal.sessionCount(venue);
        if (e >= n) revert ICredenceErrors.NoCalendarCoverage(venue);
        closeAt = cal.session(venue, e).close;
        (bellWindowAt, bellAt) = (closeAt - BELL_WINDOW, closeAt - BELL_DEADLINE);
        reopenAt = e + 1 < n ? cal.session(venue, e + 1).open : 0;
    }

    /// @notice The epoch whose Bell window [close − 2 h, close) contains `t`.
    function bellWindowEpoch(ICalendarStore cal, bytes32 venue, uint40 t)
        external
        view
        returns (uint64, bool)
    {
        (uint256 i, bool found) = cal.findSession(venue, t);
        if (!found) return (0, false);
        Session memory s = cal.session(venue, i);
        return (uint64(i), t >= s.close - BELL_WINDOW && t < s.close);
    }

    /// @notice The first epoch whose Bell window has not opened at `t`.
    function nextUnopened(ICalendarStore cal, bytes32 venue, uint40 t) external view returns (uint64) {
        (uint256 i, bool found) = cal.findSession(venue, t);
        if (!found) revert ICredenceErrors.NoCalendarCoverage(venue);
        return t >= cal.session(venue, i).close - BELL_WINDOW ? uint64(i + 1) : uint64(i);
    }

    /// @notice The latest session whose close is ≤ t (type(uint64).max if none) and the open that follows it
    ///         (type(uint40).max if beyond the calendar).
    function lastClosed(ICalendarStore cal, bytes32 venue, uint40 t)
        external
        view
        returns (uint64 c, uint40 reopen)
    {
        (uint256 i, bool found) = cal.findSession(venue, t);
        uint256 n = cal.sessionCount(venue);
        if (!found) c = n == 0 ? type(uint64).max : uint64(n - 1);
        else if (t >= cal.session(venue, i).close) c = uint64(i);
        else c = i == 0 ? type(uint64).max : uint64(i - 1);
        reopen = c != type(uint64).max && c + 1 < n ? cal.session(venue, c + 1).open : type(uint40).max;
    }

    /// @notice engine.poolCapacity over every market of the stack. The market of the policy being written counts
    ///         without the policy's own collateral (it moves from uncovered to covered with this write).
    function capacity(
        address market,
        IRiskEngine eng,
        uint256[] memory current,
        uint256[] memory add,
        uint256 j,
        bytes32 skipId,
        uint256 skipValue
    ) external view returns (bool, uint256, uint256) {
        if (add.length == 0) add = new uint256[]((uint256(eng.params().kStress) + 3) / 4);
        if (current.length == 0) current = new uint256[](add.length);
        bytes32[] memory ids = ICredenceMarket(market).marketIds();
        uint256 n = ids.length;
        bytes32[] memory assets = new bytes32[](n);
        uint8[] memory types = new uint8[](n);
        uint256[] memory values = new uint256[](n);
        uint256[] memory safes = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (assets[i], types[i], values[i], safes[i]) = ICredenceMarket(market).uncoveredExposure(ids[i]);
            if (ids[i] == skipId) values[i] = values[i] > skipValue ? values[i] - skipValue : 0;
        }
        return eng.poolCapacity(current, add, assets, types, values, safes, j);
    }

    /// @notice Σ over the stack's markets of the pool's fee receivable, accrued to now (R-09).
    function feeReceivable(address market) external view returns (uint256) {
        return market == address(0) ? 0 : ICredenceMarket(market).poolFeeReceivable();
    }

    /// @notice R-12: Σ min(cost, V × (1 − κ) × qty). A price that cannot be read values the inventory at 0.
    function inventoryValue(
        mapping(bytes32 => Inventory) storage inventory,
        bytes32[] storage assets,
        address market,
        uint256 scale
    ) external view returns (uint256 sum) {
        uint256 n = assets.length;
        if (n == 0) return 0;
        ICredenceMarket m = ICredenceMarket(market);
        uint256 kappa = IRiskEngine(m.wiring().engine).params().kappa;
        IOracleAdapter orc = IOracleAdapter(m.wiring().oracle);
        for (uint256 i; i < n; ++i) {
            Inventory storage inv = inventory[assets[i]];
            if (inv.qty == 0) continue;
            uint256 v;
            uint256 g = gasleft();
            try orc.valuationPrice(assets[i]) returns (uint256 p) {
                v = p;
            } catch {
                GasGuard.check(g);
            }
            uint256 mark = uint256(inv.qty)
                .mulDiv(v.mulDiv(WAD - kappa, WAD), 10 ** IERC20Metadata(inv.token).decimals() * scale);
            sum += Math.min(mark, inv.cost);
        }
    }

    // ───────────── GDA resale (F-4.5e) ─────────────

    /// @notice Hands the inventory of `assetId` not yet in a GDA to the auction house and starts a GDA over it.
    function listInventory(Inventory storage inv, bytes32 assetId, address market, address auctionHouse)
        external
        returns (uint64 gdaId)
    {
        if (inv.gdaId != 0) revert ICredenceErrors.GdaRunning(inv.gdaId);
        uint256 free = inv.qty - inv.inGda;
        if (free == 0) revert ICredenceErrors.NoInventory(assetId);
        uint256 v = IOracleAdapter(ICredenceMarket(market).wiring().oracle).valuationPrice(assetId);
        uint256 emission = free / GDA_EMISSION_PERIOD;
        if (emission == 0) emission = 1;
        inv.inGda = inv.qty;
        IERC20(inv.token).safeTransfer(auctionHouse, free);
        gdaId = IAuctionHouse(auctionHouse)
            .startGda(assetId, inv.token, free, v.mulDiv(GDA_START_MARKUP, WAD), GDA_DECAY, emission);
        inv.gdaId = gdaId;
        emit IUnderwriterPoolEvents.InventoryListed(assetId, gdaId, free);
    }

    // ───────────── NAV stack: pool advance and redemption claims (§8.6.1, §8.8) ─────────────

    /// @notice fallbackAdvance body: the `qty` fund tokens are already here. Requests their redemption and records the
    ///         claim at `cost` = min(qty × price, freeCash). Returns the request id and the cost to pay the adapter.
    function advance(
        mapping(uint256 => RedemptionClaim) storage claims,
        address market,
        bytes32 marketId,
        uint256 qty,
        uint256 price,
        uint256 scale,
        uint256 freeCash,
        uint64 epochId
    ) external returns (uint256 requestId, uint256 cost) {
        MarketParams memory p = ICredenceMarket(market).marketParams(marketId);
        if (p.kind != MarketKind.NAV) revert ICredenceErrors.WrongKind(uint8(p.kind));
        if (qty == 0) revert ICredenceErrors.ZeroAmount();
        INavFund fund = INavFund(p.collateralToken);
        cost = Math.min(qty.mulDiv(price, 10 ** fund.decimals() * scale), freeCash);
        requestId = fund.requestRedeem(qty, address(this), address(this));
        if (claims[requestId].fund != address(0)) revert ICredenceErrors.InvalidParam();
        claims[requestId] = RedemptionClaim({
            marketId: marketId,
            fund: address(fund),
            epochId: epochId,
            claimed: false,
            qty: uint128(qty),
            cost: uint128(cost),
            assets: 0
        });
        emit IUnderwriterPoolEvents.RedemptionRequested(epochId, requestId, marketId, address(fund), qty, cost);
    }

    /// @notice claimRedemption body: redeems a fulfilled request into the pool. Returns what arrived and the claim's
    ///         cost (realised P&L = assets − cost).
    function claim(mapping(uint256 => RedemptionClaim) storage claims, uint256 requestId, IERC20 asset)
        external
        returns (uint256 assets, uint256 cost)
    {
        RedemptionClaim storage c = claims[requestId];
        if (c.fund == address(0)) revert ICredenceErrors.UnknownRedemption(requestId);
        if (c.claimed) revert ICredenceErrors.RequestAlreadyClaimed(requestId);
        c.claimed = true;
        uint256 bal = asset.balanceOf(address(this));
        INavFund(c.fund).redeem(requestId, address(this), address(this));
        assets = asset.balanceOf(address(this)) - bal;
        c.assets = uint128(assets);
        cost = c.cost;
    }
}
