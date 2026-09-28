// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Inventory, Session} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {ICalendarStore} from "../interfaces/ICalendarStore.sol";
import {GasGuard} from "../libraries/GasGuard.sol";
import {ICredenceMarket} from "../interfaces/ICredenceMarket.sol";
import {IRiskEngine} from "../interfaces/IRiskEngine.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";

/// @title UnderwriterPool view logic: capacity inputs (§9.5) and NAV marks (R-09, R-12).
/// @dev External library (linked, runs by DELEGATECALL) so the pool fits the 24 KB code-size limit.
library PoolLib {
    using Math for uint256;

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
}
