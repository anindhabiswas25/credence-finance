// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";

/// @title Share ↔ asset conversion with virtual shares (Build Guide §7.2).
/// @dev Virtual offsets (1e6 shares, 1 asset) make the first depositor / borrower unable to skew the rate
///      (inflation attack). Directions per §7.2:
///        debt from borrow shares ............ Up      (toAssetsUp)
///        borrow shares minted on borrow ..... Up      (toSharesUp)
///        borrow shares burned on repay ...... Down    (toSharesDown)
///        vault / pool shares minted ......... Down    (toSharesDown)
///        assets paid out on redeem .......... Down    (toAssetsDown)
library SharesMath {
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return FPM.fullMulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return FPM.fullMulDivUp(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return FPM.fullMulDiv(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return FPM.fullMulDivUp(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }
}
