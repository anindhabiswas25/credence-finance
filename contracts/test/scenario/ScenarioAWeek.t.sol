// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CoreFixture} from "../utils/CoreFixture.sol";
import {RateParams, ClockState, ClosureType, BellStatus} from "../../src/libraries/Types.sol";

/// @notice Scenario A ("One week of money in Credence Finance"), Monday to the Friday Bell, to the cent (brief E,
///         acceptance 5). The doc holds the borrow rate at 7.29% all week and splits interest 80 / 10 / 10; the
///         markets here use that flat rate. Safe LTVs after Thursday's σ update are injected into MockRiskEngine at
///         the doc's full-precision values (Appendix A v1.1), and Priya's premium at the doc's $35.95 (R-22).
/// @dev Times: Mon 2026-10-05 … Fri 2026-10-09, US/Eastern = UTC − 4 h; the close is 16:00 ET = 20:00 UTC.
///      The Bell cures differ from G-10 / G-11 by design: the market projects the debt over the 3-day closure
///      (R-08), the doc does not. The test checks both: the engine's cures at the doc's debt match G-10 / G-11, and
///      the market's cures match the same formula at the projected debt (ADR-0107, report "Spec issues").
contract ScenarioAWeekTest is CoreFixture {
    address lena = makeAddr("lena");
    address rahul = makeAddr("rahul");
    address maya = makeAddr("maya");
    address priya = makeAddr("priya");
    address kai = makeAddr("kai");

    uint40 constant MON = 1_791_158_400; // 2026-10-05 00:00 UTC
    uint256 constant ET = 4 hours; // EDT
    uint256 constant CENT = 1e4; // loan units per cent (6-decimal USDC)

    uint256 constant SAFE_NVDA = 0.712580117506e18; // G-07
    uint256 constant SAFE_TSLA = 0.626773490008e18; // G-08

    function _rate() internal pure override returns (RateParams memory) {
        return RateParams({r0: 0.0729e18, s1: 0, s2: 0, uKink: 0.9e18}); // held at 7.29% all week (the doc)
    }

    function _at(uint256 day, uint256 hhmmEt) internal pure returns (uint256) {
        return MON + day * 1 days + (hhmmEt / 100) * 1 hours + (hhmmEt % 100) * 1 minutes + ET;
    }

    function _closeOf(uint256 day) internal pure returns (uint40) {
        return uint40(_at(day, 1600));
    }

    /// @dev Each weekday the next close is that day's 16:00; Friday's is a 3-day WEEKEND closure (R-07).
    function _day(uint256 day) internal {
        bool fri = day == 4;
        for (uint256 i; i < 3; ++i) {
            bytes32 a = [NVDA, AAPL, TSLA][i];
            clk.setState(a, ClockState.REGULAR);
            clk.setClosureId(a, uint64(day + 1));
            clk.setNextClose(a, _closeOf(day), fri ? ClosureType.WEEKEND : ClosureType.OVERNIGHT, fri ? 3 : 1);
        }
    }

    function _cents(uint256 actual, uint256 expectedCents, string memory what) internal pure {
        uint256 e = expectedCents * CENT;
        uint256 diff = actual > e ? actual - e : e - actual;
        assertLe(diff, CENT / 2, what); // rounds to the doc's figure
    }

    function setUp() public {
        vm.warp(_at(0, 900));
        setUpCore();
        _day(0);
    }

    function test_mondayToTheFridayBell() public {
        // ── Mon 10:00: Lena deposits $230,000; the allocator spreads it over the three markets ──
        vm.warp(_at(0, 1000));
        _deposit(lena, 230_000e6);
        assertEq(vault.totalAssets(), 230_000e6);
        vm.startPrank(allocator);
        vault.deallocate(idAAPL, 130_000e6);
        vault.allocate(idTSLA, 60_000e6);
        vault.allocate(idNVDA, 70_000e6);
        vm.stopPrank();
        // Rahul: 500 AAPL at $200, borrows $60,000 (60% LTV, HF 1.33)
        _collateral(rahul, idAAPL, tAAPL, 500e18);
        _borrow(rahul, idAAPL, 60_000e6);
        assertEq(market.ltv(idAAPL, rahul), 0.6e18);
        assertEq(market.healthFactor(idAAPL, rahul) / 1e16, 133);

        // ── Tue 10:00: Maya, 300 TSLA at $250, borrows $55,500 (74.0%, HF 1.08); auto-cover off ──
        _day(1);
        vm.warp(_at(1, 1000));
        _collateral(maya, idTSLA, tTSLA, 300e18);
        _borrow(maya, idTSLA, 55_500e6);
        vm.prank(maya);
        market.setAutoCover(idTSLA, false);
        assertEq(market.ltv(idTSLA, maya), 0.74e18);
        assertEq(market.healthFactor(idTSLA, maya) / 1e16, 108);

        // ── Wed 10:00: Priya, 500 NVDA at $180, borrows $67,000 (74.4%, HF 1.07) ──
        _day(2);
        vm.warp(_at(2, 1000));
        _collateral(priya, idNVDA, tNVDA, 500e18);
        _borrow(priya, idNVDA, 67_000e6);
        assertEq(market.healthFactor(idNVDA, priya) / 1e16, 107);

        // every weeknight Bell: overnight safe LTVs are above 75%, nobody must act
        _day(3);
        vm.warp(_at(3, 1545));
        assertEq(uint8(_status(idNVDA, priya)), uint8(BellStatus.SAFE));
        assertEq(uint8(_status(idTSLA, maya)), uint8(BellStatus.SAFE));

        // ── Thu 17:00: σ ×1.5 → weekend safe LTVs 75% (AAPL, capped) / 71.26% (NVDA) / 62.68% (TSLA) ──
        engine.setSafeLtv(NVDA, uint8(ClosureType.WEEKEND), SAFE_NVDA);
        engine.setSafeLtv(TSLA, uint8(ClosureType.WEEKEND), SAFE_TSLA);

        // ── Fri 14:00: the Bell window opens ──
        _day(4);
        vm.warp(_at(4, 1400));
        _cents(market.debtOf(idAAPL, rahul), 6_004_993, "Rahul debt 60,049.93");
        _cents(market.debtOf(idNVDA, priya), 6_702_899, "Priya debt 67,028.99");
        _cents(market.debtOf(idTSLA, maya), 5_553_510, "Maya debt 55,535.10");
        assertEq((market.ltv(idAAPL, rahul) + 5e13) / 1e14, 6005, "Rahul LTV 60.05%");
        assertEq((market.ltv(idNVDA, priya) + 5e13) / 1e14, 7448, "Priya LTV 74.48%");
        assertEq((market.ltv(idTSLA, maya) + 5e13) / 1e14, 7405, "Maya LTV 74.05%");
        assertEq(uint8(_status(idAAPL, rahul)), uint8(BellStatus.SAFE), "Rahul SAFE");

        // Appendix A G-10 / G-11: the engine's cures at the doc's debts, to the cent
        (uint8 st, uint256 repayP, uint256 addValP) =
            engine.bellStatus(NVDA, 2, 90_000e6, 67_028.99e6, 0.75e18, 0, false);
        assertEq(st, 1);
        _cents(repayP, 289_678, "G-10 repay 2,896.78");
        assertApproxEqAbs(addValP * 1e30 / 180e18, 22.584e18, 0.0005e18, "G-10 add 22.584 NVDA");
        (, uint256 repayM, uint256 addValM) = engine.bellStatus(TSLA, 2, 75_000e6, 55_535.10e6, 0.75e18, 0, false);
        _cents(repayM, 852_709, "G-11 repay 8,527.09");
        assertApproxEqAbs(addValM * 1e30 / 250e18, 54.419e18, 0.0005e18, "G-11 add 54.419 TSLA");

        // the market's own Bell check uses the projected debt (R-08): D × (1 + 7.29% × 3/365)
        (BellStatus bs, uint256 cureRepay,,) = market.bellStatus(idNVDA, priya);
        assertEq(uint8(bs), uint8(BellStatus.NEEDS_ACTION));
        uint256 dProj = market.projectedDebt(idNVDA, priya);
        assertEq(dProj, _projected(market.debtOf(idNVDA, priya)));
        assertEq(cureRepay, dProj - SAFE_NVDA * 90_000e6 / 1e18, "market cure = F-4.2 at D_proj");
        (bs,,,) = market.bellStatus(idTSLA, maya);
        assertEq(uint8(bs), uint8(BellStatus.NEEDS_ACTION));

        // ── Fri 15:30: Priya buys Gap Cover for $35.95 from her wallet ──
        vm.warp(_at(4, 1530));
        pool.setPremium(35.95e6, 0.2e18); // doc premium (R-22: scenario tests inject the doc's figures)
        usdc.mint(priya, 35.95e6);
        vm.startPrank(priya);
        usdc.approve(address(market), 35.95e6);
        market.buyCover(idNVDA, 35.95e6, false);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(pool)), 35.95e6, "premium in the pool");
        assertEq(uint8(_status(idNVDA, priya)), uint8(BellStatus.COVERED));
        assertEq(market.coveredCollateral(idNVDA, 6), 500e18);

        // ── Fri 15:45: the Bell deadline; Kai enforces it on Maya (auto-cover off → pre-close sale) ──
        vm.warp(_at(4, 1545));
        address[] memory bs3 = new address[](3);
        (bs3[0], bs3[1], bs3[2]) = (rahul, priya, maya);
        vm.prank(kai);
        market.enforceBell(idTSLA, bs3);
        vm.prank(kai);
        market.enforceBell(idNVDA, bs3); // Priya is covered: skipped, no tip
        uint64 lotId = market.position(idTSLA, maya).auctionId;
        assertGt(lotId, 0, "Maya queued for the pre-close sale");
        assertEq(usdc.balanceOf(kai), 2e6, "one tip: Maya (Rahul and Priya skipped)");

        // ── Fri 15:50: lot fixed at R_pre = 99% × $250 = $247.50, sized down to the safe LTV (R-06, G-17) ──
        vm.warp(_at(4, 1550));
        uint256 x = ah.fix(lotId);
        uint256 dMaya = market.projectedDebt(idTSLA, maya);
        // cleared at R, the debt after the 1% penalty lands at the safe LTV (G-17 property)
        uint256 proceedsAtR = x * 247.5e18 / 1e30;
        uint256 debtAfter = dMaya - proceedsAtR * 99 / 100;
        uint256 collAfter = (300e18 - x) * 250e18 / 1e30;
        assertApproxEqAbs(debtAfter * 1e18 / collAfter, SAFE_TSLA, 1e11, "LTV after = safe LTV");
        // G-17 at the doc's debt of $55,536.02: 96.5454 TSLA (the doc's 94.43 predates R-06); the market's lot is
        // larger because it sizes on the projected debt (R-08)
        uint256 g17 = engine.precloseLot(55_536.02e6, 300e18, 250e18, 247.5e18, SAFE_TSLA, 0.01e18, 18, 6);
        assertApproxEqAbs(g17, 96.5454e18, 0.00005e18, "G-17 96.5454");
        assertEq(x, engine.precloseLot(dMaya, 300e18, 250e18, 247.5e18, SAFE_TSLA, 0.01e18, 18, 6), "lot at D_proj");
        assertGt(x, g17);

        // ── 16:00: the batch clears at $249.50 (Mo); settlement: 1% penalty split ⅓ / ⅓ / ⅓ ──
        uint256 proceeds = x * 249.5e18 / 1e30;
        usdc.mint(address(ah), proceeds);
        ah.clearAt(lotId, 249.5e18, usdc, 18, 6);
        uint256 debtBefore = market.debtOf(idTSLA, maya);
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 treasuryBefore = usdc.balanceOf(address(treasury));
        address[] memory m1 = new address[](1);
        m1[0] = maya;
        market.settlePositions(lotId, m1);
        uint256 penalty = proceeds / 100;
        uint256 third = penalty / 3;
        assertEq(usdc.balanceOf(address(pool)) - poolBefore, third, "pool: 1/3 of the penalty");
        assertEq(reserve.balance(), third, "reserve: 1/3");
        assertEq(usdc.balanceOf(address(treasury)) - treasuryBefore, penalty - 2 * third, "treasury: the rest");
        assertApproxEqAbs(market.debtOf(idTSLA, maya), debtBefore - (proceeds - penalty), 1, "debt - (1 - lambda) P");
        assertEq(market.position(idTSLA, maya).collateral, 300e18 - x);
        (bs,,,) = market.bellStatus(idTSLA, maya);
        assertEq(uint8(bs), uint8(BellStatus.SAFE), "Maya is safe into the weekend");

        // Rahul did nothing and is fine; Lena lost nothing
        assertEq(uint8(_status(idAAPL, rahul)), uint8(BellStatus.SAFE));
        assertGe(vault.totalAssets(), 230_000e6);
    }

    function _status(bytes32 id, address b) internal view returns (BellStatus s) {
        (s,,,) = market.bellStatus(id, b);
    }

    function _projected(uint256 d) internal pure returns (uint256) {
        uint256 growth = (uint256(0.0729e18) * 3 + 364) / 365; // ⌈r × 3 / 365⌉
        return (d * (1e18 + growth) + 1e18 - 1) / 1e18;
    }
}
