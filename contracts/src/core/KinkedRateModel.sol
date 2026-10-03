// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {RateParams} from "../libraries/Types.sol";

/// @title Kinked interest-rate model, as an internal library (Build Guide §8.4.3, F-4.6, P2: no external call).
/// @dev A line-by-line port of risk-core `rates.rs`, with the same rounding, so `risk-cli kinked-rate` /
///      `accrue-interest` / `projected-debt` reproduce every number (tested through FFI).
library KinkedRateModel {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    /// @notice U = borrowed / supplied, WAD, rounded DOWN (0 when nothing is supplied).
    function utilization(uint256 borrowed, uint256 supplied) internal pure returns (uint256) {
        if (supplied == 0) return 0;
        return FPM.fullMulDiv(borrowed, WAD, supplied);
    }

    /// @notice r_b(U) = r0 + s1·U/U* (U ≤ U*), r0 + s1 + s2·(U − U*)/(1 − U*) above. WAD per year, rounded DOWN.
    /// @dev `uKink` ∈ (0, 1e18) is checked when the market is created.
    function rate(uint256 u, RateParams memory p) internal pure returns (uint256) {
        if (u <= p.uKink) return p.r0 + FPM.fullMulDiv(p.s1, u, p.uKink);
        return p.r0 + p.s1 + FPM.fullMulDiv(p.s2, u - p.uKink, WAD - p.uKink);
    }

    /// @notice I = B × r × dt / 31,536,000, rounded UP.
    function interest(uint256 borrowed, uint256 r, uint256 dt) internal pure returns (uint256) {
        return FPM.fullMulDivUp(FPM.fullMulDivUp(borrowed, r, WAD), dt, YEAR);
    }

    /// @notice D_proj = D × (1 + r × days / 365), rounded UP (R-08).
    function projected(uint256 debt, uint256 r, uint256 days_) internal pure returns (uint256) {
        return FPM.fullMulDivUp(debt, WAD + FPM.fullMulDivUp(r, days_, 365), WAD);
    }
}
