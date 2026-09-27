// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @dev Uniswap v3 pool stub: a constant mean tick over any window, settable slot0 / liquidity, failure switches.
contract MockUniV3Pool {
    address public token0;
    address public token1;
    uint128 public liquidity;
    uint160 public sqrtP;
    int24 public spotTick;
    int56 public meanTick;
    int56 public cumBase = 1_000_000;
    int56 public cumExtra; // added to the latest cumulative only (non-integral mean ticks)
    bool public revertObserve;
    bool public shortObserve;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function set(uint160 sqrtPriceX96, int24 tick, uint128 liq, int56 mean) external {
        sqrtP = sqrtPriceX96;
        spotTick = tick;
        liquidity = liq;
        meanTick = mean;
    }

    function setFlags(bool revertObs, bool shortObs) external {
        revertObserve = revertObs;
        shortObserve = shortObs;
    }

    function setCumExtra(int56 c) external {
        cumExtra = c;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtP, spotTick, 0, 1, 1, 0, true);
    }

    function observe(uint32[] calldata ago) external view returns (int56[] memory cum, uint160[] memory spl) {
        require(!revertObserve, "OLD");
        uint256 n = shortObserve ? 1 : ago.length;
        cum = new int56[](n);
        spl = new uint160[](n);
        for (uint256 i; i < n; ++i) {
            // cumulative at (now − ago[i]) for a constant tick
            cum[i] = cumBase - meanTick * int56(uint56(ago[i])) + (ago[i] == 0 ? cumExtra : int56(0));
        }
    }
}
