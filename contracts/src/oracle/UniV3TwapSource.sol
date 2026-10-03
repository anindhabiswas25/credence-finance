// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ITwapSource} from "../interfaces/ITwapSource.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {GasGuard} from "../libraries/GasGuard.sol";

/// @dev The subset of the Uniswap v3 pool interface this source reads.
interface IUniswapV3PoolMinimal {
    /// @notice Uniswap v3 pool: token0.
    function token0() external view returns (address);
    /// @notice Uniswap v3 pool: token1.
    function token1() external view returns (address);
    /// @notice Uniswap v3 pool: in-range liquidity.
    function liquidity() external view returns (uint128);
    /// @notice Uniswap v3 pool: current price and tick.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    /// @notice Uniswap v3 pool: cumulative ticks at the given ages.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @title UniV3TwapSource: the DEX weekend/overnight signal for one stock token (Build Guide §8.3.2).
/// @notice The price only ever enters valuation through `min(refPrice, twap)`, and is ignored when the pool is
///         shallow (depth < minDepth in the adapter). The quote token (USDC) is valued at $1 (§7.1).
/// @dev Price from the arithmetic-mean tick: P = 1.0001^tick × 10^(dec0 − dec1), evaluated as
///      expWad(tick·ln(1.0001) ± Δdec·ln(10)) so the exponent stays small and the result keeps full WAD precision.
///      Relative error ≤ |tick| × 0.5e-18 + expWad error < 1e-12 for every valid tick. No TickMath port is needed.
contract UniV3TwapSource is ITwapSource, ICredenceErrors {
    int256 internal constant LN_1_0001_WAD = 99_995_000_333_308; // ln(1.0001) × 1e18
    int256 internal constant LN_10_WAD = 2_302_585_092_994_045_684; // ln(10) × 1e18
    uint256 internal constant ONE_MINUS_SQRT_098_WAD = 10_050_506_338_833_466; // (1 − √0.98) × 1e18
    uint256 internal constant Q96 = 2 ** 96;
    int24 internal constant MAX_TICK = 887_272;

    address public immutable pool;
    address public immutable baseToken;
    address public immutable quoteToken;
    bool public immutable baseIsToken0;
    uint8 internal immutable _baseDec;
    uint8 internal immutable _quoteDec;

    constructor(address pool_, address baseToken_, address quoteToken_) {
        if (pool_ == address(0) || baseToken_ == address(0) || quoteToken_ == address(0)) {
            revert ZeroAddress();
        }
        address t0 = IUniswapV3PoolMinimal(pool_).token0();
        address t1 = IUniswapV3PoolMinimal(pool_).token1();
        if (!((t0 == baseToken_ && t1 == quoteToken_) || (t0 == quoteToken_ && t1 == baseToken_))) {
            revert InvalidParam();
        }
        pool = pool_;
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        baseIsToken0 = t0 == baseToken_;
        _baseDec = IERC20Metadata(baseToken_).decimals();
        _quoteDec = IERC20Metadata(quoteToken_).decimals();
    }

    /// @inheritdoc ITwapSource
    function twap(uint32 window) external view returns (uint256 price, bool ok) {
        if (window == 0) return (0, false);
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        uint256 g0 = gasleft();
        try IUniswapV3PoolMinimal(pool).observe(ago) returns (int56[] memory cum, uint160[] memory) {
            if (cum.length != 2) return (0, false);
            int56 delta = cum[1] - cum[0];
            int24 tick = int24(delta / int56(uint56(window)));
            if (delta < 0 && (delta % int56(uint56(window)) != 0)) tick--; // round toward −∞ (Uniswap OracleLibrary)
            if (tick > MAX_TICK || tick < -MAX_TICK) return (0, false);
            price = priceAtTick(tick);
            ok = price != 0;
        } catch {
            GasGuard.check(g0);
            return (0, false);
        }
    }

    /// @notice WAD USD per whole base token at `tick`.
    function priceAtTick(int24 tick) public view returns (uint256) {
        // raw price of token0 in token1 units = 1.0001^tick; per whole tokens: × 10^(dec0 − dec1)
        (uint8 dec0, uint8 dec1) = baseIsToken0 ? (_baseDec, _quoteDec) : (_quoteDec, _baseDec);
        int256 x = int256(tick) * LN_1_0001_WAD + (int256(uint256(dec0)) - int256(uint256(dec1))) * LN_10_WAD;
        if (!baseIsToken0) x = -x; // base is token1: invert
        if (x >= 135_305_999_368_893_231_589) return 0; // expWad overflow bound: unusable
        int256 r = FPM.expWad(x);
        return r <= 0 ? 0 : uint256(r);
    }

    /// @inheritdoc ITwapSource
    /// @dev Δy = L × (√P − √(0.98 P)) = L × √P × (1 − √0.98) in raw token1 units, from in-range liquidity.
    function depth() external view returns (uint256 depthUsd) {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
        uint256 liq = IUniswapV3PoolMinimal(pool).liquidity();
        if (liq == 0 || sqrtPriceX96 == 0) return 0;
        uint256 dyRaw = FPM.fullMulDiv(FPM.fullMulDiv(liq, sqrtPriceX96, Q96), ONE_MINUS_SQRT_098_WAD, 1e18);
        if (baseIsToken0) {
            // token1 is the quote: value = raw / 10^quoteDec, in WAD
            return FPM.fullMulDiv(dyRaw, 1e18, 10 ** _quoteDec);
        }
        // token1 is the base: value = raw / 10^baseDec × price
        return FPM.fullMulDiv(dyRaw, priceAtTick(tick), 10 ** _baseDec);
    }
}
