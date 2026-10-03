// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {WadMath} from "../../src/libraries/WadMath.sol";
import {SharesMath} from "../../src/libraries/SharesMath.sol";
import {PackedInt} from "../../src/libraries/PackedInt.sol";
import {ClockLib} from "../../src/libraries/ClockLib.sol";
import {ClockState} from "../../src/libraries/Types.sol";

/// @dev External wrappers so reverts inside the libraries are observable.
contract PackedIntHarness {
    function getU64(uint256[] memory w, uint256 i) external pure returns (uint64) {
        return PackedInt.getU64(w, i);
    }

    function setU64(uint256[] memory w, uint256 i, uint64 v) external pure returns (uint256[] memory) {
        PackedInt.setU64(w, i, v);
        return w;
    }

    function packU64(uint256[] memory v) external pure returns (uint256[] memory) {
        return PackedInt.packU64(v);
    }

    function unpackU64(uint256[] memory w, uint256 n) external pure returns (uint256[] memory) {
        return PackedInt.unpackU64(w, n);
    }

    function addU64(uint256[] memory a, uint256[] memory b, uint256 n)
        external
        pure
        returns (uint256[] memory)
    {
        return PackedInt.addU64(a, b, n);
    }

    function maxU64(uint256[] memory w, uint256 n) external pure returns (uint64) {
        return PackedInt.maxU64(w, n);
    }

    function getI16Word(uint256 w, uint256 lane) external pure returns (int16) {
        return PackedInt.getI16(w, lane);
    }

    function getI16(uint256[] memory w, uint256 i) external pure returns (int16) {
        return PackedInt.getI16(w, i);
    }

    function unpackI16(uint256[] memory w, uint256 n) external pure returns (int16[] memory) {
        return PackedInt.unpackI16(w, n);
    }

    function isSortedI16(uint256[] memory w, uint256 n) external pure returns (bool) {
        return PackedInt.isSortedI16(w, n);
    }
}

contract LibrariesTest is Test {
    using WadMath for uint256;

    uint256 constant WAD = 1e18;
    PackedIntHarness h;

    function setUp() public {
        h = new PackedIntHarness();
    }

    // ───────────── WadMath ─────────────

    function test_wadRounding() public pure {
        assertEq(uint256(7).mulWadDown(0.5e18), 3);
        assertEq(uint256(7).mulWadUp(0.5e18), 4);
        assertEq(uint256(1).divWadDown(3e18), 0);
        assertEq(uint256(1).divWadUp(3e18), 1);
        assertEq(WadMath.mulDivDown(7, 3, 2), 10);
        assertEq(WadMath.mulDivUp(7, 3, 2), 11);
        assertEq(WadMath.min(1, 2), 1);
        assertEq(WadMath.max(1, 2), 2);
    }

    function test_valueLtvHf() public pure {
        // 100 tokens × $180 = $18,000 (6-dec USDC)
        uint256 c = WadMath.collateralValue(100e18, 180e18, 18, 6);
        assertEq(c, 18_000e6);
        assertEq(WadMath.ltvUp(13_500e6, c), 0.75e18);
        assertEq(WadMath.ltvUp(0, c), 0);
        assertEq(WadMath.ltvUp(1, 0), type(uint256).max);
        assertEq(WadMath.healthFactorDown(c, 0.8e18, 13_500e6), 1_066_666_666_666_666_666);
        assertEq(WadMath.healthFactorDown(c, 0.8e18, 0), type(uint256).max);
    }

    function test_relDiff() public pure {
        assertEq(WadMath.relDiffUp(101e18, 100e18), 0.01e18);
        assertEq(WadMath.relDiffUp(100e18, 101e18), 0.01e18);
        assertEq(WadMath.relDiffUp(0, 1), type(uint256).max);
        assertEq(WadMath.relDiffUp(1, 0), type(uint256).max);
        assertEq(WadMath.relDiffUp(3, 3), 0);
    }

    function testFuzz_mulWad_directions(uint128 a, uint128 b) public pure {
        uint256 down = uint256(a).mulWadDown(b);
        uint256 up = uint256(a).mulWadUp(b);
        assertLe(down, up);
        assertLe(up - down, 1);
        assertEq(down, uint256(a) * b / WAD);
    }

    function testFuzz_ltvHfConsistent(uint64 debt, uint96 q, uint64 v) public pure {
        vm.assume(debt > 0 && q > 0 && v > 0);
        uint256 c = WadMath.collateralValue(q, v, 18, 6);
        vm.assume(c > 0);
        uint256 ltv = WadMath.ltvUp(debt, c);
        // LTV rounds up: LTV × C ≥ D × 1e18
        assertGe(ltv * c, uint256(debt) * WAD);
        // HF rounds down: HF × D ≤ C × LT
        uint256 hf = WadMath.healthFactorDown(c, 0.8e18, debt);
        assertLe(hf * debt, c * 0.8e18);
    }

    // ───────────── SharesMath ─────────────

    function test_sharesVirtualOffsets() public pure {
        assertEq(SharesMath.toSharesDown(1, 0, 0), 1e6);
        assertEq(SharesMath.toAssetsDown(1e6, 0, 0), 1);
        assertEq(SharesMath.toSharesUp(1, 1, 1e6), 1e6);
        assertEq(SharesMath.toAssetsUp(1, 10, 1e6), 1);
    }

    function testFuzz_sharesRoundTrip(uint96 assets, uint96 totalAssets, uint96 totalShares) public pure {
        uint256 sDown = SharesMath.toSharesDown(assets, totalAssets, totalShares);
        uint256 sUp = SharesMath.toSharesUp(assets, totalAssets, totalShares);
        assertLe(sDown, sUp);
        assertLe(sUp - sDown, 1);
        // minting down then redeeming down never returns more than was put in
        assertLe(SharesMath.toAssetsDown(sDown, totalAssets, totalShares), assets);
        // debt from shares rounded up is at least the borrowed amount when shares were minted up
        assertGe(SharesMath.toAssetsUp(sUp, totalAssets, totalShares), assets);
    }

    // ───────────── PackedInt ─────────────

    function test_u64Layout() public view {
        uint256[] memory vals = new uint256[](5);
        vals[0] = 1;
        vals[1] = 2;
        vals[2] = type(uint64).max;
        vals[3] = 4;
        vals[4] = 5;
        uint256[] memory w = h.packU64(vals);
        assertEq(w.length, 2);
        assertEq(w[1], 5); // lane 0 = least-significant bits
        assertEq(w[0] & type(uint64).max, 1);
        uint256[] memory back = h.unpackU64(w, 5);
        for (uint256 i; i < 5; ++i) {
            assertEq(back[i], vals[i]);
            assertEq(h.getU64(w, i), vals[i]);
        }
        assertEq(h.maxU64(w, 5), type(uint64).max);
        uint256[] memory w2 = h.setU64(w, 3, 9);
        assertEq(h.getU64(w2, 3), 9);
        assertEq(h.getU64(w2, 2), type(uint64).max);
        assertEq(PackedInt.wordsForU64(0), 0);
        assertEq(PackedInt.wordsForI16(17), 2);
    }

    function test_u64Reverts() public {
        uint256[] memory w = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(PackedInt.PackedIndexOutOfRange.selector, 4, 4));
        h.getU64(w, 4);
        vm.expectRevert(abi.encodeWithSelector(PackedInt.PackedIndexOutOfRange.selector, 4, 4));
        h.setU64(w, 4, 1);
        uint256[] memory big = new uint256[](1);
        big[0] = uint256(type(uint64).max) + 1;
        vm.expectRevert(PackedInt.PackedOverflow.selector);
        h.packU64(big);
        vm.expectRevert(abi.encodeWithSelector(PackedInt.PackedIndexOutOfRange.selector, 5, 4));
        h.unpackU64(w, 5);
        vm.expectRevert(abi.encodeWithSelector(PackedInt.PackedIndexOutOfRange.selector, 5, 4));
        h.maxU64(w, 5);
        vm.expectRevert(abi.encodeWithSelector(PackedInt.PackedIndexOutOfRange.selector, 5, 4));
        h.addU64(w, w, 5);
        uint256[] memory full = new uint256[](1);
        full[0] = type(uint64).max;
        uint256[] memory one = new uint256[](1);
        one[0] = 1;
        vm.expectRevert(PackedInt.PackedOverflow.selector);
        h.addU64(full, one, 1);
    }

    function testFuzz_addU64(uint64[8] memory a, uint64[8] memory b) public view {
        uint256[] memory av = new uint256[](8);
        uint256[] memory bv = new uint256[](8);
        for (uint256 i; i < 8; ++i) {
            av[i] = a[i] / 2;
            bv[i] = b[i] / 2;
        }
        uint256[] memory s = h.addU64(h.packU64(av), h.packU64(bv), 8);
        for (uint256 i; i < 8; ++i) {
            assertEq(h.getU64(s, i), av[i] + bv[i]);
        }
    }

    function testFuzz_i16RoundTrip(int16[20] memory v) public view {
        int16[] memory vals = new int16[](20);
        for (uint256 i; i < 20; ++i) {
            vals[i] = v[i];
        }
        uint256[] memory w = PackedInt.packI16(vals);
        int16[] memory back = h.unpackI16(w, 20);
        for (uint256 i; i < 20; ++i) {
            assertEq(back[i], vals[i]);
            assertEq(h.getI16(w, i), vals[i]);
            assertEq(h.getI16Word(w[i / 16], i % 16), vals[i]);
        }
    }

    function test_i16SortedAndReverts() public {
        int16[] memory vals = new int16[](3);
        vals[0] = -5;
        vals[1] = -5;
        vals[2] = 7;
        uint256[] memory w = PackedInt.packI16(vals);
        assertTrue(h.isSortedI16(w, 3));
        vals[2] = -6;
        assertFalse(h.isSortedI16(PackedInt.packI16(vals), 3));
        assertEq(h.getI16Word(0xffff, 0), -1);
        vm.expectRevert(abi.encodeWithSelector(PackedInt.PackedIndexOutOfRange.selector, 16, 16));
        h.getI16Word(0, 16);
        vm.expectRevert(abi.encodeWithSelector(PackedInt.PackedIndexOutOfRange.selector, 16, 16));
        h.getI16(w, 16);
        vm.expectRevert(abi.encodeWithSelector(PackedInt.PackedIndexOutOfRange.selector, 17, 16));
        h.unpackI16(w, 17);
        vm.expectRevert(abi.encodeWithSelector(PackedInt.PackedIndexOutOfRange.selector, 17, 16));
        h.isSortedI16(w, 17);
    }

    // ───────────── ClockLib ─────────────

    function test_rankOrder() public pure {
        assertLt(ClockLib.rank(ClockState.REGULAR), ClockLib.rank(ClockState.EXTENDED));
        assertLt(ClockLib.rank(ClockState.EXTENDED), ClockLib.rank(ClockState.REOPEN));
        assertLt(ClockLib.rank(ClockState.REOPEN), ClockLib.rank(ClockState.CLOSED));
        assertLt(ClockLib.rank(ClockState.CLOSED), ClockLib.rank(ClockState.HALTED));
        assertLt(ClockLib.rank(ClockState.HALTED), ClockLib.rank(ClockState.CORP_ACTION));
        assertEq(
            uint8(ClockLib.mostRestrictive(ClockState.CLOSED, ClockState.REOPEN)), uint8(ClockState.CLOSED)
        );
        assertEq(
            uint8(ClockLib.mostRestrictive(ClockState.REGULAR, ClockState.HALTED)), uint8(ClockState.HALTED)
        );
        assertTrue(ClockLib.isShut(ClockState.CLOSED));
        assertTrue(ClockLib.isShut(ClockState.HALTED));
        assertTrue(ClockLib.isShut(ClockState.CORP_ACTION));
        assertFalse(ClockLib.isShut(ClockState.REOPEN));
        assertFalse(ClockLib.isShut(ClockState.EXTENDED));
    }

    function testFuzz_mostRestrictiveCommutes(uint8 a, uint8 b) public pure {
        ClockState x = ClockState(a % 6);
        ClockState y = ClockState(b % 6);
        ClockState m = ClockLib.mostRestrictive(x, y);
        assertEq(uint8(m), uint8(ClockLib.mostRestrictive(y, x)));
        assertGe(ClockLib.rank(m), ClockLib.rank(x));
        assertGe(ClockLib.rank(m), ClockLib.rank(y));
    }
}
