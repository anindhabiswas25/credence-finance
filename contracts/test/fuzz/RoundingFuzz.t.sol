// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {SharesMath} from "../../src/libraries/SharesMath.sol";
import {WadMath} from "../../src/libraries/WadMath.sol";
import {Auction, LotInfo} from "../../src/libraries/Types.sol";
import {RiskFixture} from "../utils/RiskFixture.sol";

/// @title The Build Guide §7.2 rounding table, row by row, against the exact rational value (QA-sec S4 item C).
/// @notice Every conversion must round in the protocol's favour. Library rows are checked by cross-multiplication
///         (no division, so the check itself cannot round); the market rows through the real CredenceMarket.
///         Rows owned by the Rust engine (premium up, lot x up) are proven in risk-core's property tests
///         (docs/security/invariant-map.md §7.2).
contract RoundingLibFuzz is Test {
    uint256 internal constant VS = 1e6; // SharesMath virtual shares
    uint256 internal constant VA = 1; // SharesMath virtual assets

    /// @dev Shares minted on borrow round UP; shares burned on repay and vault / pool shares minted round DOWN.
    function testFuzz_sharesDirections(uint256 a, uint256 ta, uint256 ts) public pure {
        a = bound(a, 0, 1e30);
        ta = bound(ta, 0, 1e30);
        ts = bound(ts, 0, 1e36);
        uint256 dn = SharesMath.toSharesDown(a, ta, ts);
        uint256 up = SharesMath.toSharesUp(a, ta, ts);
        // exact = a (ts + VS) / (ta + VA)
        assertLe(dn * (ta + VA), a * (ts + VS), "toSharesDown <= exact");
        assertGe(up * (ta + VA), a * (ts + VS), "toSharesUp >= exact");
        assertLe(up - dn, 1);
    }

    /// @dev Debt from borrow shares rounds UP; assets paid out on redeem round DOWN.
    function testFuzz_assetsDirections(uint256 s, uint256 ta, uint256 ts) public pure {
        s = bound(s, 0, 1e36);
        ta = bound(ta, 0, 1e30);
        ts = bound(ts, 0, 1e36);
        uint256 dn = SharesMath.toAssetsDown(s, ta, ts);
        uint256 up = SharesMath.toAssetsUp(s, ta, ts);
        assertLe(dn * (ts + VS), s * (ta + VA), "toAssetsDown <= exact");
        assertGe(up * (ts + VS), s * (ta + VA), "toAssetsUp >= exact");
        assertLe(up - dn, 1);
    }

    /// @dev A borrow's debt (shares minted up, debt read up) is never below what was lent.
    function testFuzz_borrowThenReadDebt(uint256 a, uint256 ta, uint256 ts) public pure {
        a = bound(a, 1, 1e24);
        ta = bound(ta, 0, 1e24);
        ts = bound(ts, ta == 0 ? 0 : 1, 1e36);
        uint256 minted = SharesMath.toSharesUp(a, ta, ts);
        uint256 debt = SharesMath.toAssetsUp(minted, ta + a, ts + minted);
        assertGe(debt, a, "debt >= borrowed");
    }

    /// @dev Collateral value DOWN, LTV (limit checks) UP, health factor DOWN.
    function testFuzz_valueLtvHf(uint256 q, uint256 v, uint8 cd, uint8 ld, uint256 d, uint256 lt)
        public
        pure
    {
        cd = uint8(bound(cd, 0, 18));
        ld = uint8(bound(ld, 0, 18));
        q = bound(q, 0, 1e30);
        v = bound(v, 0, 1e24);
        uint256 c = WadMath.collateralValue(q, v, cd, ld);
        // exact: q v 10^ld / (10^cd 1e18)
        assertLe(c * (10 ** cd) * 1e18, q * v * (10 ** ld), "collateral value rounds down");
        d = bound(d, 0, 1e30);
        uint256 l = WadMath.ltvUp(d, c);
        if (d != 0 && c != 0) assertGe(l * c, d * 1e18, "LTV rounds up");
        lt = bound(lt, 0, 1e18);
        uint256 h = WadMath.healthFactorDown(c, lt, d);
        if (d != 0) assertLe(h * d, c * lt, "HF rounds down");
    }
}

/// @notice The §7.2 rows the market applies itself, through the real CredenceMarket (S3 stack).
contract RoundingMarketFuzz is RiskFixture {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        setUpRisk();
        _underwrite(uw1, 500_000e6);
        // a seasoned market: shares no longer 1:1 with assets
        _position(makeAddr("seed"), idNVDA, tNVDA, 10_000e18, 900_000e6 / 4);
        vm.warp(block.timestamp + 97 days + 13);
        _day(0, 0);
    }

    function testFuzz_borrowDebtRoundsUp(uint256 amount, uint256 dt) public {
        amount = bound(amount, 1, 100_000e6);
        vm.warp(block.timestamp + bound(dt, 0, 30 days));
        _position(alice, idNVDA, tNVDA, 1_000e18, amount);
        assertGe(market.debtOf(idNVDA, alice), amount, "debt >= borrowed");
        // closing by shares right away costs at least what was borrowed
        uint256 shares = market.position(idNVDA, alice).borrowShares;
        usdc.mint(alice, amount + 1e6);
        vm.startPrank(alice);
        usdc.approve(address(market), type(uint256).max);
        uint256 paid = market.repay(idNVDA, alice, 0, shares);
        vm.stopPrank();
        assertGe(paid, amount, "no free money: borrow then close");
    }

    function testFuzz_repayNeverOverCredits(uint256 amount, uint256 x, uint256 dt) public {
        amount = bound(amount, 2, 100_000e6);
        _position(alice, idNVDA, tNVDA, 1_000e18, amount);
        vm.warp(block.timestamp + bound(dt, 0, 30 days));
        uint256 before = market.debtOf(idNVDA, alice);
        x = bound(x, 1, before - 1);
        usdc.mint(alice, x);
        vm.startPrank(alice);
        usdc.approve(address(market), x);
        try market.repay(idNVDA, alice, x, 0) returns (uint256 paid) {
            vm.stopPrank();
            assertEq(paid, x, "pays exactly the amount");
            assertLe(before - market.debtOf(idNVDA, alice), x, "debt falls by at most what was paid");
        } catch (bytes memory err) {
            vm.stopPrank();
            // x below one share's worth burns 0 shares: refused, never credited
            assertEq(bytes4(err), bytes4(keccak256("ZeroAmount()")));
        }
    }

    /// @dev Proceeds per position round DOWN and the last position settled gets the dust: Σ = the lot's proceeds.
    function testFuzz_settleProceedsDustToLast(uint256 qa, uint256 qb, uint256 pBps, bool bobFirst) public {
        vm.warp(_openAt(1, 1) + 1 hours);
        _day(1, 1);
        qa = bound(qa, 10e18, 1_000e18); // both fit the NVDA market's liquidity
        qb = bound(qb, 10e18, 1_000e18);
        _position(alice, idNVDA, tNVDA, qa, qa * 180 * 70 / 100 / 1e12);
        _position(bob, idNVDA, tNVDA, qb, qb * 180 * 72 / 100 / 1e12);
        orc.setPrice(NVDA, 150e18); // both under water
        address[] memory bs = new address[](2);
        (bs[0], bs[1]) = bobFirst ? (bob, alice) : (alice, bob);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, bs);
        uint64 id = market.position(idNVDA, alice).auctionId;
        vm.warp(block.timestamp + 15);
        house.fixLots(id);
        Auction memory a = house.auction(id);
        // one bidder takes part of the lot at a price in [R, 1.3 V]; the pool backstops the rest
        uint256 price =
            uint256(a.reserve) + (130e18 - uint256(a.reserve) * 100 / 150) * bound(pBps, 0, 10_000) / 10_000;
        address bidder = makeAddr("bidder");
        usdc.mint(bidder, 10_000_000e6);
        vm.startPrank(bidder);
        usdc.approve(address(house), type(uint256).max);
        uint128 bq = uint128(uint256(a.lot) * (1 + bound(pBps, 0, 99)) / 100);
        if (uint256(bq) * price / 1e30 >= 100e6) house.placeBid(id, bq, uint128(price));
        vm.stopPrank();
        vm.warp(a.deadlines[3]);
        house.clear(id);
        vm.recordLogs();
        market.settlePositions(id, bs);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        LotInfo memory li = market.lotInfo(id);
        assertEq(li.settledCount, li.positions);
        assertEq(li.proceedsSettled, li.proceeds, "every unit of proceeds is allocated, dust to the last");
        // per position: P_i = value(x_i, p̄) rounded down, except the last settled, which takes the remainder
        bytes32 sig = keccak256(
            "PositionSettled(bytes32,address,uint64,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        uint256 seen;
        uint256 sum;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            (uint256 x, uint256 p) = abi.decode(logs[i].data, (uint256, uint256));
            uint256 floorValue = x * li.blendedPrice / 1e30;
            if (++seen < li.positions) assertEq(p, floorValue, "proceeds per position round down");
            else assertGe(p, floorValue, "the last position gets the dust");
            sum += p;
        }
        assertEq(seen, li.positions);
        assertEq(sum, li.proceeds);
    }
}
