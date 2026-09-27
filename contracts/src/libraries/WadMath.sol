// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";

/// @title WAD fixed-point helpers with explicit rounding (Build Guide §7.1, §7.2, F-4.1).
/// @dev Rounding rule: always against the acting user, never against solvency.
///      Every function names its direction. Intermediate products use 512-bit mulDiv (no silent overflow).
library WadMath {
    uint256 internal constant WAD = 1e18;

    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return FPM.fullMulDiv(x, y, WAD);
    }

    function mulWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return FPM.fullMulDivUp(x, y, WAD);
    }

    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return FPM.fullMulDiv(x, WAD, y);
    }

    function divWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return FPM.fullMulDivUp(x, WAD, y);
    }

    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return FPM.fullMulDiv(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return FPM.fullMulDivUp(x, y, d);
    }

    /// @notice value(q, V) = q × V × 10^loanDec / (10^collDec × 1e18), rounded DOWN (§7.1).
    /// @param q Collateral in token base units.
    /// @param v Price, WAD USD per whole token.
    function collateralValue(uint256 q, uint256 v, uint8 collDec, uint8 loanDec) internal pure returns (uint256) {
        return FPM.fullMulDiv(q, v * 10 ** loanDec, 10 ** collDec * WAD);
    }

    /// @notice LTV = D × 1e18 / C, rounded UP (limit checks). C = 0 with D > 0 → type(uint256).max.
    function ltvUp(uint256 debt, uint256 collValue) internal pure returns (uint256) {
        if (debt == 0) return 0;
        if (collValue == 0) return type(uint256).max;
        return FPM.fullMulDivUp(debt, WAD, collValue);
    }

    /// @notice HF = C × LT / D, rounded DOWN. D = 0 → type(uint256).max.
    function healthFactorDown(uint256 collValue, uint256 lt, uint256 debt) internal pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        return FPM.fullMulDiv(collValue, lt, debt);
    }

    /// @notice |a − b| / min(a, b) in WAD, rounded UP (a disagreement test must not under-report).
    ///         type(uint256).max if either is 0 (a missing price always counts as disagreeing).
    function relDiffUp(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return type(uint256).max;
        (uint256 hi, uint256 lo) = a > b ? (a, b) : (b, a);
        return FPM.fullMulDivUp(hi - lo, WAD, lo);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
