// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Inventory, MarketState} from "../libraries/Types.sol";
import {GasGuard} from "../libraries/GasGuard.sol";
import {ICredenceMarket} from "../interfaces/ICredenceMarket.sol";
import {IRiskEngine} from "../interfaces/IRiskEngine.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";

/// @title UnderwriterPool view logic: capacity inputs (§9.5) and NAV marks (R-09, R-12).
/// @dev External library (linked, runs by DELEGATECALL) so the pool fits the 24 KB code-size limit.
library PoolLib {
    using Math for uint256;

    uint256 internal constant WAD = 1e18;

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

    /// @notice Σ over the stack's markets of the pool's fee receivable (R-09).
    function feeReceivable(address market) external view returns (uint256 sum) {
        if (market == address(0)) return 0;
        bytes32[] memory ids = ICredenceMarket(market).marketIds();
        for (uint256 i; i < ids.length; ++i) {
            MarketState memory s = ICredenceMarket(market).marketState(ids[i]);
            sum += s.poolFeeAccrued;
        }
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
