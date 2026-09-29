// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CoreFixture} from "../utils/CoreFixture.sol";
import {
    MarketState,
    Position,
    ClockState,
    ClosureType,
    BellStatus,
    MarketAction,
    LotInfo,
    CoverRequest
} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";

contract CredenceMarketTest is CoreFixture {
    address lena = makeAddr("lena");
    address rahul = makeAddr("rahul");
    address priya = makeAddr("priya");
    address maya = makeAddr("maya");

    function setUp() public {
        vm.warp(1_790_000_000);
        setUpCore();
        _deposit(lena, 230_000e6);
    }

    function test_depositSuppliesDownTheQueue() public view {
        MarketState memory s = market.marketState(idAAPL);
        assertEq(
            s.totalSupplyAssets, 230_000e6, "first market in the supply queue gets everything under its cap"
        );
        assertEq(vault.totalAssets(), 230_000e6);
        assertEq(vault.balanceOf(address(0xdead)), 1e3, "dead shares");
    }

    function test_borrowRepayAndAccrual() public {
        _collateral(rahul, idAAPL, tAAPL, 500e18);
        _borrow(rahul, idAAPL, 60_000e6);
        assertEq(usdc.balanceOf(rahul), 60_000e6);
        assertEq(market.debtOf(idAAPL, rahul), 60_000e6);
        assertEq(market.ltv(idAAPL, rahul), 0.6e18);
        uint256 u = uint256(60_000e6) * 1e18 / 230_000e6;
        uint256 r = 0.02e18 + 0.06e18 * u / 0.9e18;
        assertEq(market.borrowRate(idAAPL), r);
        vm.warp(block.timestamp + 365 days);
        uint256 i = _mulUp(_mulUp(60_000e6, r, 1e18), 365 days, 365 days);
        assertEq(market.debtOf(idAAPL, rahul), 60_000e6 + i, "interest, rounded up");
        MarketState memory s = market.marketState(idAAPL);
        assertEq(s.poolFeeAccrued, i / 10);
        assertEq(s.treasuryFeeAccrued, i / 10);
        assertEq(s.totalSupplyAssets, 230_000e6 + i - 2 * (i / 10), "senior share into supply (R-09)");
        uint256 debt = market.debtOf(idAAPL, rahul);
        usdc.mint(rahul, debt);
        vm.startPrank(rahul);
        usdc.approve(address(market), debt);
        uint256 paid = market.repay(idAAPL, rahul, 0, market.position(idAAPL, rahul).borrowShares);
        vm.stopPrank();
        assertEq(paid, debt);
        assertEq(market.debtOf(idAAPL, rahul), 0);
        market.claimFees(idAAPL);
        assertEq(pool.riskFees(), i / 10);
        assertEq(usdc.balanceOf(address(treasury)), i / 10);
    }

    function test_borrowAboveMaxLtvReverts() public {
        _collateral(rahul, idAAPL, tAAPL, 500e18);
        vm.prank(rahul);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.LtvAboveLimit.selector, 0.750001e18, 0.75e18));
        market.borrow(idAAPL, 75_000.1e6, rahul);
    }

    function test_borrowBlockedByState() public {
        _collateral(rahul, idAAPL, tAAPL, 500e18);
        clk.setState(AAPL, ClockState.REOPEN);
        vm.prank(rahul);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICredenceErrors.ActionNotAllowedInState.selector, MarketAction.BORROW, ClockState.REOPEN
            )
        );
        market.borrow(idAAPL, 1e6, rahul);
        clk.setState(AAPL, ClockState.REGULAR);
        orc.setStress(AAPL, true);
        vm.prank(rahul);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.BorrowPaused.selector, idAAPL));
        market.borrow(idAAPL, 1e6, rahul);
    }

    function _moveToNvda(uint256 amount) internal {
        vm.startPrank(allocator);
        vault.deallocate(idAAPL, amount);
        vault.allocate(idNVDA, amount);
        vm.stopPrank();
    }

    function test_bellWindowUsesSafeLtvWithProjectedDebt() public {
        _moveToNvda(100_000e6);
        engine.setSafeLtv(NVDA, uint8(ClosureType.WEEKEND), 0.712580117506e18);
        clk.setNextClose(NVDA, uint40(block.timestamp + 1 hours), ClosureType.WEEKEND, 3);
        _collateral(priya, idNVDA, tNVDA, 500e18);
        vm.prank(priya);
        vm.expectRevert();
        market.borrow(idNVDA, 67_000e6, priya);
        _borrow(priya, idNVDA, 60_000e6);
        assertEq(market.borrowLimitLtv(idNVDA, priya), 0.712580117506e18);
    }

    function _priyaAtRisk() internal {
        _moveToNvda(100_000e6);
        _collateral(priya, idNVDA, tNVDA, 500e18);
        _borrow(priya, idNVDA, 67_000e6);
        engine.setSafeLtv(NVDA, uint8(ClosureType.WEEKEND), 0.712580117506e18);
        clk.setNextClose(NVDA, uint40(block.timestamp + 2 hours), ClosureType.WEEKEND, 3);
        clk.setClosureId(NVDA, 7);
    }

    function test_buyCoverFromWallet() public {
        _priyaAtRisk();
        (BellStatus st, uint256 repay_, uint256 addQ,) = market.bellStatus(idNVDA, priya);
        assertEq(uint8(st), uint8(BellStatus.NEEDS_ACTION));
        assertGt(repay_, 0);
        assertGt(addQ, 0);
        pool.setPremium(35.95e6, 0.2e18);
        usdc.mint(priya, 35.95e6);
        vm.startPrank(priya);
        usdc.approve(address(market), 35.95e6);
        market.buyCover(idNVDA, 36e6, false);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(pool)), 35.95e6);
        Position memory pos = market.position(idNVDA, priya);
        assertEq(pos.coverClosureId, 8);
        assertEq(market.coveredCollateral(idNVDA, 8), 500e18);
        (st,,,) = market.bellStatus(idNVDA, priya);
        assertEq(uint8(st), uint8(BellStatus.COVERED));
        CoverRequest memory r = pool.lastRequest();
        assertEq(r.closureDays, 3);
        assertEq(r.closureType, uint8(ClosureType.WEEKEND));
        assertEq(r.collateralValue, 90_000e6);
        _collateral(maya, idNVDA, tNVDA, 100e18);
        clk.setNextClose(NVDA, uint40(block.timestamp + 3 hours), ClosureType.WEEKEND, 3);
        _borrow(maya, idNVDA, 10_000e6);
        clk.setNextClose(NVDA, uint40(block.timestamp + 2 hours), ClosureType.WEEKEND, 3);
        vm.warp(block.timestamp + 2 hours - 15 minutes);
        vm.prank(maya);
        vm.expectRevert(); // INV-COV-01: a borrower cannot buy after bellAt
        market.buyCover(idNVDA, 1e6, true);
    }

    function test_enforceBellAutoCoverAndPreclose() public {
        _priyaAtRisk();
        _collateral(maya, idNVDA, tNVDA, 500e18);
        vm.prank(maya);
        market.setAutoCover(idNVDA, false);
        clk.setNextClose(NVDA, uint40(block.timestamp + 3 hours), ClosureType.WEEKEND, 3);
        _borrow(maya, idNVDA, 30_000e6);
        clk.setNextClose(NVDA, uint40(block.timestamp + 2 hours), ClosureType.WEEKEND, 3);
        engine.setSafeLtv(NVDA, uint8(ClosureType.WEEKEND), 0.3e18);
        pool.setPremium(35.95e6, 0.2e18);
        vm.warp(block.timestamp + 2 hours - 15 minutes);
        address[] memory bs = new address[](2);
        (bs[0], bs[1]) = (priya, maya);
        uint256 debtBefore = market.debtOf(idNVDA, priya);
        vm.prank(keeper);
        market.enforceBell(idNVDA, bs);
        assertEq(market.position(idNVDA, priya).coverClosureId, 8, "auto-covered");
        assertEq(market.debtOf(idNVDA, priya), debtBefore + 35.95e6, "premium added to debt");
        uint64 auctionId = market.position(idNVDA, maya).auctionId;
        assertGt(auctionId, 0, "Maya (auto-cover off) goes to the pre-close sale");
        assertEq(usdc.balanceOf(keeper), 4e6, "2 USDC per processed position");
        uint256 x = ah.fix(auctionId);
        assertGt(x, 0);
        assertEq(market.position(idNVDA, maya).collateral, 500e18 - x);
    }

    function _mondayReopen(uint256 open) internal {
        clk.setClosureId(NVDA, 8);
        clk.setState(NVDA, ClockState.REOPEN);
        clk.setOpenPrint(NVDA, uint128(open), uint40(block.timestamp));
        orc.setPrice(NVDA, open);
    }

    function test_reopenFullCloseShortfallPaidByPool() public {
        _priyaAtRisk();
        pool.setPremium(35.95e6, 0.2e18);
        vm.prank(priya);
        market.buyCover(idNVDA, 36e6, true);
        usdc.mint(address(pool), 40_000e6);
        _mondayReopen(126e18);
        address[] memory bs = new address[](1);
        bs[0] = priya;
        vm.prank(keeper);
        market.flagForAuction(idNVDA, bs);
        uint64 id = market.position(idNVDA, priya).auctionId;
        assertEq(ah.fix(id), 500e18, "full close");
        uint256 debt = market.debtOf(idNVDA, priya);
        usdc.mint(address(ah), 62_055e6);
        uint256 proceeds = ah.clearAt(id, 124.11e18, usdc, 18, 6);
        assertEq(proceeds, 62_055e6);
        uint256 supplyBefore = market.marketState(idNVDA).totalSupplyAssets;
        market.settlePositions(id, bs);
        assertEq(market.debtOf(idNVDA, priya), 0);
        assertEq(pool.shortfallsPaid(), debt - 62_055e6, "pool pays the whole shortfall");
        assertEq(market.marketState(idNVDA).totalSupplyAssets, supplyBefore, "senior loss 0");
        assertTrue(ah.settled(id));
        LotInfo memory li = market.lotInfo(id);
        assertEq(li.settledCount, 1);
    }

    function test_waterfallReachesSeniorOnlyAfterPoolAndReserve() public {
        _priyaAtRisk();
        usdc.mint(address(pool), 1_000e6);
        usdc.mint(address(this), 500e6);
        usdc.approve(address(reserve), 500e6);
        vm.prank(timelock);
        reserve.setTargetSize(1_000_000e6);
        reserve.fund(500e6);
        _mondayReopen(126e18);
        address[] memory bs = new address[](1);
        bs[0] = priya;
        market.flagForAuction(idNVDA, bs);
        uint64 id = market.position(idNVDA, priya).auctionId;
        ah.fix(id);
        uint256 debt = market.debtOf(idNVDA, priya);
        usdc.mint(address(ah), 62_055e6);
        ah.clearAt(id, 124.11e18, usdc, 18, 6);
        uint256 supplyBefore = market.marketState(idNVDA).totalSupplyAssets;
        uint256 sharePriceBefore = vault.convertToAssets(1e18);
        market.settlePositions(id, bs);
        uint256 s = debt - 62_055e6;
        uint256 loss = s - 1_000e6 - 500e6;
        assertEq(market.marketState(idNVDA).totalSupplyAssets, supplyBefore - loss, "senior takes the rest");
        assertLt(vault.convertToAssets(1e18), sharePriceBefore, "INV-SV-01: price falls with a recorded loss");
    }

    function test_repayAndAddCollateralWithEverythingReverting() public {
        _collateral(rahul, idAAPL, tAAPL, 500e18);
        _borrow(rahul, idAAPL, 60_000e6);
        engine.setReverting(true);
        orc.setReverting(true);
        clk.setReverting(true);
        _collateral(rahul, idAAPL, tAAPL, 1e18);
        usdc.mint(rahul, 1_000e6);
        vm.startPrank(rahul);
        usdc.approve(address(market), 1_000e6);
        market.repay(idAAPL, rahul, 1_000e6, 0);
        vm.stopPrank();
        assertEq(market.position(idAAPL, rahul).collateral, 501e18);
    }

    function test_guardianPauseAndHaircut() public {
        _collateral(rahul, idAAPL, tAAPL, 500e18);
        vm.prank(safe);
        guardianC.pauseBorrow(bytes32(0));
        vm.prank(rahul);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.BorrowPaused.selector, idAAPL));
        market.borrow(idAAPL, 1e6, rahul);
        vm.prank(safe);
        guardianC.scheduleUnpauseBorrow(bytes32(0));
        vm.prank(safe);
        vm.expectRevert();
        guardianC.executeUnpause(bytes32(0));
        vm.warp(block.timestamp + 6 hours);
        vm.prank(safe);
        guardianC.executeUnpause(bytes32(0));
        clk.setNextClose(AAPL, uint40(block.timestamp + 1 days), ClosureType.OVERNIGHT, 1);
        vm.prank(safe);
        guardianC.raiseHaircut(idAAPL, 500);
        assertEq(market.borrowLimitLtv(idAAPL, rahul), 0.7e18);
        vm.prank(safe);
        vm.expectRevert();
        guardianC.raiseHaircut(idAAPL, 400);
        vm.warp(block.timestamp + 7 days + 1);
        clk.setNextClose(AAPL, uint40(block.timestamp + 1 days), ClosureType.OVERNIGHT, 1);
        assertEq(market.borrowLimitLtv(idAAPL, rahul), 0.75e18, "expired");
    }

    function _mulUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return (a * b + d - 1) / d;
    }
}
