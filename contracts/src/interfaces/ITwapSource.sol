// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title A DEX TWAP source for one collateral token (Build Guide §8.3.2 shallow-pool rule).
interface ITwapSource {
    /// @return price WAD USD per whole collateral token over the trailing `window` seconds.
    /// @return ok false if the pool cannot serve the window (not enough observations) or is unusable.
    function twap(uint32 window) external view returns (uint256 price, bool ok);
    /// @notice ±2% depth: L × (√P − √(0.98 P)) of in-range liquidity, valued in WAD USD.
    function depth() external view returns (uint256 depthUsd);
    /// @notice The Uniswap v3 pool read for the TWAP.
    function pool() external view returns (address);
    /// @notice The priced token.
    function baseToken() external view returns (address);
    /// @notice The quote token (USD stablecoin).
    function quoteToken() external view returns (address);
}
