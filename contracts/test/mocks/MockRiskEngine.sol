// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RiskParams} from "../../src/libraries/Types.sol";
import {PackedInt} from "../../src/libraries/PackedInt.sol";

/// @notice Stand-in for the Stylus Risk Engine in Solidity tests (Foundry cannot run WASM, §14.1).
///         - Writers and hash views behave like the real engine (auth, payload length, keccak256 of the packed words).
///         - `safeLtv` returns a value the test injects per (asset, closure type) (e.g. the doc's 71.26% for NVDA),
///           capped at `maxLtv`; `quoteCover` returns an injected quote.
///         - `bellStatus`, `liquidationLot` and `precloseLot` are line-by-line ports of risk-core (same rounding), so
///           market tests get the engine's numbers for the injected safe LTV; `test/unit/MockRiskEngine.t.sol`
///           checks the ports against `risk-cli` through FFI.
///         - `setReverting(true)` makes every math view revert (INV-REPAY-01/02).
contract MockRiskEngine {
    error Unauthorized();
    error MathError(uint8 code);
    error UnknownSet(bytes32 assetId, uint8 closureType);

    address public timelock;
    address public sigmaOracle;
    RiskParams internal _params;

    mapping(bytes32 => bytes32) internal _setHash; // key = keccak256(abi.encodePacked(assetId, closureType))
    mapping(bytes32 => uint32) public setLength;
    mapping(bytes32 => bytes32) public jointHash;
    mapping(bytes32 => uint256[]) internal _joint; // packed int16 joint column per asset (capacity ports, S3)
    mapping(bytes32 => uint256) internal _sigma;
    mapping(bytes32 => uint64) internal _sigmaAt;
    mapping(bytes32 => uint256) internal _floor;
    mapping(bytes32 => uint256) internal _safe; // injected safe LTV per key (0 = maxLtv)
    uint256[3] internal _quote;
    bool public reverting;
    uint256 public safeLtvCalls;

    constructor(address timelock_, address sigmaOracle_) {
        timelock = timelock_;
        sigmaOracle = sigmaOracle_;
    }

    function _key(bytes32 assetId, uint8 closureType) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(assetId, closureType));
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert Unauthorized();
        _;
    }

    function setScenarioSet(bytes32 assetId, uint8 closureType, uint256[] calldata packedSortedZ, uint32 n)
        external
        onlyTimelock
    {
        if (n == 0 || packedSortedZ.length != (uint256(n) + 15) / 16) revert MathError(1);
        bytes32 k = _key(assetId, closureType);
        _setHash[k] = keccak256(abi.encodePacked(packedSortedZ));
        setLength[k] = n;
    }

    function setJointColumn(bytes32 assetId, uint256[] calldata packedZ) external onlyTimelock {
        if (packedZ.length != (uint256(_params.kStress) + 15) / 16) revert MathError(1);
        jointHash[assetId] = keccak256(abi.encodePacked(packedZ));
        _joint[assetId] = packedZ;
    }

    function setParams(RiskParams calldata p) external onlyTimelock {
        _params = p;
    }

    function setSigmaFloor(bytes32 assetId, uint8 closureType, uint256 floor) external onlyTimelock {
        _floor[_key(assetId, closureType)] = floor;
    }

    function updateSigma(bytes32 assetId, uint8 closureType, uint256 s) external {
        if (msg.sender != sigmaOracle) revert Unauthorized();
        _sigma[_key(assetId, closureType)] = s;
        _sigmaAt[_key(assetId, closureType)] = uint64(block.timestamp);
    }

    function sigmaAt(bytes32 assetId, uint8 closureType) external view returns (uint64) {
        return _sigmaAt[_key(assetId, closureType)];
    }

    function sigma(bytes32 assetId, uint8 closureType) external view returns (uint256) {
        return _sigma[_key(assetId, closureType)];
    }

    function sigmaFloor(bytes32 assetId, uint8 closureType) external view returns (uint256) {
        return _floor[_key(assetId, closureType)];
    }

    function params() external view returns (RiskParams memory) {
        return _params;
    }

    function scenarioHash(bytes32 assetId, uint8 closureType) external view returns (bytes32) {
        return _setHash[_key(assetId, closureType)];
    }

    // ───────────── injected math ─────────────

    function setSafeLtv(bytes32 assetId, uint8 closureType, uint256 v) external {
        _safe[_key(assetId, closureType)] = v;
    }

    function setQuote(uint256 premium, uint256 el, uint256 es) external {
        _quote = [premium, el, es];
    }

    function setReverting(bool r) external {
        reverting = r;
    }

    function _live() internal view {
        if (reverting) revert MathError(99);
    }

    function safeLtv(bytes32 assetId, uint8 closureType, uint256 maxLtv, uint256)
        public
        view
        returns (uint256)
    {
        _live();
        uint256 v = _safe[_key(assetId, closureType)];
        return v == 0 || v > maxLtv ? maxLtv : v;
    }

    function quoteCover(bytes32, uint8, uint16, uint256, uint256, uint256)
        external
        view
        returns (uint256, uint256, uint256)
    {
        _live();
        return (_quote[0], _quote[1], _quote[2]);
    }

    /// @dev risk-core `bell_status` at the injected safe LTV.
    function bellStatus(
        bytes32 assetId,
        uint8 closureType,
        uint256 collateralValue,
        uint256 debtProjected,
        uint256 maxLtv,
        uint256 dividend,
        bool covered
    ) external view returns (uint8, uint256, uint256) {
        uint256 s = safeLtv(assetId, closureType, maxLtv, dividend);
        if (covered) return (2, 0, 0);
        uint256 ltv = debtProjected == 0
            ? 0
            : (collateralValue == 0 ? type(uint256).max : _divUp(debtProjected * 1e18, collateralValue));
        if (ltv <= s) return (0, 0, 0);
        uint256 allowed = s * collateralValue / 1e18;
        uint256 repay = debtProjected > allowed ? debtProjected - allowed : 0;
        if (s == 0) return (1, repay, type(uint256).max);
        uint256 need = _divUp(debtProjected * 1e18, s);
        return (1, repay, need > collateralValue ? need - collateralValue : 0);
    }

    /// @dev risk-core `liquidation_lot` (F-4.5a).
    function liquidationLot(
        uint256 debt,
        uint256 qty,
        uint256 sizingPrice,
        uint256 hfPrice,
        uint256 lt,
        uint256 hStar,
        uint256 lambda,
        uint8 collDec,
        uint8 loanDec
    ) external view returns (uint256) {
        _live();
        if (lambda > 1e18 || lt > 10e18) revert MathError(3);
        if (qty == 0) return 0;
        uint256 scale = 10 ** collDec;
        uint256 lhs = hStar * (debt * 10 ** (18 - loanDec));
        uint256 rhs = qty * (hfPrice * lt) / scale;
        if (lhs <= rhs) return 0;
        uint256 hr = hStar * sizingPrice * (1e18 - lambda) / 1e18;
        uint256 pl = hfPrice * lt;
        if (hr <= pl) return qty;
        uint256 x = _divUp((lhs - rhs) * scale, hr - pl);
        return x >= qty ? qty : x;
    }

    /// @dev risk-core `preclose_lot` (F-4.5b).
    function precloseLot(
        uint256 debt,
        uint256 qty,
        uint256 valuation,
        uint256 reserve,
        uint256 targetLtv,
        uint256 lambdaPre,
        uint8 collDec,
        uint8 loanDec
    ) external view returns (uint256) {
        _live();
        if (lambdaPre > 1e18 || targetLtv > 1e18) revert MathError(3);
        if (qty == 0) return 0;
        uint256 scale = 10 ** collDec;
        uint256 lhs = debt * 10 ** (18 - loanDec) * 1e18;
        uint256 rhs = qty * (targetLtv * valuation) / scale;
        if (lhs <= rhs) return 0;
        uint256 sell = (1e18 - lambdaPre) * reserve;
        uint256 keep = targetLtv * valuation;
        if (sell <= keep) return qty;
        uint256 x = _divUp((lhs - rhs) * scale, sell - keep);
        return x >= qty ? qty : x;
    }

    // ───────────── S3 ports: capacity (F-4.4) and clearing (F-4.5c) ─────────────

    /// @dev risk-core `gap_factor`: g = max(0, 1 ± σ|z|/1000 − d) × (1 − κ), rounded down (σ|z| against the user).
    function _gap(int16 z, uint256 sig, uint256 kappa) internal pure returns (uint256) {
        uint256 az = uint256(uint16(z < 0 ? -z : z));
        uint256 base;
        if (z >= 0) {
            base = 1e18 + sig * az / 1000;
        } else {
            uint256 mv = Math.mulDiv(sig, az, 1000, Math.Rounding.Ceil);
            base = mv >= 1e18 ? 0 : 1e18 - mv;
        }
        return Math.mulDiv(base, 1e18 - kappa, 1e18);
    }

    function _z(bytes32 assetId, uint256 j) internal view returns (int16) {
        uint256[] storage col = _joint[assetId];
        return PackedInt.getI16(col[j / 16], j % 16);
    }

    /// @dev risk-core `loss_vector`: L_j = max(0, D − C × g_j) (C × g rounded down), packed 4 × uint64.
    function coverLossVector(
        bytes32 assetId,
        uint8 closureType,
        uint256 collateralValue,
        uint256 debtProjected
    ) external view returns (uint256[] memory packed) {
        _live();
        uint256 k = _params.kStress;
        if (_joint[assetId].length == 0) revert UnknownSet(assetId, closureType);
        uint256 sig = _sigma[_key(assetId, closureType)];
        packed = new uint256[]((k + 3) / 4);
        for (uint256 j; j < k; ++j) {
            uint256 cv = Math.mulDiv(collateralValue, _gap(_z(assetId, j), sig, _params.kappa), 1e18);
            uint256 l = debtProjected > cv ? debtProjected - cv : 0;
            if (l > type(uint64).max) revert MathError(2);
            packed[j / 4] |= l << (64 * (j % 4));
        }
    }

    /// @dev risk-core `pool_capacity`: Λ_j = current_j + add_j + Σ B_{m,j}; u = max_j Λ_j / J (up); ok iff u ≤ u_max.
    function poolCapacity(
        uint256[] calldata packedCurrent,
        uint256[] calldata packedAdd,
        bytes32[] calldata uncAssets,
        uint8[] calldata uncClosureTypes,
        uint256[] calldata uncCollateralValue,
        uint256[] calldata uncSafeLtv,
        uint256 equity
    ) external view returns (bool ok, uint256 utilAfter, uint256 worstLoss) {
        _live();
        uint256 k = _params.kStress;
        uint256 words = (k + 3) / 4;
        if (packedCurrent.length < words || packedAdd.length < words) revert MathError(1);
        uint256[] memory sig = new uint256[](uncAssets.length);
        for (uint256 m; m < uncAssets.length; ++m) {
            if (_joint[uncAssets[m]].length == 0) revert MathError(1);
            sig[m] = _sigma[_key(uncAssets[m], uncClosureTypes[m])];
        }
        for (uint256 j; j < k; ++j) {
            uint256 lambda = ((packedCurrent[j / 4] >> (64 * (j % 4))) & type(uint64).max)
                + ((packedAdd[j / 4] >> (64 * (j % 4))) & type(uint64).max);
            for (uint256 m; m < uncAssets.length; ++m) {
                uint256 g = _gap(_z(uncAssets[m], j), sig[m], _params.kappa);
                if (g < uncSafeLtv[m]) {
                    lambda += Math.mulDiv(uncCollateralValue[m], uncSafeLtv[m] - g, 1e18, Math.Rounding.Ceil);
                }
            }
            if (lambda > worstLoss) worstLoss = lambda;
        }
        if (worstLoss != 0) {
            utilAfter =
                equity == 0 ? type(uint256).max : Math.mulDiv(worstLoss, 1e18, equity, Math.Rounding.Ceil);
        }
        ok = utilAfter <= _params.uMax;
    }

    /// @dev risk-core `clear` (F-4.5c): price desc (tie key asc), fill to Q, pro rata at p*, remainders by tie key.
    function clear(
        uint256[] calldata qtys,
        uint256[] calldata prices,
        bytes32[] calldata tieKeys,
        uint256 lot,
        uint256 reserve
    ) external view returns (uint256 pStar, uint256[] memory fills, uint256 qPool) {
        _live();
        uint256 n = qtys.length;
        if (prices.length != n || tieKeys.length != n) revert MathError(1);
        fills = new uint256[](n);
        uint256[] memory idx = new uint256[](n);
        uint256 m;
        for (uint256 i; i < n; ++i) {
            if (prices[i] >= reserve && qtys[i] != 0) idx[m++] = i;
        }
        for (uint256 a = 1; a < m; ++a) {
            uint256 x = idx[a];
            uint256 b = a;
            while (b > 0 && _before(prices, tieKeys, x, idx[b - 1])) {
                idx[b] = idx[b - 1];
                --b;
            }
            idx[b] = x;
        }
        uint256 remaining = lot;
        uint256 g;
        while (g < m && remaining != 0) {
            uint256 price = prices[idx[g]];
            uint256 end = g;
            uint256 total;
            while (end < m && prices[idx[end]] == price) {
                total += qtys[idx[end]];
                ++end;
            }
            pStar = price;
            if (total <= remaining) {
                for (uint256 t = g; t < end; ++t) {
                    fills[idx[t]] = qtys[idx[t]];
                }
                remaining -= total;
            } else {
                uint256 assigned;
                for (uint256 t = g; t < end; ++t) {
                    uint256 f = Math.mulDiv(qtys[idx[t]], remaining, total);
                    fills[idx[t]] = f;
                    assigned += f;
                }
                uint256 left = remaining - assigned;
                for (uint256 t = g; t < end && left != 0; ++t) {
                    if (fills[idx[t]] < qtys[idx[t]]) {
                        ++fills[idx[t]];
                        --left;
                    }
                }
                remaining = 0;
            }
            g = end;
        }
        qPool = remaining;
    }

    function _before(uint256[] calldata prices, bytes32[] calldata keys, uint256 a, uint256 b)
        internal
        pure
        returns (bool)
    {
        return prices[a] > prices[b] || (prices[a] == prices[b] && keys[a] < keys[b]);
    }

    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
