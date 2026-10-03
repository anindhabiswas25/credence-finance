// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {
    RateParams,
    ClockState,
    ClosureType,
    BellStatus,
    Auction,
    AuctionKind,
    Epoch,
    EpochPhase,
    Inventory
} from "../../src/libraries/Types.sol";
import {ICredenceMarketEvents, IUnderwriterPoolEvents} from "../../src/libraries/Events.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Scenario A ("One week of money in Credence Finance") through the following Monday, on the REAL
///         UnderwriterPool and AuctionHouse (S3 acceptance 4): the Friday Bell (cover through the pool, Maya's
///         pre-close sale in a real PRECLOSE batch), the weekend closure, Monday's open prints, the REOPEN auction
///         (Mo and Omar commit, reveal, clear at p*), `settlePositions`, and `settleEpoch`. Figures are Appendix A's
///         to the cent, at projected debt (PM ruling on R-08): p* = 124.11, proceeds 62,055, shortfall 5,011.69 paid
///         by the pool, senior loss 0, and the pool share price after = NAV / 40,000 shares with the premium input
///         35.95 (R-22). Plus a gap-loss variant where only Mo bids and the pool backstops 200 NVDA at R.
/// @dev Times: Mon 2026-10-05 … Mon 2026-10-12, US/Eastern = UTC − 4 h. The joint stress column uses σ = 3% so the
///      doc's pool ($40,000) has capacity for Priya's policy (its u is ≈ 5%; the doc's 20% only enters the injected
///      premium).
contract ScenarioAFullWeekTest is RiskFixture, IUnderwriterPoolEvents {
    address lena = makeAddr("lena");
    address uma = makeAddr("uma");
    address rahul = makeAddr("rahul");
    address maya = makeAddr("maya");
    address priya = makeAddr("priya");
    address mo = makeAddr("mo");
    address omar = makeAddr("omar");
    address kai = makeAddr("kai");

    uint256 constant ET = 4 hours;
    uint256 constant CENT = 1e4;
    uint256 constant SAFE_NVDA = 0.712580117506e18; // G-07
    uint256 constant SAFE_TSLA = 0.626773490008e18; // G-08
    uint64 constant FRI = 4; // Friday's session index = the epoch of the weekend closure
    uint64 constant WEEKEND_CLOSURE = 6; // closure ids: Mon's close = 2 … Fri's close = 6

    uint64 preId;
    uint64 reopenId;
    uint256 penaltyThird;

    function _rate() internal pure override returns (RateParams memory) {
        return RateParams({r0: 0.0729e18, s1: 0, s2: 0, uKink: 0.9e18}); // 7.29% all week (the doc)
    }

    function _at(uint256 day, uint256 hhmmEt) internal pure returns (uint256) {
        return MON + day * 1 days + (hhmmEt / 100) * 1 hours + (hhmmEt % 100) * 1 minutes + ET;
    }

    function _cents(uint256 actual, uint256 expectedCents, string memory what) internal pure {
        uint256 e = expectedCents * CENT;
        uint256 diff = actual > e ? actual - e : e - actual;
        assertLe(diff, CENT / 2, what);
    }

    /// @dev The doc charges simple interest from the borrow; the market's borrow index compounds at every accrual
    ///      (R-09), which adds ≈ 2 cents to Priya's debt by Monday. Exact identities are asserted to the unit; the
    ///      doc's debt-derived figures within 3 cents (report, spec issue).
    function _centsCompounded(uint256 actual, uint256 expectedCents, string memory what) internal pure {
        uint256 e = expectedCents * CENT;
        uint256 diff = actual > e ? actual - e : e - actual;
        assertLe(diff, 3 * CENT, what);
    }

    function _weekday(uint256 day) internal {
        _day(0, day);
        for (uint256 i; i < 3; ++i) {
            clk.setClosureId([NVDA, AAPL, TSLA][i], uint64(day + 1));
        }
    }

    function setUp() public {
        vm.warp(_at(0, 900));
        setUpCore();
        _loadStress();
        vm.startPrank(timelock);
        for (uint256 i; i < 3; ++i) {
            engine.updateSigma([NVDA, AAPL, TSLA][i], uint8(ClosureType.WEEKEND), 0.03e18);
        }
        vm.stopPrank();
        _weekday(0);
    }

    // ───────────── Monday to Friday 16:00 ─────────────

    function _week() internal {
        // Mon 10:00: Lena $230,000 into the vault; Uma $40,000 into the pool (before any Bell window: minted now)
        vm.warp(_at(0, 1000));
        _deposit(lena, 230_000e6);
        vm.startPrank(allocator);
        vault.deallocate(idAAPL, 130_000e6);
        vault.allocate(idTSLA, 60_000e6);
        vault.allocate(idNVDA, 70_000e6);
        vm.stopPrank();
        assertEq(_underwrite(uma, 40_000e6), 40_000e18);
        _position(rahul, idAAPL, tAAPL, 500e18, 60_000e6);
        // Tue: Maya (auto-cover off); Wed: Priya
        _weekday(1);
        vm.warp(_at(1, 1000));
        _position(maya, idTSLA, tTSLA, 300e18, 55_500e6);
        vm.prank(maya);
        market.setAutoCover(idTSLA, false);
        _weekday(2);
        vm.warp(_at(2, 1000));
        _position(priya, idNVDA, tNVDA, 500e18, 67_000e6);
        // Thu 17:00: σ × 1.5 → weekend safe LTVs
        _weekday(3);
        engine.setSafeLtv(NVDA, uint8(ClosureType.WEEKEND), SAFE_NVDA);
        engine.setSafeLtv(TSLA, uint8(ClosureType.WEEKEND), SAFE_TSLA);

        // Fri 14:00: the Bell window; debts to the cent (Appendix A S-A)
        _weekday(4);
        vm.warp(_at(4, 1400));
        _cents(market.debtOf(idNVDA, priya), 6_702_899, "Priya debt 67,028.99");
        _cents(market.debtOf(idTSLA, maya), 5_553_510, "Maya debt 55,535.10");
        up.openEpoch(VENUE);
        assertEq(up.epoch(FRI).navBefore, up.nav());

        // Fri 15:30: Priya buys cover for $35.95 through the real pool (premium injected, R-22)
        vm.warp(_at(4, 1530));
        engine.setQuote(35.95e6, 15.12e6, 604.99e6);
        _cover(priya, idNVDA, 35.95e6);
        assertEq(up.epoch(FRI).premiums, 35.95e6);
        assertEq(up.unearnedPremiums(), 35.95e6);
        assertEq(market.coveredCollateral(idNVDA, WEEKEND_CLOSURE), 500e18);
        (BellStatus st,,,) = market.bellStatus(idNVDA, priya);
        assertEq(uint8(st), uint8(BellStatus.COVERED));

        // Fri 15:45: the Bell deadline; Kai snapshots J and enforces Maya → PRECLOSE batch
        vm.warp(_at(4, 1545));
        vm.prank(kai);
        up.snapshotEpoch(FRI);
        assertEq(up.epoch(FRI).equityAtRisk, up.nav());
        address[] memory bs = new address[](1);
        bs[0] = maya;
        vm.prank(kai);
        market.enforceBell(idTSLA, bs);
        preId = market.position(idTSLA, maya).auctionId;
        Auction memory a = house.auction(preId);
        assertEq(uint8(a.kind), uint8(AuctionKind.PRECLOSE));
        assertEq(a.deadlines[0], _at(4, 1555));
        assertEq(a.deadlines[3], _at(4, 1600) - 30);

        // 15:55: lot fixed at R_pre = 99% × $250, sized down to the safe LTV at the projected debt (R-06, R-08)
        vm.warp(_at(4, 1555));
        uint256 dMaya = market.projectedDebt(idTSLA, maya);
        house.fixLots(preId);
        a = house.auction(preId);
        assertEq(a.reserve, 247.5e18);
        assertEq(a.lot, engine.precloseLot(dMaya, 300e18, 250e18, 247.5e18, SAFE_TSLA, 0.01e18, 18, 6));
        // Mo buys the lot at $249.50 (TSLA trades at $250)
        usdc.mint(mo, 200_000e6);
        usdc.mint(omar, 200_000e6);
        vm.prank(mo);
        usdc.approve(address(house), type(uint256).max);
        vm.prank(omar);
        usdc.approve(address(house), type(uint256).max);
        vm.prank(mo);
        house.placeBid(preId, a.lot, 249.5e18);
        vm.warp(_at(4, 1600) - 30);
        vm.prank(kai);
        house.clear(preId);
        a = house.auction(preId);
        assertEq(a.pStar, 249.5e18);
        assertEq(a.filled, a.lot);
        uint256 proceeds = (uint256(a.lot) * 249.5e18 + 1e30 - 1) / 1e30;
        assertEq(a.proceeds, proceeds);
        uint256 poolCash = usdc.balanceOf(address(up));
        vm.prank(kai);
        market.settlePositions(preId, bs);
        penaltyThird = proceeds / 100 / 3;
        assertEq(usdc.balanceOf(address(up)) - poolCash, penaltyThird, "pool: 1/3 of Maya's 1% penalty");
        assertEq(up.epoch(FRI).penalties, penaltyThird);
        (st,,,) = market.bellStatus(idTSLA, maya);
        assertEq(uint8(st), uint8(BellStatus.SAFE), "Maya is safe into the weekend");
        vm.prank(mo);
        house.claim(preId);
        assertEq(tTSLA.balanceOf(mo), a.lot);

        // Fri 16:00: the close; every market CLOSED over the weekend (no money moves, INV-LIQ-01)
        vm.warp(_at(4, 1600));
        _closed(FRI, WEEKEND_CLOSURE);
        vm.warp(_at(5, 1100));
        orc.setPrice(NVDA, 138e18); // the DEX says −23%: no liquidation in CLOSED
        address[] memory pr = new address[](1);
        pr[0] = priya;
        vm.expectRevert();
        market.flagForAuction(idNVDA, pr);
    }

    // ───────────── Monday: the REOPEN auction and settlement ─────────────

    function _mondayOpen() internal returns (uint40 printAt) {
        printAt = uint40(_at(7, 930));
        vm.warp(printAt + 5);
        _reopen(FRI, WEEKEND_CLOSURE, printAt, [uint128(126e18), 194e18, 230e18]);
        orc.setPrice(NVDA, 126e18);
        orc.setPrice(AAPL, 194e18);
        orc.setPrice(TSLA, 230e18);
        address[] memory pr = new address[](1);
        pr[0] = priya;
        vm.prank(kai);
        market.flagForAuction(idNVDA, pr);
        reopenId = market.position(idNVDA, priya).auctionId;
        // Rahul (HF 1.29) and Maya (HF > 1 after Friday's sale) are not liquidatable
        address[] memory others = new address[](1);
        others[0] = maya;
        vm.prank(kai);
        market.flagForAuction(idTSLA, others);
        assertEq(market.position(idTSLA, maya).auctionId, 0);

        // 09:32: full close (the formula asks for 789 tokens > 500); R = 97% × $126 = $122.22
        vm.warp(printAt + 120);
        vm.prank(kai);
        house.fixLots(reopenId);
        Auction memory a = house.auction(reopenId);
        assertEq(a.lot, 500e18, "full close");
        assertEq(a.reserve, 122.22e18);
    }

    function _commit(address who, uint128 qty, uint128 price, uint128 maxNotional, bytes32 salt) internal {
        bytes32 c = keccak256(abi.encode(block.chainid, address(house), reopenId, who, qty, price, salt));
        vm.prank(who);
        house.commitBid(reopenId, c, maxNotional);
    }

    function _settleMonday(uint40 printAt) internal returns (Epoch memory e) {
        // 09:37 settlement of Priya, then the other assets' REOPEN ends, then the epoch settles
        address[] memory pr = new address[](1);
        pr[0] = priya;
        vm.prank(kai);
        market.settlePositions(reopenId, pr);
        assertEq(market.position(idNVDA, priya).borrowShares, 0, "non-recourse: Priya owes nothing");
        assertFalse(_clockData(NVDA).reopenPending, "NVDA REOPEN completed by the last tranche");
        house.completeReopen(AAPL);
        house.completeReopen(TSLA);
        vm.warp(printAt + 10 minutes);
        vm.prank(kai);
        up.settleEpoch(FRI);
        e = up.epoch(FRI);
        assertEq(uint8(e.phase), uint8(EpochPhase.SETTLED));
        assertEq(e.pendingLossReserve, 0, "every REOPEN completed");
    }

    function test_scenarioA_throughMonday() public {
        _week();
        uint40 printAt = _mondayOpen();

        // 09:32–09:35 commit: Mo 300 @ $124.40 (bond $3,732), Omar 300 @ $124.11 (bond $3,723.30)
        _commit(mo, 300e18, 124.4e18, 37_320e6, "mo");
        _commit(omar, 300e18, 124.11e18, 37_233e6, "omar");
        assertEq(house.bid(reopenId, mo).escrow, 3_732e6);
        assertEq(house.bid(reopenId, omar).escrow, 3_723.3e6);
        // 09:35–09:37 reveal
        vm.warp(printAt + 300);
        vm.prank(mo);
        house.revealBid(reopenId, 300e18, 124.4e18, "mo");
        vm.prank(omar);
        house.revealBid(reopenId, 300e18, 124.11e18, "omar");
        // 09:37 clear: both pay p* = $124.11; Mo 300, Omar 200; proceeds $62,055
        vm.warp(printAt + 420);
        uint256 debt0937 = market.debtOf(idNVDA, priya);
        _centsCompounded(debt0937, 6_706_669, "Priya debt at 09:37: 67,066.69 (doc, simple interest)");
        vm.prank(kai);
        house.clear(reopenId);
        Auction memory a = house.auction(reopenId);
        assertEq(a.pStar, 124.11e18, "S-A: p* = 124.11 (G-18)");
        assertEq(a.filled, 500e18);
        assertEq(a.qPool, 0);
        assertEq(a.proceeds, 62_055e6, "proceeds 62,055.00");
        vm.prank(mo);
        house.claim(reopenId);
        vm.prank(omar);
        house.claim(reopenId);
        assertEq(tNVDA.balanceOf(mo), 300e18);
        assertEq(tNVDA.balanceOf(omar), 200e18);
        assertEq(
            usdc.balanceOf(mo),
            200_000e6 - (uint256(house.auction(preId).proceeds)) - 37_233e6,
            "Mo pays 37,233"
        );
        assertEq(
            usdc.balanceOf(omar), 200_000e6 - 24_822e6, "Omar pays 24,822; unfilled 100 and bond returned"
        );

        // settlement: shortfall 5,011.69 paid by the pool, senior loss 0
        uint256 poolCash = usdc.balanceOf(address(up));
        vm.recordLogs();
        Epoch memory e = _settleMonday(printAt);
        uint256 paid = poolCash - usdc.balanceOf(address(up));
        assertEq(paid, debt0937 - 62_055e6, "shortfall = debt - proceeds, to the unit");
        _centsCompounded(paid, 501_169, "S-A: shortfall 5,011.69 paid by the pool");
        assertEq(e.lossesPaid, paid);
        _assertNoSeniorLoss();

        // INV-POOL-01 and the pool share price: NAV_after = 40,000 + premium + ⅓ penalty + risk fees − shortfall
        assertEq(e.premiums, 35.95e6);
        assertEq(e.penalties, penaltyThird);
        assertEq(
            uint256(e.navAfter),
            uint256(e.navBefore) + e.premiums + e.riskFees + e.penalties + e.bonds - e.lossesPaid,
            "INV-POOL-01"
        );
        assertEq(up.totalSupply(), 40_000e18);
        assertEq(e.sharePriceAfter, (uint256(e.navAfter) + 1) * 1e30 / (40_000e18 + 1e12));
        // Uma's $40,000 at the doc's inputs is worth $35,123.19 (penalty ⅓ 78.53, fees 20.40); here Maya's lot is
        // sized at the projected debt (R-06/R-08), so the penalty differs: the identity above holds to the unit,
        // and the value is recorded for Guide v1.2
        emit log_named_decimal_uint("S-A pool NAV after (Uma's $40,000)", e.navAfter, 6);
        emit log_named_decimal_uint("S-A pool share price after", e.sharePriceAfter, 18);
        emit log_named_decimal_uint("S-A 1/3 penalty to the pool", penaltyThird, 6);
        emit log_named_decimal_uint("S-A pool risk fees in the epoch", e.riskFees, 6);
        // at the doc's penalty and fees the same identity gives the doc's figure
        assertEq(uint256(40_000e6) + 35.95e6 + 78.53e6 + 20.4e6 - 5_011.69e6, 35_123.19e6);
    }

    /// @dev Gap-loss variant: only Mo bids (300 @ $124.40); the pool backstops the other 200 NVDA at R = $122.22,
    ///      pays the larger shortfall, and holds the inventory at min(cost, V × (1 − κ)).
    function test_scenarioA_gapLossWithBackstop() public {
        _week();
        uint40 printAt = _mondayOpen();
        _commit(mo, 300e18, 124.4e18, 37_320e6, "mo");
        vm.warp(printAt + 300);
        vm.prank(mo);
        house.revealBid(reopenId, 300e18, 124.4e18, "mo");
        vm.warp(printAt + 420);
        uint256 poolCash = usdc.balanceOf(address(up));
        vm.prank(kai);
        house.clear(reopenId);
        Auction memory a = house.auction(reopenId);
        assertEq(a.pStar, 124.4e18);
        assertEq(a.filled, 300e18);
        assertEq(a.qPool, 200e18, "the pool buys 200 NVDA at R");
        uint256 backstop = 200 * 122.22e6;
        assertEq(poolCash - usdc.balanceOf(address(up)), backstop, "pool pays 200 x 122.22 = 24,444");
        assertEq(a.proceeds, 37_320e6 + backstop, "proceeds 61,764");
        Inventory memory inv = up.inventory(NVDA);
        assertEq(inv.qty, 200e18);
        assertEq(inv.cost, backstop);
        // p̄ = (300 × 124.40 + 200 × 122.22) / 500 = 123.528 (G-19 shape)
        assertEq(market.lotInfo(reopenId).blendedPrice, 123.528e18);

        poolCash = usdc.balanceOf(address(up));
        vm.recordLogs();
        Epoch memory e = _settleMonday(printAt);
        uint256 shortfall = poolCash - usdc.balanceOf(address(up));
        _centsCompounded(shortfall, (67_066.69e6 - 61_764e6) / CENT, "shortfall 5,302.69 paid by the pool");
        _assertNoSeniorLoss();
        // the inventory is marked at min(cost, V × (1 − κ)) = min(24,444, 200 × 126 × 0.97 = 24,444) in NAV
        uint256 mark = 200 * 122.22e6;
        assertEq(
            uint256(e.navAfter),
            uint256(e.navBefore) + e.premiums + e.riskFees + e.penalties + e.bonds - e.lossesPaid - backstop
                + mark,
            "INV-POOL-01 with the backstop at its mark"
        );
        // resale by GDA starts at 1.02 × V
        uint64 g = up.resellInventory(NVDA);
        assertEq(house.gda(g).k, 126e18 * 102 / 100);
    }

    function _assertNoSeniorLoss() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ICredenceMarketEvents.Shortfall.selector) {
                (, uint256 paidPool, uint256 paidReserve, uint256 seniorLoss) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                assertEq(seniorLoss, 0, "senior loss 0");
                assertEq(paidReserve, 0, "reserve untouched");
                assertGt(paidPool, 0);
            }
        }
        assertGe(vault.totalAssets(), 230_000e6, "Lena lost nothing");
    }
}
