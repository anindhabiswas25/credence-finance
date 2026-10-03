// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {
    RateParams,
    ClockState,
    ClosureType,
    Auction,
    AuctionKind,
    Epoch,
    EpochPhase,
    Inventory
} from "../../src/libraries/Types.sol";
import {ICredenceMarketEvents} from "../../src/libraries/Events.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Scenario B ("One week of money flow", Appendix A S-B), the whole week, on the real market, UnderwriterPool
///         and AuctionHouse with the doc's premiums injected (R-22): Thursday's INTRADAY liquidation of Ben, Friday's
///         Bell (Priya's cover, the others' $280, Dev's auto-cover), the weekend, Monday's REOPEN auctions (Priya's
///         partial, Dev's full close with Aria's 60 COIN, the pool's 40-COIN backstop, Zed's forfeited bond), the
///         shortfall, the epoch settlement and Sara's withdrawal.
/// @dev Figures are asserted to the cent where the doc's inputs are exact, and as chain identities (to the unit) where
///      R-06 / R-08 / R-09 / R-10 move a cent; every difference is explained at its assertion and in the S4 report §4.
///      The 7.33 % rate is held flat all week (the doc). US/Eastern = UTC − 4 h. Week: Mon 2026-10-05 … Mon 2026-10-12.
contract ScenarioBWeekTest is RiskFixture {
    // the cast
    address lena = makeAddr("lena");
    address earlier = makeAddr("earlierLenders");
    address uwEarlier = makeAddr("earlierUnderwriters");
    address sara = makeAddr("sara");
    address umar = makeAddr("umar");
    address priya = makeAddr("priya");
    address dev = makeAddr("dev");
    address ben = makeAddr("ben");
    address rahul = makeAddr("rahul");
    address others = makeAddr("otherBorrowers");
    address otherCovered = makeAddr("otherCoveredBorrowers");
    address aria = makeAddr("aria");
    address zed = makeAddr("zed");
    address kai = makeAddr("kai");

    bytes32 constant COIN = keccak256("COIN:XNAS");
    bytes32 constant SPY = keccak256("SPY:ARCX");
    MockERC20 tCOIN;
    MockERC20 tSPY;
    bytes32 idCOIN;
    bytes32 idSPY;

    uint256 constant ET = 4 hours;
    uint256 constant CENT = 1e4;
    uint256 constant SAFE_WEEKEND = 0.712580117506e18; // G-07, σ 4.5 %: "71.3 %"
    uint64 constant FRI = 4; // Friday's session index = the weekend epoch
    uint64 constant WEEKEND_CLOSURE = 6;

    uint64 thuId;
    uint64 nvdaId;
    uint64 coinId;
    bool umarOnMonday; // variant: Umar deposits with the earlier underwriters, before any fee accrues

    function _rate() internal pure override returns (RateParams memory) {
        return RateParams({r0: 0.0733e18, s1: 0, s2: 0, uKink: 0.9e18}); // 7.33 % all week (the doc)
    }

    function _at(uint256 day, uint256 hhmmEt) internal pure returns (uint256) {
        return MON + day * 1 days + (hhmmEt / 100) * 1 hours + (hhmmEt % 100) * 1 minutes + ET;
    }

    function _assets() internal pure returns (bytes32[5] memory) {
        return [NVDA, AAPL, TSLA, COIN, SPY];
    }

    /// @dev |actual − doc| ≤ tolerance (in cents; 0 = to the half cent).
    function _cents(uint256 actual, uint256 docCents, uint256 tolCents, string memory what) internal pure {
        uint256 e = docCents * CENT;
        uint256 diff = actual > e ? actual - e : e - actual;
        assertLe(diff, tolCents == 0 ? CENT / 2 : tolCents * CENT, what);
    }

    /// @dev Every asset REGULAR in weekday `d`'s session: next close that day 16:00 ET (WEEKEND on Friday), the cover
    ///      epoch = the session index, closure ids Mon's close = 1 … Fri's close = 5 → the weekend closure is 6.
    function _weekday(uint256 d) internal {
        bool fri = d == 4;
        for (uint256 i; i < 5; ++i) {
            bytes32 a = _assets()[i];
            clk.setState(a, ClockState.REGULAR);
            clk.setNextClose(
                a, _closeAt(0, d), fri ? ClosureType.WEEKEND : ClosureType.OVERNIGHT, fri ? 3 : 1
            );
            clk.setCursor(a, uint32(_session(0, d)));
            clk.setClosureId(a, uint64(d + 1));
        }
    }

    function _listExtra() internal {
        tCOIN = new MockERC20("Credence Test Coinbase", "tCOIN", 18);
        tSPY = new MockERC20("Credence Test S&P 500", "tSPY", 18);
        idCOIN = _list(address(tCOIN), COIN);
        idSPY = _list(address(tSPY), SPY);
        vm.startPrank(timelock);
        vault.setCap(idCOIN, 2_000_000e6);
        vault.setCap(idSPY, 2_000_000e6);
        uint256[] memory col = new uint256[](16);
        for (uint256 j; j < 256; ++j) {
            int16 z = int16(int256(-8000) + int256(j) * 40);
            col[j / 16] |= uint256(uint16(z)) << (16 * (j % 16));
        }
        for (uint256 i; i < 5; ++i) {
            bytes32 a = _assets()[i];
            if (a == COIN || a == SPY) engine.setJointColumn(a, col);
            for (uint8 t = 1; t <= 3; ++t) {
                engine.updateSigma(a, t, 0.03e18); // σ 3 %: the doc's $100,000 pool has room for the week's covers
            }
        }
        vm.stopPrank();
        bytes32[] memory q = new bytes32[](5);
        (q[0], q[1], q[2], q[3], q[4]) = (idAAPL, idTSLA, idNVDA, idCOIN, idSPY);
        vm.startPrank(allocator);
        vault.setSupplyQueue(q);
        vault.setWithdrawQueue(q);
        vm.stopPrank();
    }

    function setUp() public {
        vm.warp(_at(0, 900));
        setUpCore();
        _loadStress();
        _listExtra();
        _weekday(0);
        orc.setPrice(NVDA, 180e18);
        orc.setPrice(AAPL, 200e18);
        orc.setPrice(TSLA, 400e18);
        orc.setPrice(COIN, 300e18);
        orc.setPrice(SPY, 600e18);
        for (uint8 j; j <= 7; ++j) {
            vm.prank(timelock);
            tips.setTip(j, 2e6); // Kai's $2 tips
        }
    }

    /// @dev A loan at exactly max LTV rounds its debt up past the limit, so it is posted with the price 1 cent higher
    ///      (the doc's 75.00 % loans are pre-existing positions).
    function _loanAtMax(
        address b,
        bytes32 id,
        bytes32 asset,
        MockERC20 t,
        uint256 q,
        uint256 debt,
        uint256 px
    ) internal {
        orc.setPrice(asset, px + 0.01e18);
        _position(b, id, t, q, debt);
        orc.setPrice(asset, px);
    }

    // ───────────── Monday to Thursday ─────────────

    function _monToThu() internal {
        // Mon 09:30: the protocol accounts (§1): vault $800,000 + Lena $200,000; pool $80,000 (Sara 10,000 shares)
        vm.warp(_at(0, 930));
        _deposit(earlier, 800_000e6);
        _deposit(lena, 200_000e6);
        assertEq(vault.totalAssets(), 1_000_000e6, "the vault holds $1,000,000");
        vm.startPrank(allocator);
        vault.deallocate(idAAPL, 350_000e6);
        vault.allocate(idNVDA, 20_000e6);
        vault.allocate(idTSLA, 20_000e6);
        vault.allocate(idCOIN, 30_000e6);
        vault.allocate(idSPY, 280_000e6);
        vm.stopPrank();
        assertEq(_underwrite(uwEarlier, 70_000e6), 70_000e18);
        assertEq(_underwrite(sara, 10_000e6), 10_000e18);
        if (umarOnMonday) assertEq(_underwrite(umar, 20_000e6), 20_000e18);
        // the book at 09:30: Dev $22,500 (75 %), Ben $14,800 (74 %), Rahul $150,000 (50 %), others $599,200
        _loanAtMax(dev, idCOIN, COIN, tCOIN, 100e18, 22_500e6, 300e18);
        _position(ben, idTSLA, tTSLA, 50e18, 14_800e6);
        _position(rahul, idSPY, tSPY, 500e18, 150_000e6);
        _position(others, idAAPL, tAAPL, 5_892e18, 589_200e6);
        _loanAtMax(otherCovered, idAAPL, AAPL, tAAPL, 66_666_666_666_666_666_667, 10_000e6, 200e18);
        // Mon 10:00: Priya posts 100 NVDA ($18,000) and borrows $13,500 (75 %)
        vm.warp(_at(0, 1000));
        _loanAtMax(priya, idNVDA, NVDA, tNVDA, 100e18, 13_500e6, 180e18);

        // Wed: Umar deposits $20,000 (no epoch open: minted now, at the NAV with the risk fee accrued since Monday)
        _weekday(2);
        vm.warp(_at(2, 1100));
        if (!umarOnMonday) {
            uint256 umarShares = _underwrite(umar, 20_000e6);
            assertLt(
                umarShares,
                20_000e18,
                "R-09: the fee receivable since Monday belongs to the earlier underwriters"
            );
        }

        // Thu 13:00: TSLA −9 % to $364; Ben's debt 14,809.35, HF 0.98 → Kai flags; INTRADAY lot of 20.23 TSLA
        _weekday(3);
        vm.warp(_at(3, 1300));
        orc.setPrice(TSLA, 364e18);
        _cents(market.debtOf(idTSLA, ben), 1_480_935, 0, "S-B: Ben's debt 14,809.35");
        address[] memory bs = new address[](1);
        bs[0] = ben;
        vm.prank(kai);
        market.flagForAuction(idTSLA, bs);
        thuId = market.position(idTSLA, ben).auctionId;
        assertEq(uint8(house.auction(thuId).kind), uint8(AuctionKind.INTRADAY));
        vm.warp(block.timestamp + 15);
        vm.prank(kai);
        house.fixLots(thuId);
        Auction memory a = house.auction(thuId);
        assertEq(a.reserve, 353.08e18, "R = 97 % x $364");
        assertApproxEqAbs(a.lot, 20.2286e18, 0.0001e18, "S-B: lot 20.23 TSLA (G-13: 20.2286)");
        // Aria bids the lot at $362.18 (99.5 % of the live price); clears at +60 s
        usdc.mint(aria, 100_000e6);
        vm.prank(aria);
        usdc.approve(address(house), type(uint256).max);
        vm.prank(aria);
        house.placeBid(thuId, a.lot, 362.18e18);
        vm.warp(a.deadlines[3]);
        vm.prank(kai);
        house.clear(thuId);
        a = house.auction(thuId);
        assertEq(a.pStar, 362.18e18);
        assertEq(a.qPool, 0);
        // the doc rounds the lot to 20.2287 (7,326.43); F-4.5a at the doc's debt gives 20.22863, so the chain's
        // proceeds are ≈ 1.6 cents lower. Identity to the unit, doc within 3 cents (Appendix A rule for rounded lots).
        assertEq(
            a.proceeds, (uint256(a.lot) * 362.18e18 + 1e30 - 1) / 1e30, "proceeds = lot x p*, to the unit"
        );
        _cents(a.proceeds, 732_643, 3, "S-B: Aria pays 7,326.43");
        // settlement: 3 % penalty 219.79 split 73.26 x 3; 7,106.64 repays Ben; he owes 7,702.72
        uint256 poolCash = usdc.balanceOf(address(up));
        uint256 resBal = usdc.balanceOf(address(reserve));
        uint256 debtBefore = market.debtOf(idTSLA, ben);
        vm.prank(kai);
        market.settlePositions(thuId, bs);
        uint256 penalty = uint256(a.proceeds) * 3 / 100;
        _cents(penalty, 21_979, 1, "S-B: Ben's penalty 219.79");
        _cents(usdc.balanceOf(address(up)) - poolCash, 7_326, 0, "S-B: 73.26 to the pool");
        _cents(usdc.balanceOf(address(reserve)) - resBal, 7_326, 0, "S-B: 73.26 to the reserve");
        _cents(a.proceeds - penalty, 710_664, 3, "S-B: 7,106.64 repays Ben (the lot's 1.6 cents)");
        assertApproxEqAbs(market.debtOf(idTSLA, ben), debtBefore - (a.proceeds - penalty), 1);
        _cents(market.debtOf(idTSLA, ben), 770_272, 3, "S-B: Ben owes 7,702.72 (the lot's 1.6 cents)");
        assertEq(market.position(idTSLA, ben).collateral / 1e16, 2_977, "Ben keeps 29.77 TSLA");
        assertEq((market.healthFactor(idTSLA, ben) + 0.005e18) / 0.01e18, 113, "HF 1.13 (2 decimals)");
        vm.prank(aria);
        house.claim(thuId);
    }

    // ───────────── Friday: the Bell ─────────────

    function _friday() internal {
        _weekday(4);
        for (uint256 i; i < 5; ++i) {
            engine.setSafeLtv(_assets()[i], uint8(ClosureType.WEEKEND), SAFE_WEEKEND);
        }
        // Fri 13:00, before the Bell window: Sara requests her withdrawal (R-10: every weeknight is an epoch, so a
        // Wednesday request would be paid after Wednesday night's; the doc shows one epoch for readability)
        vm.warp(_at(4, 1300));
        vm.prank(sara);
        assertEq(up.requestWithdraw(10_000e18), FRI);

        // 14:00 the Bell window
        vm.warp(_at(4, 1400));
        vm.prank(kai);
        up.openEpoch(VENUE);
        // 14:20 Priya buys cover for $6.53; the other borrowers above the line buy $280.00
        vm.warp(_at(4, 1420));
        engine.setQuote(6.53e6, 0, 0);
        _cover(priya, idNVDA, 6.53e6);
        engine.setQuote(280e6, 0, 0);
        _cover(otherCovered, idAAPL, 280e6);
        // 15:45 the Bell deadline: Kai snapshots J and enforces Dev (still above 71.3 %) → auto-cover $10.89
        vm.warp(_at(4, 1545));
        vm.prank(kai);
        up.snapshotEpoch(FRI);
        engine.setQuote(10.89e6, 0, 0);
        address[] memory bs = new address[](1);
        bs[0] = dev;
        vm.prank(kai);
        market.enforceBell(idCOIN, bs);
        assertEq(market.position(idCOIN, dev).coverClosureId, WEEKEND_CLOSURE, "Dev auto-covered");
        _cents(market.debtOf(idCOIN, dev), 2_253_019, 5, "S-B: Dev's debt with the premium 22,530.19");
        assertEq(up.epoch(FRI).premiums, 297.42e6, "S-B: premiums 297.42 for the epoch");

        // 16:00 the close; the weekend: nothing can be liquidated (COIN's DEX −14 %, NVDA −8 %)
        vm.warp(_at(4, 1600));
        for (uint256 i; i < 5; ++i) {
            clk.setState(_assets()[i], ClockState.CLOSED);
            clk.setReopen(_assets()[i], WEEKEND_CLOSURE, FRI, true);
        }
        vm.warp(_at(5, 1100));
        orc.setPrice(COIN, 258e18);
        orc.setPrice(NVDA, 165.6e18);
        vm.expectRevert();
        market.flagForAuction(idCOIN, bs);
    }

    // ───────────── Monday: the reopen ─────────────

    function _commit(address who, uint64 id, uint128 qty, uint128 price, uint128 maxNotional, bytes32 salt)
        internal
    {
        bytes32 c = keccak256(abi.encode(block.chainid, address(house), id, who, qty, price, salt));
        vm.prank(who);
        house.commitBid(id, c, maxNotional);
    }

    /// @dev The same week with Umar's $20,000 deposited Monday 09:30 (the doc's 100,000 shares at $1.00): share price
    ///      0.9998823 and Sara's 9,998.82 come out to the doc's figures, which isolates Umar's Wednesday mint (R-09) as
    ///      the whole difference in the main test.
    function test_scenarioB_withTheDocsShareCount() public {
        umarOnMonday = true;
        test_scenarioB_wholeWeek();
    }

    function test_scenarioB_wholeWeek() public {
        _monToThu();
        _friday();

        // Mon 09:30: open prints NVDA $158.40 (−12 %), COIN $225.00 (−25 %); TSLA, SPY, AAPL within 1.5 %
        uint40 printAt = uint40(_at(7, 930));
        vm.warp(printAt + 5);
        uint128[5] memory prints = [uint128(158.4e18), 200e18, 364e18, 225e18, 600e18];
        for (uint256 i; i < 5; ++i) {
            clk.setState(_assets()[i], ClockState.REOPEN);
            clk.setOpenPrint(_assets()[i], prints[i], printAt);
            orc.setPrice(_assets()[i], prints[i]);
        }
        _cents(
            market.debtOf(idNVDA, priya),
            1_351_902,
            50,
            "S-B: Priya's debt 13,519.02 (doc: +7.016 days; +-$0.50)"
        );
        // the doc's Monday debts carry ≈ 7.016 days of interest (to ≈ 09:52), the chain reads them at 09:30
        _cents(market.debtOf(idCOIN, dev), 2_254_259, 6, "S-B: Dev's debt 22,542.59 (doc +22 min)");
        address[] memory pr = new address[](1);
        pr[0] = priya;
        address[] memory dv = new address[](1);
        dv[0] = dev;
        vm.startPrank(kai);
        market.flagForAuction(idNVDA, pr);
        market.flagForAuction(idCOIN, dv);
        vm.stopPrank();
        nvdaId = market.position(idNVDA, priya).auctionId;
        coinId = market.position(idCOIN, dev).auctionId;

        // 09:32 lots fixed: 59.08 NVDA (R $153.65), 100 COIN (the formula asks 128.6 > 100: full close, R $218.25)
        vm.warp(printAt + 120);
        vm.startPrank(kai);
        house.fixLots(nvdaId);
        house.fixLots(coinId);
        vm.stopPrank();
        Auction memory an = house.auction(nvdaId);
        Auction memory ac = house.auction(coinId);
        assertEq(an.reserve, 153.648e18);
        assertEq(ac.reserve, 218.25e18);
        assertEq(ac.lot, 100e18, "Dev: full close");
        assertApproxEqAbs(
            an.lot, 59.0752e18, 0.02e18, "S-B: lot 59.08 NVDA (G-14: 59.0752 at the doc's debt)"
        );

        // 09:32–09:35 commits: Aria on both lots; Zed on COIN with an $86 bond (maxNotional $860)
        usdc.mint(aria, 50_000e6);
        usdc.mint(zed, 86e6);
        vm.prank(zed);
        usdc.approve(address(house), type(uint256).max);
        _commit(aria, nvdaId, an.lot, 156.024e18, 10_000e6, "a-nvda");
        _commit(aria, coinId, 60e18, 219e18, 14_000e6, "a-coin");
        _commit(zed, coinId, 40e18, 220e18, 860e6, "z");
        assertEq(house.bid(coinId, zed).escrow, 86e6, "Zed's bond: $86");
        // 09:35–09:37 Aria reveals and escrows; Zed never reveals
        vm.warp(printAt + 300);
        vm.startPrank(aria);
        house.revealBid(nvdaId, an.lot, 156.024e18, "a-nvda");
        house.revealBid(coinId, 60e18, 219e18, "a-coin");
        vm.stopPrank();
        uint256 ariaEscrow = house.bid(nvdaId, aria).escrow + house.bid(coinId, aria).escrow;
        _cents(ariaEscrow, 2_235_715, 50, "S-B: Aria escrows 22,357.15 (+-$0.50 with the lot)");

        // 09:37 clear: NVDA all to Aria at $156.02; COIN 60 to Aria at $219.00, the pool 40 at $218.25; Zed's bond → pool
        vm.warp(printAt + 420);
        uint256 poolCash = usdc.balanceOf(address(up));
        vm.startPrank(kai);
        house.clear(nvdaId);
        house.clear(coinId);
        vm.stopPrank();
        an = house.auction(nvdaId);
        ac = house.auction(coinId);
        assertEq(an.pStar, 156.024e18);
        assertEq(an.filled, an.lot);
        assertEq(ac.pStar, 219e18);
        assertEq(ac.filled, 60e18);
        assertEq(ac.qPool, 40e18, "S-B: the pool backstops 40 COIN");
        assertEq(
            poolCash + 86e6 - usdc.balanceOf(address(up)),
            8_730e6,
            "S-B: the pool pays 8,730.00 (40 x 218.25)"
        );
        assertEq(up.epoch(FRI).bonds, 86e6, "S-B: Zed's 86 to the pool");
        assertEq(ac.proceeds, 21_870e6, "S-B: Dev's proceeds 13,140.00 + 8,730.00 = 21,870.00");
        _cents(an.proceeds, 921_715, 50, "S-B: Priya's proceeds 9,217.15 (+-$0.50 with the lot)");
        // cash in = cash out: Aria + pool = debt repaid + penalty (checked after settlement)
        uint256 cashIn = an.proceeds + ac.proceeds; // Aria's fills + the pool's backstop
        assertEq(cashIn, uint256(house.bid(nvdaId, aria).escrow) + 13_140e6 + 8_730e6);
        _cents(cashIn, 3_108_715, 50, "S-B: cash in 31,087.15");

        // settlement: Priya partial (penalty 276.51, 92.17 each), Dev short 672.59 → pool; senior made whole
        uint256 dPriya = market.debtOf(idNVDA, priya);
        uint256 dDev = market.debtOf(idCOIN, dev);
        poolCash = usdc.balanceOf(address(up));
        uint256 seniorBefore =
            market.marketState(idNVDA).totalSupplyAssets + market.marketState(idCOIN).totalSupplyAssets;
        vm.recordLogs();
        vm.startPrank(kai);
        market.settlePositions(nvdaId, pr);
        market.settlePositions(coinId, dv);
        vm.stopPrank();
        uint256 penaltyP = uint256(an.proceeds) * 3 / 100;
        _cents(penaltyP, 27_651, 2, "S-B: Priya's penalty 276.51");
        uint256 repaidP = an.proceeds - penaltyP;
        _cents(repaidP, 894_064, 50, "S-B: 8,940.64 repays Priya");
        assertApproxEqAbs(
            market.debtOf(idNVDA, priya), dPriya - repaidP, 1, "D - (1 - lambda) P, to the unit"
        );
        _cents(market.debtOf(idNVDA, priya), 457_838, 50, "S-B: Priya owes 4,578.38");
        assertEq(market.position(idNVDA, priya).collateral / 1e16, 4_092, "Priya keeps 40.92 NVDA");
        assertEq(market.position(idCOIN, dev).borrowShares, 0, "Dev owes nothing (non-recourse)");
        uint256 shortfall = poolCash + penaltyP / 3 - usdc.balanceOf(address(up));
        assertEq(shortfall, dDev - 21_870e6, "shortfall = Dev's debt - proceeds, to the unit");
        _cents(shortfall, 67_259, 5, "S-B: shortfall 672.59 paid by the pool");
        // cash out = debt repaid (8,940.64 + 21,870.00) + penalty 276.51 = cash in
        assertEq(repaidP + 21_870e6 + penaltyP, cashIn, "S-B: cash in = cash out");
        _assertSeniorWhole(seniorBefore);

        // the other assets' REOPEN ends; the epoch settles at reopen + 10 min
        house.completeReopen(AAPL);
        house.completeReopen(TSLA);
        house.completeReopen(SPY);
        assertFalse(clk.closureInfo(NVDA).reopenPending);
        assertFalse(clk.closureInfo(COIN).reopenPending);
        vm.warp(printAt + 10 minutes);
        vm.prank(kai);
        up.settleEpoch(FRI);
        Epoch memory e = up.epoch(FRI);
        assertEq(uint8(e.phase), uint8(EpochPhase.SETTLED));
        assertEq(e.premiums, 297.42e6);
        assertEq(e.lossesPaid, shortfall);
        // the 40 COIN are marked at min(cost 8,730, 40 x 225 x 0.97 = 8,730): an asset swap, not a loss (R-12)
        Inventory memory inv = up.inventory(COIN);
        assertEq(inv.qty, 40e18);
        assertEq(inv.cost, 8_730e6);
        assertEq(
            uint256(e.navAfter),
            uint256(e.navBefore) + e.premiums + e.riskFees + e.penalties + e.bonds - e.lossesPaid,
            "INV-POOL-01"
        );
        _poolAndSara(e);
    }

    /// @dev Pool NAV, share price and Sara's payout. The doc's pool: 100,000 + 111.97 fee + 297.42 premiums + 165.43
    ///      penalty thirds + 86.00 bond − 672.59 = 99,988.23 over 100,000 shares = 0.9998823, Sara 9,998.82.
    ///      On chain the NAV has the same terms and lands within cents (the book's actual R-09 accrual instead of the
    ///      doc's 1,119.72 × 10 %, and the cents of the rounded lots and debts above). The share price differs by more,
    ///      for one R-09 reason: Umar's Wednesday deposit is minted at the NAV that already holds Mon–Wed's risk fee,
    ///      so he receives fewer than 20,000 shares and that fee stays with the earlier underwriters (Sara included).
    ///      Asserted: NAV vs the doc within 15 cents, NAV / the doc's 100,000 shares vs 9,998.82 within 2 cents, and
    ///      the chain's price and Sara's payout as identities.
    function _poolAndSara(Epoch memory e) internal {
        uint256 supply = 80_000e18 + up.balanceOf(umar); // Sara's escrowed shares are still in the supply
        uint256 price = e.sharePriceAfter;
        emit log_named_decimal_uint("S-B pool NAV after (doc 99,988.23)", e.navAfter, 6);
        emit log_named_decimal_uint("S-B pool share price after (doc 0.9998823)", price, 18);
        emit log_named_decimal_uint("S-B Umar's shares (doc 20,000)", up.balanceOf(umar), 18);
        _cents(e.navAfter, 9_998_823, 15, "S-B: pool NAV after 99,988.23");
        _cents(uint256(e.navAfter) / 10, 999_882, 2, "S-B: 10,000 of the doc's 100,000 shares = 9,998.82");
        assertEq(price, (uint256(e.navAfter) + 1) * 1e30 / (supply + 1e12), "share price = NAV / supply");
        if (!umarOnMonday) {
            assertLt(up.balanceOf(umar), 20_000e18, "Umar paid for the fee accrued before his deposit (R-09)");
        }
        uint256 before = usdc.balanceOf(sara);
        vm.prank(sara);
        uint256 paid = up.claimWithdraw(FRI);
        assertEq(usdc.balanceOf(sara) - before, paid);
        assertEq(paid, 10_000e18 * price / 1e30, "Sara = 10,000 x sharePriceAfter, to the unit");
        emit log_named_decimal_uint("S-B Sara receives (doc 9,998.82)", paid, 6);
        // with the doc's 100,000 shares (Umar in on Monday) the chain's price and Sara's payout are the doc's
        if (umarOnMonday) {
            assertApproxEqAbs(
                price, 0.9998823e18, 0.0000015e18, "S-B: share price 0.9998823 (NAV within 15 cents)"
            );
            _cents(paid, 999_882, 2, "S-B: Sara receives 9,998.82");
        }
        // the doc's arithmetic at its own inputs, to the cent
        assertEq(uint256(100_000e6) + 111.97e6 + 297.42e6 + 165.43e6 + 86e6 - 672.59e6, 99_988.23e6);
        assertEq(uint256(99_988.23e6) * 10_000 / 100_000, 9_998.823e6);
    }

    function _assertSeniorWhole(uint256 seniorBefore) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ICredenceMarketEvents.Shortfall.selector) {
                (, uint256 paidPool, uint256 paidReserve, uint256 seniorLoss) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                assertEq(seniorLoss, 0, "senior loss 0");
                assertEq(paidReserve, 0, "reserve untouched");
                assertGt(paidPool, 0);
                ++n;
            }
        }
        assertEq(n, 1, "one shortfall (Dev)");
        uint256 seniorAfter =
            market.marketState(idNVDA).totalSupplyAssets + market.marketState(idCOIN).totalSupplyAssets;
        assertGe(seniorAfter, seniorBefore, "the Senior Vault is made whole");
    }
}
