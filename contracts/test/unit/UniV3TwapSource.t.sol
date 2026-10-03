// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {UniV3TwapSource} from "../../src/oracle/UniV3TwapSource.sol";
import {MockUniV3Pool} from "../mocks/MockUniV3Pool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Reference values are 1.0001^tick computed off-chain with 60-digit decimals (not with the contract's math).
contract UniV3TwapSourceTest is Test {
    MockERC20 base18;
    MockERC20 usdc;
    MockERC20 base6;

    function setUp() public {
        base18 = new MockERC20("tNVDA", "tNVDA", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        base6 = new MockERC20("B6", "B6", 6);
    }

    function _src(address t0, address t1, address base, address quote)
        internal
        returns (UniV3TwapSource s, MockUniV3Pool p)
    {
        p = new MockUniV3Pool(t0, t1);
        s = new UniV3TwapSource(address(p), base, quote);
    }

    function _rel(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 d = a > b ? a - b : b - a;
        return d * 1e18 / b;
    }

    function test_constructor() public {
        MockUniV3Pool p = new MockUniV3Pool(address(base18), address(usdc));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new UniV3TwapSource(address(0), address(base18), address(usdc));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new UniV3TwapSource(address(p), address(0), address(usdc));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new UniV3TwapSource(address(p), address(base18), address(0));
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        new UniV3TwapSource(address(p), address(base6), address(usdc));
        UniV3TwapSource s = new UniV3TwapSource(address(p), address(base18), address(usdc));
        assertTrue(s.baseIsToken0());
        assertEq(s.pool(), address(p));
        assertEq(s.baseToken(), address(base18));
        assertEq(s.quoteToken(), address(usdc));
        UniV3TwapSource r = new UniV3TwapSource(address(p), address(usdc), address(base18)); // reversed roles
        assertFalse(r.baseIsToken0());
    }

    function test_priceAtTickMatchesReference() public {
        (UniV3TwapSource s,) = _src(address(base6), address(usdc), address(base6), address(usdc)); // equal decimals
        assertEq(s.priceAtTick(0), 1e18);
        assertLe(_rel(s.priceAtTick(69_081), 999_999_339_043_354_493_036), 1e6, "1.0001^69081");
        assertLe(_rel(s.priceAtTick(1), 1_000_100_000_000_000_000), 1e6);
        assertLe(_rel(s.priceAtTick(-1), 999_900_009_999_000_100), 1e6);
        // an 18-dec stock token quoted in 6-dec USDC at ≈ $180 (tick −224,392)
        (UniV3TwapSource t,) = _src(address(base18), address(usdc), address(base18), address(usdc));
        assertLe(_rel(t.priceAtTick(-224_392), 179_997_507_061_653_823_483), 1e6);
        // base is token1: the price inverts
        (UniV3TwapSource u,) = _src(address(usdc), address(base18), address(base18), address(usdc));
        assertLe(_rel(u.priceAtTick(224_392), 179_997_507_061_653_823_483), 1e6);
        // an exponent past expWad's domain is unusable, not a revert; one far below it underflows to 0
        MockERC20 d36 = new MockERC20("D36", "D36", 36);
        MockERC20 d0 = new MockERC20("D0", "D0", 0);
        (UniV3TwapSource v,) = _src(address(d36), address(d0), address(d36), address(d0));
        assertEq(v.priceAtTick(887_272), 0);
        (UniV3TwapSource w,) = _src(address(d0), address(d36), address(d0), address(d36));
        assertEq(w.priceAtTick(-887_272), 0);
    }

    function testFuzz_adjacentTicks(int24 tick) public {
        tick = int24(bound(tick, -400_000, 400_000));
        (UniV3TwapSource s,) = _src(address(base6), address(usdc), address(base6), address(usdc));
        uint256 a = s.priceAtTick(tick);
        uint256 b = s.priceAtTick(tick + 1);
        if (a > 1e12) assertLe(_rel(b, a * 10_001 / 10_000), 1e9, "one tick = 1 bp");
    }

    function test_twap() public {
        (UniV3TwapSource s, MockUniV3Pool p) =
            _src(address(base18), address(usdc), address(base18), address(usdc));
        p.set(0, 0, 0, -224_392);
        (uint256 price, bool ok) = s.twap(3600);
        assertTrue(ok);
        assertLe(_rel(price, 179_997_507_061_653_823_483), 1e6);
        (, ok) = s.twap(0);
        assertFalse(ok);
        // a non-integral negative mean rounds toward −∞ (Uniswap OracleLibrary): −224391.9997 → −224392
        p.setCumExtra(1);
        (uint256 p2,) = s.twap(3600);
        assertEq(p2, price);
        p.setCumExtra(0);
        p.setFlags(true, false);
        (, ok) = s.twap(3600);
        assertFalse(ok, "observe reverts (OLD): unusable");
        p.setFlags(false, true);
        (, ok) = s.twap(3600);
        assertFalse(ok, "malformed observe");
        p.setFlags(false, false);
        p.set(0, 0, 0, 900_000); // beyond MAX_TICK
        (, ok) = s.twap(60);
        assertFalse(ok);
        MockERC20 d36 = new MockERC20("D36", "D36", 36);
        MockERC20 d0 = new MockERC20("D0", "D0", 0);
        (UniV3TwapSource v, MockUniV3Pool pv) = _src(address(d36), address(d0), address(d36), address(d0));
        pv.set(0, 0, 0, 887_272); // price overflows expWad → 0 → not ok
        (, ok) = v.twap(60);
        assertFalse(ok);
    }

    function test_depth() public {
        // token1 = USDC (quote): Δy = L·√P·(1 − √0.98)
        (UniV3TwapSource s, MockUniV3Pool p) =
            _src(address(base18), address(usdc), address(base18), address(usdc));
        assertEq(s.depth(), 0);
        uint160 sqrtP = uint160(2 ** 96) / 1e6 * 13_416; // √(1.8e-10) ≈ 1.3416e-5
        p.set(sqrtP, -224_392, 2e18, 0);
        uint256 dyRaw = uint256(2e18) * sqrtP / 2 ** 96 * 10_050_506_338_833_466 / 1e18;
        assertLe(_rel(s.depth(), dyRaw * 1e18 / 1e6), 1e10);
        // token1 = base: Δy tokens valued at the spot tick
        (UniV3TwapSource r, MockUniV3Pool q) =
            _src(address(usdc), address(base18), address(base18), address(usdc));
        q.set(uint160(2 ** 96) * 74_535, 224_392, 1e12, 0); // √(5.55e9)
        uint256 dy = uint256(1e12) * 74_535 * 10_050_506_338_833_466 / 1e18;
        assertLe(_rel(r.depth(), dy * r.priceAtTick(224_392) / 1e18), 1e10);
        q.set(0, 0, 1e12, 0);
        assertEq(r.depth(), 0);
    }
}
