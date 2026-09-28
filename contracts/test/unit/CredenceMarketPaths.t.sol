// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CoreFixture} from "../utils/CoreFixture.sol";
import {
    MarketParams,
    MarketKind,
    MarketWiring,
    MarketState,
    ClockState,
    ClosureType,
    AuctionKind,
    MarketAction,
    RateParams
} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {CredenceMarket} from "../../src/core/CredenceMarket.sol";
import {SeniorVault} from "../../src/core/SeniorVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Governance setters, validation, views, the REOPEN dequeue rule, lot edge cases and the vault's admin and
///         queue paths (the parts of §8.4 / §8.5 the flow tests do not reach).
contract CredenceMarketPathsTest is CoreFixture {
    address lena = makeAddr("lena");
    address bob = makeAddr("bob");
    address carl = makeAddr("carl");

    function setUp() public {
        vm.warp(1_790_000_000);
        setUpCore();
        _deposit(lena, 300_000e6);
        vm.startPrank(allocator);
        vault.deallocate(idAAPL, 200_000e6);
        vault.allocate(idNVDA, 200_000e6);
        vm.stopPrank();
    }

    // ───────────── governance ─────────────

    function test_setters() public {
        vm.startPrank(timelock);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        market.setEngine(address(0));
        market.setEngine(address(engine));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        market.setOracle(address(0));
        market.setOracle(address(orc));
        market.setCaps(idNVDA, 1_000e6, 500e6);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        market.setFeeSplit(idNVDA, 2000, 1001);
        market.setFeeSplit(idNVDA, 500, 500);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        market.setReserveFeeShare(10_001);
        market.setReserveFeeShare(5000);
        vm.expectRevert(ICredenceErrors.InvalidRiskParams.selector);
        market.setRiskParams(idNVDA, 0.75e18, 0.77e18, 0.03e18); // LT < maxLtv + 3 pp
        vm.expectRevert(ICredenceErrors.IncompatibleRiskParams.selector);
        market.setRiskParams(idNVDA, 0.75e18, 0.97e18, 0.1e18); // H*(1 − κ)(1 − λ) = 0.96 ≤ LT
        vm.stopPrank();
        MarketParams memory p = market.marketParams(idNVDA);
        assertEq(p.supplyCap, 1_000e6);
        assertEq(p.borrowCap, 500e6);
        MarketState memory st = market.marketState(idNVDA);
        assertEq(st.feePoolBps, 500);
        assertEq(market.reserveFeeShareBps(), 5000);
        assertEq(market.wiring().engine, address(engine));
        assertEq(market.marketIds().length, 3);
        assertEq(market.upcomingClosureId(idNVDA), 1);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        market.setCaps(idNVDA, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.MarketNotFound.selector, bytes32(uint256(9))));
        market.marketParams(bytes32(uint256(9)));
    }

    function _fresh() internal view returns (MarketParams memory q) {
        q = market.marketParams(idNVDA);
        q.assetId = keccak256("COIN:XNAS");
    }

    function test_createMarketValidation() public {
        MarketParams memory p = market.marketParams(idNVDA);
        vm.startPrank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.MarketExists.selector, idNVDA));
        market.createMarket(p);
        MarketParams memory q = _fresh();
        q.rate.uKink = 1e18;
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        market.createMarket(q);
        q = _fresh();
        q.precloseKappa = 1e18;
        vm.expectRevert(ICredenceErrors.InvalidRiskParams.selector);
        market.createMarket(q);
        q = _fresh();
        q.precloseKappa = 0.3e18; // (1 − λ_pre)(1 − κ_pre) = 0.693 ≤ maxLtv
        vm.expectRevert(ICredenceErrors.IncompatibleRiskParams.selector);
        market.createMarket(q);
        q = _fresh();
        q.collateralToken = address(0);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        market.createMarket(q);
        q = _fresh();
        q.maxLtv = 0;
        vm.expectRevert(ICredenceErrors.InvalidRiskParams.selector);
        market.createMarket(q);
        vm.stopPrank();
        CredenceMarket m = new CredenceMarket(timelock, address(guardianC));
        q = _fresh();
        vm.prank(timelock);
        vm.expectRevert(ICredenceErrors.NotWired.selector);
        m.createMarket(q);
    }

    function test_wiringOnce() public {
        MarketWiring memory w = market.wiring();
        vm.expectRevert(ICredenceErrors.AlreadyWired.selector);
        market.initializeWiring(w);
        CredenceMarket m = new CredenceMarket(timelock, address(guardianC));
        vm.prank(timelock);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        m.initializeWiring(w);
        w.pool = address(0);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        m.initializeWiring(w);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new CredenceMarket(address(0), address(guardianC));
    }

    // ───────────── senior vault hooks ─────────────

    function test_supplyAndWithdrawSupplyAuthAndLimits() public {
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        market.supply(idNVDA, 1);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        market.withdrawSupply(idNVDA, 1, lena);
        vm.startPrank(address(vault));
        vm.expectRevert(ICredenceErrors.ZeroAmount.selector);
        market.supply(idNVDA, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.CapExceeded.selector, 2_000_000e6 + 1, 2_000_000e6)
        );
        market.supply(idNVDA, 1_800_000e6 + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.InsufficientLiquidity.selector, 300_000e6, 200_000e6)
        );
        market.withdrawSupply(idNVDA, 300_000e6, lena);
        vm.stopPrank();
    }

    // ───────────── borrower paths ─────────────

    function test_borrowWithCoverAndErrors() public {
        _collateral(bob, idNVDA, tNVDA, 500e18);
        engine.setSafeLtv(NVDA, uint8(ClosureType.WEEKEND), 0.5e18);
        clk.setNextClose(NVDA, uint40(block.timestamp + 1 hours), ClosureType.WEEKEND, 3); // in the window
        pool.setPremium(10e6, 0.1e18);
        // plain borrow above the safe LTV fails in the window; with cover it may go to maxLtv
        vm.prank(bob);
        vm.expectRevert();
        market.borrow(idNVDA, 60_000e6, bob);
        vm.prank(bob);
        market.borrowWithCover(idNVDA, 60_000e6, bob, 10e6);
        assertEq(market.position(idNVDA, bob).coverClosureId, 1);
        assertEq(market.debtOf(idNVDA, bob), 60_010e6);
        // cover can't be bought twice, nor outside REGULAR
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.AlreadyCovered.selector, 1));
        market.buyCover(idNVDA, 10e6, true);
        clk.setState(NVDA, ClockState.EXTENDED);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICredenceErrors.ActionNotAllowedInState.selector, MarketAction.BUY_COVER, ClockState.EXTENDED
            )
        );
        market.borrowWithCover(idNVDA, 1e6, bob, 10e6);
        // zero / bad inputs
        vm.startPrank(bob);
        vm.expectRevert(ICredenceErrors.ZeroAmount.selector);
        market.borrow(idNVDA, 0, bob);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        market.borrow(idNVDA, 1, address(0));
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        market.repay(idNVDA, bob, 1, 1);
        vm.expectRevert(ICredenceErrors.ZeroAmount.selector);
        market.addCollateral(idNVDA, bob, 0);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        market.addCollateral(idNVDA, address(0), 1);
        vm.expectRevert(ICredenceErrors.ZeroAmount.selector);
        market.withdrawCollateral(idNVDA, 0, bob);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        market.withdrawCollateral(idNVDA, 501e18, bob);
        vm.stopPrank();
        vm.prank(carl);
        vm.expectRevert(ICredenceErrors.NoDebt.selector);
        market.repay(idNVDA, carl, 1, 0);
        // cover above maxLtv + δ is refused (R-03)
        clk.setState(NVDA, ClockState.REGULAR);
        clk.setNextClose(NVDA, uint40(block.timestamp + 5 hours), ClosureType.WEEKEND, 3);
        _collateral(carl, idNVDA, tNVDA, 100e18);
        _borrow(carl, idNVDA, 13_000e6);
        orc.setPrice(NVDA, 160e18); // LTV 81%
        vm.prank(carl);
        vm.expectRevert();
        market.buyCover(idNVDA, 10e6, true);
        orc.setPrice(NVDA, 180e18);
        vm.prank(carl);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.PremiumAboveMax.selector, 10e6, 1));
        market.buyCover(idNVDA, 1, true);
    }

    function test_withdrawCollateralRules() public {
        _collateral(bob, idNVDA, tNVDA, 100e18);
        _borrow(bob, idNVDA, 12_000e6); // 66.7%
        vm.prank(bob);
        vm.expectRevert(); // above the 75% limit
        market.withdrawCollateral(idNVDA, 15e18, bob);
        vm.prank(bob);
        market.withdrawCollateral(idNVDA, 5e18, bob);
        // the 1.05 HF floor binds only for tight parameters (NAV-like 90% / 93%): LTV 89% is inside the limit,
        // but HF = 0.93 / 0.89 < 1.05
        vm.prank(timelock);
        market.setRiskParams(idNVDA, 0.9e18, 0.93e18, 0.01e18);
        vm.prank(bob);
        vm.expectRevert();
        market.withdrawCollateral(idNVDA, 20e18, bob);
        clk.setState(NVDA, ClockState.REOPEN);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICredenceErrors.ActionNotAllowedInState.selector,
                MarketAction.WITHDRAW_COLLATERAL,
                ClockState.REOPEN
            )
        );
        market.withdrawCollateral(idNVDA, 1e18, bob);
        // an empty position can always leave, whatever the state
        _collateral(carl, idNVDA, tNVDA, 3e18);
        vm.prank(carl);
        market.withdrawCollateral(idNVDA, 3e18, carl);
        assertEq(tNVDA.balanceOf(carl), 3e18);
        // closed: down to the safe LTV on projected debt
        clk.setState(NVDA, ClockState.CLOSED);
        engine.setSafeLtv(NVDA, 1, 0.6e18);
        vm.prank(bob);
        vm.expectRevert();
        market.withdrawCollateral(idNVDA, 10e18, bob);
    }

    // ───────────── lots ─────────────

    function _reopenWith(address b, uint256 q, uint256 debt, uint256 open) internal returns (uint64 id) {
        _collateral(b, idNVDA, tNVDA, q);
        _borrow(b, idNVDA, debt);
        clk.setClosureId(NVDA, 2);
        clk.setState(NVDA, ClockState.REOPEN);
        clk.setOpenPrint(NVDA, uint128(open), uint40(block.timestamp));
        orc.setPrice(NVDA, open);
        address[] memory bs = new address[](1);
        bs[0] = b;
        market.flagForAuction(idNVDA, bs);
        id = market.position(idNVDA, b).auctionId;
    }

    function test_dequeueOnRepayAndEmptyLot() public {
        uint64 id = _reopenWith(bob, 100e18, 13_000e6, 150e18); // HF 0.92 at the open
        _collateral(carl, idNVDA, tNVDA, 100e18);
        clk.setState(NVDA, ClockState.REGULAR);
        orc.setPrice(NVDA, 180e18);
        _borrow(carl, idNVDA, 13_000e6);
        orc.setPrice(NVDA, 150e18);
        clk.setState(NVDA, ClockState.REOPEN);
        address[] memory bs = new address[](1);
        bs[0] = carl;
        market.flagForAuction(idNVDA, bs);
        assertEq(market.lotBorrowers(id).length, 2);
        // Bob repays enough at the open print: he leaves the queue (§8.4.3 dequeue rule), Carl moves to his slot
        usdc.mint(bob, 5_000e6);
        vm.startPrank(bob);
        usdc.approve(address(market), 5_000e6);
        market.repay(idNVDA, bob, 5_000e6, 0);
        vm.stopPrank();
        assertEq(market.position(idNVDA, bob).auctionId, 0);
        assertEq(market.lotBorrowers(id).length, 1);
        assertEq(market.lotBorrowers(id)[0], carl);
        // Carl adds collateral: he leaves too, and the lot releases nothing
        _collateral(carl, idNVDA, tNVDA, 50e18);
        assertEq(market.position(idNVDA, carl).auctionId, 0);
        assertEq(ah.fix(id), 0);
        (uint128 qty, bool settled) = market.lotPosition(id, carl);
        assertEq(qty, 0);
        assertFalse(settled);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.LotAlreadyReleased.selector, id));
        ah.fix(id);
    }

    function test_releaseCuredAtFixingAndWrongState() public {
        uint64 id = _reopenWith(bob, 100e18, 13_000e6, 150e18);
        vm.prank(address(ah));
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NotInLot.selector, id, address(0)));
        market.onAuctionCleared(id, 0, 0);
        // the price recovers before lot fixing: Bob is dropped at release
        orc.setPrice(NVDA, 200e18);
        clk.setState(NVDA, ClockState.CLOSED);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICredenceErrors.ActionNotAllowedInState.selector,
                MarketAction.FLAG_FOR_AUCTION,
                ClockState.CLOSED
            )
        );
        ah.fix(id);
        clk.setState(NVDA, ClockState.REOPEN);
        assertEq(ah.fix(id), 0);
        assertEq(market.position(idNVDA, bob).auctionId, 0);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        market.releaseLots(id);
    }

    function test_partialSettlementAndReserveFeeShare() public {
        uint64 id = _reopenWith(bob, 100e18, 13_500e6, 158.4e18); // G-12 shape: partial lot
        uint256 x = ah.fix(id);
        assertLt(x, 100e18);
        usdc.mint(address(ah), 20_000e6);
        ah.clearAt(id, 156.024e18, usdc, 18, 6);
        vm.prank(address(ah));
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.LotAlreadyCleared.selector, id));
        market.onAuctionCleared(id, 0, 0);
        address[] memory bs = new address[](1);
        bs[0] = bob;
        market.settlePositions(id, bs);
        market.settlePositions(id, bs); // settled already: no-op
        assertGt(market.debtOf(idNVDA, bob), 0, "partial: the position stays open");
        (, bool settled) = market.lotPosition(id, bob);
        assertTrue(settled);
        // fees: part of the treasury share goes to the reserve
        vm.prank(timelock);
        market.setReserveFeeShare(3000);
        vm.prank(timelock);
        reserve.setTargetSize(1_000_000e6);
        vm.warp(block.timestamp + 30 days);
        uint256 resBefore = reserve.balance();
        market.claimFees(idNVDA);
        assertGt(reserve.balance(), resBefore);
    }

    /// INV-LIQ-02: in EXTENDED a covered position is never sold; an uncovered one below HF 0.92 is (EMERGENCY).
    function test_noEmergencySaleOfCoveredPositions() public {
        clk.setClosureId(NVDA, 4);
        clk.setNextClose(NVDA, uint40(block.timestamp + 5 hours), ClosureType.WEEKEND, 3);
        pool.setPremium(1e6, 0.1e18);
        _collateral(bob, idNVDA, tNVDA, 100e18);
        _borrow(bob, idNVDA, 13_000e6);
        vm.prank(bob);
        market.buyCover(idNVDA, 1e6, true); // covered for closure 5
        _collateral(carl, idNVDA, tNVDA, 100e18);
        _borrow(carl, idNVDA, 13_000e6);
        // the close: closure 5 starts; overnight trading crashes the price (HF ≈ 0.74)
        clk.setClosureId(NVDA, 5);
        clk.setState(NVDA, ClockState.EXTENDED);
        orc.setPrice(NVDA, 120e18);
        address[] memory bs = new address[](2);
        (bs[0], bs[1]) = (bob, carl);
        market.flagForAuction(idNVDA, bs);
        assertEq(market.position(idNVDA, bob).auctionId, 0, "covered: waits for the regular open");
        uint64 id = market.position(idNVDA, carl).auctionId;
        assertGt(id, 0, "uncovered: EMERGENCY sale");
        assertEq(uint8(market.lotInfo(id).kind), uint8(AuctionKind.EMERGENCY));
    }

    function test_settleBeforeClearReverts() public {
        uint64 id = _reopenWith(bob, 100e18, 13_500e6, 158.4e18);
        address[] memory bs = new address[](1);
        bs[0] = bob;
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.LotNotCleared.selector, id));
        market.settlePositions(id, bs);
    }

    // ───────────── vault admin and queues ─────────────

    function test_vaultAdminAndQueues() public {
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        vault.setAllocator(bob);
        vm.startPrank(timelock);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        vault.setAllocator(address(0));
        vault.setAllocator(bob);
        vm.stopPrank();
        assertEq(vault.allocator(), bob);
        bytes32[] memory q = new bytes32[](1);
        q[0] = idAAPL;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownMarket.selector, idNVDA));
        vault.setWithdrawQueue(q); // NVDA holds vault money and must stay reachable
        vm.prank(bob);
        vault.setSupplyQueue(q);
        assertEq(vault.supplyQueue().length, 1);
        assertEq(vault.withdrawQueue().length, 3);
        assertEq(vault.queueLength(), 0);
        assertEq(vault.maxRedeem(lena), vault.balanceOf(lena));
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.CapExceeded.selector, 2_000_001e6 + 0, 2_000_000e6)
        );
        vault.allocate(idAAPL, 2_000_001e6 - 100_000e6 + 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownMarket.selector, bytes32(uint256(7))));
        vault.allocate(bytes32(uint256(7)), 1);
    }

    function test_redeemQueueStopsAtLiquidity() public {
        // lend everything out, then queue two redeems larger than the free cash
        _collateral(bob, idNVDA, tNVDA, 2_000e18);
        _borrow(bob, idNVDA, 195_000e6);
        uint256 shares = vault.balanceOf(lena);
        vm.startPrank(lena);
        uint256 r1 = vault.requestRedeem(shares / 5, lena); // ~60k of ~105k available
        uint256 r2 = vault.requestRedeem(shares / 2, lena); // ~150k: more than what is left
        vm.stopPrank();
        assertEq(vault.queueLength(), 2);
        vault.processQueue(5);
        assertTrue(vault.redeemRequest(r1).processed);
        assertFalse(vault.redeemRequest(r2).processed, "stops when liquidity runs out");
        assertEq(vault.queueHead(), r2);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NotRequestOwner.selector, r1));
        vault.claimRedeem(r1);
        vm.prank(lena);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.RequestNotProcessed.selector, r2));
        vault.claimRedeem(r2);
        vm.prank(lena);
        uint256 got = vault.claimRedeem(r1);
        assertGt(got, 0);
        vm.prank(lena);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.RequestAlreadyClaimed.selector, r1));
        vault.claimRedeem(r1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.RequestNotFound.selector, 99));
        vault.claimRedeem(99);
        vm.prank(lena);
        vm.expectRevert(ICredenceErrors.ZeroAmount.selector);
        vault.requestRedeem(0, lena);
        vm.prank(lena);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        vault.requestRedeem(1, address(0));
    }

    function test_firstDepositTooSmall() public {
        SeniorVault v = new SeniorVault(IERC20(address(usdc)), "v", "v", timelock, address(market), allocator);
        usdc.mint(bob, 1);
        vm.startPrank(bob);
        usdc.approve(address(v), 1);
        vm.expectRevert(); // 1 wei of USDC mints 1e6 shares: fine; a zero-share deposit is not
        v.deposit(0, bob);
        vm.stopPrank();
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new SeniorVault(IERC20(address(usdc)), "v", "v", address(0), address(market), allocator);
    }
}
