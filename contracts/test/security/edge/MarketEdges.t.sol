// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {EdgeFixture} from "./EdgeFixture.sol";
import {ClockState, MarketAction, AuctionKind} from "../../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../../src/libraries/Errors.sol";
import {ICredenceMarketEvents} from "../../../src/libraries/Events.sol";
import {WadMath} from "../../../src/libraries/WadMath.sol";

/// @title Market edge cases (matrix rows E-M-*, `docs/qa/edge-cases.md`).
/// @notice Boundaries (0, 1 unit, exactly at a limit, one unit over), deadlines (the last second, the first second
///         late), two actors in one block, and state changes mid-flow, on the real pool and auction house.
contract MarketEdgesTest is EdgeFixture {
    function setUp() public {
        setUpEdge();
    }

    // ───────────── limits: exactly at, one unit over ─────────────

    /// E-M-01: LTV exactly maxLtv is allowed; one base unit more is refused.
    function test_E_M01_borrowExactlyAtMaxLtv_oneUnitOverReverts() public {
        _collateral(alice, idNVDA, tNVDA, 1_000e18); // $180,000
        _borrow(alice, idNVDA, 135_000e6); // 75.000000 %
        assertEq(market.ltv(idNVDA, alice), 0.75e18);
        _collateral(bob, idNVDA, tNVDA, 1_000e18);
        uint256 over = WadMath.mulDivUp(135_000e6 + 1, 1e18, 180_000e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.LtvAboveLimit.selector, over, 0.75e18));
        market.borrow(idNVDA, 135_000e6 + 1, bob);
    }

    /// E-M-02: two borrowers race for the last liquidity in one block: exactly what is left is fine, one unit more
    ///         reverts `InsufficientLiquidity`, and the market ends at zero liquidity (withdrawals then queue).
    function test_E_M02_lastUnitOfLiquidity_twoBorrowersOneBlock() public {
        uint256 liq = market.liquidity(idNVDA);
        _collateral(alice, idNVDA, tNVDA, 10_000e18);
        _borrow(alice, idNVDA, liq - 100);
        _collateral(bob, idNVDA, tNVDA, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.InsufficientLiquidity.selector, 101, 100));
        market.borrow(idNVDA, 101, bob);
        _borrow(bob, idNVDA, 100);
        assertEq(market.liquidity(idNVDA), 0);
        // the senior vault cannot pull from a fully used market
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.InsufficientLiquidity.selector, 1, 0));
        market.withdrawSupply(idNVDA, 1, address(vault));
    }

    /// E-M-03: borrow cap exactly reached, then one unit over.
    function test_E_M03_borrowCapExactlyReached() public {
        vm.prank(timelock);
        market.setCaps(idNVDA, 2_000_000e6, 1_000e6);
        _collateral(alice, idNVDA, tNVDA, 100e18);
        _borrow(alice, idNVDA, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.CapExceeded.selector, 1_000e6 + 1, 1_000e6));
        market.borrow(idNVDA, 1, alice);
    }

    // ───────────── dust and full repay ─────────────

    /// E-M-04: a 1-unit borrow and its repay; repaying *more* than the debt by assets reverts (the UI's "repay max"
    ///         must repay by shares), and a by-shares full repay costs exactly `debtOf` and leaves nothing.
    function test_E_M04_dustBorrow_andFullRepayByShares() public {
        _collateral(alice, idNVDA, tNVDA, 100e18);
        _borrow(alice, idNVDA, 1);
        assertEq(market.debtOf(idNVDA, alice), 1, "1-unit debt");
        _borrow(alice, idNVDA, 10_000e6 - 1);
        vm.warp(block.timestamp + 1 days);
        uint256 debt = market.debtOf(idNVDA, alice);
        assertGt(debt, 10_000e6, "interest accrued");
        usdc.mint(alice, debt + 1);
        vm.startPrank(alice);
        usdc.approve(address(market), type(uint256).max);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        market.repay(idNVDA, alice, debt + 1, 0);
        uint256 shares = market.position(idNVDA, alice).borrowShares;
        uint256 repaid = market.repay(idNVDA, alice, 0, shares);
        vm.stopPrank();
        assertEq(repaid, debt, "a by-shares full repay costs exactly debtOf");
        assertEq(market.debtOf(idNVDA, alice), 0);
        assertEq(market.position(idNVDA, alice).borrowShares, 0);
        // an empty position leaves whatever the clock says
        clk.setState(NVDA, ClockState.REOPEN);
        vm.prank(alice);
        market.withdrawCollateral(idNVDA, 100e18, alice);
    }

    /// E-M-05: repaying 1 base unit by assets when a share is worth more than 1 unit burns no share and reverts
    ///         (`ZeroAmount`) instead of taking the unit for nothing.
    function test_E_M05_oneUnitRepayNeverTakesMoneyForNothing() public {
        _collateral(alice, idNVDA, tNVDA, 1_000e18);
        _borrow(alice, idNVDA, 100_000e6);
        vm.warp(block.timestamp + 365 days);
        usdc.mint(alice, 1);
        vm.startPrank(alice);
        usdc.approve(address(market), 1);
        uint256 sharesBefore = market.position(idNVDA, alice).borrowShares;
        try market.repay(idNVDA, alice, 1, 0) returns (uint256 repaid) {
            assertEq(repaid, 1);
            assertLt(market.position(idNVDA, alice).borrowShares, sharesBefore, "a unit paid burns a share");
        } catch (bytes memory err) {
            assertEq(bytes4(err), ICredenceErrors.ZeroAmount.selector);
            assertEq(usdc.balanceOf(alice), 1, "nothing taken");
        }
        vm.stopPrank();
    }

    /// E-M-06: the 1.05 HF floor on withdrawals (§12.2) binds when LT is the minimum 3 pp above maxLtv: inside the
    ///         LTV limit but HF < 1.05 reverts `HealthFactorTooLow`; HF just above passes.
    function test_E_M06_withdrawHfFloorBindsAtTightParams() public {
        vm.prank(timelock);
        market.setRiskParams(idNVDA, 0.75e18, 0.78e18, 0.03e18);
        _collateral(alice, idNVDA, tNVDA, 1_000e18);
        _borrow(alice, idNVDA, 100_000e6);
        // 745 NVDA left: LTV 74.57 % (inside 75 %), HF = 134,100 × 0.78 / 100,000 = 1.04598
        uint256 hf = WadMath.mulDivDown(134_100e6, 0.78e18, 100_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.HealthFactorTooLow.selector, hf, 1.05e18));
        market.withdrawCollateral(idNVDA, 255e18, alice);
        vm.prank(alice); // 748 NVDA left: HF 1.05019
        market.withdrawCollateral(idNVDA, 252e18, alice);
    }

    // ───────────── cover and the Bell: the last second, the first second late ─────────────

    /// E-M-07: `buyCover` at bellAt − 1 s works; at bellAt it is refused (INV-COV-01).
    function test_E_M07_buyCoverLastSecondBeforeTheBell() public {
        uint40 bellAt = _closeAt(0, 0) - 15 minutes;
        _position(alice, idTSLA, tTSLA, 100e18, 15_000e6);
        _position(bob, idTSLA, tTSLA, 100e18, 15_000e6);
        vm.warp(bellAt - 1);
        _cover(alice, idTSLA, 1_000e6);
        assertEq(market.position(idTSLA, alice).coverClosureId, 1);
        vm.warp(bellAt);
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(market), 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICredenceErrors.ActionNotAllowedInState.selector, MarketAction.BUY_COVER, ClockState.REGULAR
            )
        );
        market.buyCover(idTSLA, 1_000e6, false);
        vm.stopPrank();
    }

    function _needsAction(address b) internal {
        _position(b, idTSLA, tTSLA, 100e18, 18_000e6); // 72 %
        engine.setSafeLtv(TSLA, 1, 0.6e18);
    }

    /// E-M-08: `enforceBell` runs in [bellAt, closeAt): refused at bellAt − 1 s and at closeAt.
    function test_E_M08_enforceBellWindowEdges() public {
        uint40 close = _closeAt(0, 0);
        _needsAction(alice);
        bytes memory refused = abi.encodeWithSelector(
            ICredenceErrors.ActionNotAllowedInState.selector, MarketAction.ENFORCE_BELL, ClockState.REGULAR
        );
        vm.warp(close - 15 minutes - 1);
        vm.prank(keeper);
        vm.expectRevert(refused);
        market.enforceBell(idTSLA, _one(alice));
        vm.warp(close);
        vm.prank(keeper);
        vm.expectRevert(refused);
        market.enforceBell(idTSLA, _one(alice));
        vm.warp(close - 15 minutes);
        vm.prank(keeper);
        market.enforceBell(idTSLA, _one(alice));
        assertEq(market.position(idTSLA, alice).coverClosureId, 1, "auto-covered at bellAt");
    }

    /// E-M-09: the same borrower twice in one batch (two keepers' lists merged) is enforced once, tipped once.
    function test_E_M09_duplicateBorrowerInOneBatch() public {
        _needsAction(alice);
        vm.warp(_closeAt(0, 0) - 15 minutes);
        vm.recordLogs();
        vm.prank(keeper);
        market.enforceBell(idTSLA, _two(alice, alice));
        assertEq(_count(vm.getRecordedLogs(), ICredenceMarketEvents.BellEnforced.selector), 1);
        // and a second keeper's batch in the same block is a no-op
        vm.recordLogs();
        vm.prank(carl);
        market.enforceBell(idTSLA, _one(alice));
        assertEq(_count(vm.getRecordedLogs(), ICredenceMarketEvents.BellEnforced.selector), 0);
    }

    /// E-M-10: a Bell with no positions, and with a borrower that has no debt, is a no-op (no revert, no event).
    function test_E_M10_bellWithNothingToDo() public {
        _collateral(carl, idTSLA, tTSLA, 10e18);
        vm.warp(_closeAt(0, 0) - 15 minutes);
        vm.recordLogs();
        vm.startPrank(keeper);
        market.enforceBell(idTSLA, new address[](0));
        market.enforceBell(idTSLA, _two(carl, address(0xdead)));
        vm.stopPrank();
        assertEq(_count(vm.getRecordedLogs(), ICredenceMarketEvents.BellEnforced.selector), 0);
    }

    /// E-M-11: manual cover exactly at the coverable LTV (maxLtv + δ = 75.5 %) works; just above reverts
    ///         `LtvAboveCoverable` (R-03).
    function test_E_M11_coverExactlyAtCoverableLtv() public {
        vm.warp(_closeAt(0, 0) - 1 hours); // the pool writes cover inside the Bell window; no interest after this
        _position(alice, idTSLA, tTSLA, 100e18, 15_100e6);
        _position(bob, idTSLA, tTSLA, 100e18, 15_100e6);
        orc.setPrice(TSLA, 200e18); // 15,100 / 20,000 = 75.5 %
        _cover(alice, idTSLA, 1_000e6);
        assertEq(market.position(idTSLA, alice).coverClosureId, 1);
        orc.setPrice(TSLA, 199.99e18);
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(market), 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICredenceErrors.LtvAboveCoverable.selector, WadMath.mulDivUp(15_100e6, 1e18, 19_999e6), 0.755e18
            )
        );
        market.buyCover(idTSLA, 1_000e6, false);
        vm.stopPrank();
    }

    /// E-M-12 (QA-10): a Bell batch sent after the PRECLOSE lot fixing (close − 5 min) but before the close must
    ///         still process what it can (§8.4.3 "skip, don't revert"). Today one position that needs a pre-close
    ///         sale reverts the whole batch (`TooLate`), so the auto-cover of every other position in it is lost
    ///         and the closure starts with them uncovered. The ops page fires at bellAt + 10 min = exactly then.
    function test_E_M12_QA10_lateBellBatchStillAutoCovers() public finding {
        _needsAction(alice);
        _needsAction(bob);
        vm.prank(bob);
        market.setAutoCover(idTSLA, false); // bob's default is the pre-close sale
        vm.warp(_closeAt(0, 0) - 4 minutes);
        vm.prank(keeper);
        market.enforceBell(idTSLA, _two(alice, bob));
        assertEq(market.position(idTSLA, alice).coverClosureId, 1, "alice auto-covered despite bob");
    }

    /// E-M-12b: the same batch one second before the PRECLOSE fixing processes both.
    function test_E_M12b_bellBatchBeforePrecloseFixing() public {
        _needsAction(alice);
        _needsAction(bob);
        vm.prank(bob);
        market.setAutoCover(idTSLA, false);
        vm.warp(_closeAt(0, 0) - 5 minutes - 1);
        vm.prank(keeper);
        market.enforceBell(idTSLA, _two(alice, bob));
        assertEq(market.position(idTSLA, alice).coverClosureId, 1);
        assertGt(market.position(idTSLA, bob).auctionId, 0, "bob joined the pre-close lot");
    }

    // ───────────── liquidation queue ─────────────

    function _intraday() internal {
        vm.warp(_openAt(0, 1) + 1 hours);
        _day(0, 1);
    }

    /// E-M-13: a position flagged into a lot cannot borrow, withdraw or buy cover (`PositionInAuction`), but can
    ///         still repay and add collateral.
    function test_E_M13_positionInAuctionIsFrozenButCanCure() public {
        _intraday();
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        orc.setPrice(NVDA, 150e18);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(alice));
        uint64 lot = market.position(idNVDA, alice).auctionId;
        assertGt(lot, 0);
        bytes memory inLot = abi.encodeWithSelector(ICredenceErrors.PositionInAuction.selector, lot);
        vm.startPrank(alice);
        vm.expectRevert(inLot);
        market.borrow(idNVDA, 1, alice);
        vm.expectRevert(inLot);
        market.withdrawCollateral(idNVDA, 1, alice);
        usdc.mint(alice, 10e6);
        usdc.approve(address(market), 10e6);
        vm.expectRevert(inLot);
        market.buyCover(idNVDA, 10e6, false);
        market.repay(idNVDA, alice, 1e6, 0);
        vm.stopPrank();
        _collateral(alice, idNVDA, tNVDA, 1e18);
    }

    /// E-M-14: HF exactly 1.0 is not liquidatable; one wei of price lower is.
    function test_E_M14_hfExactlyOneIsNotFlagged() public {
        _intraday();
        _position(alice, idNVDA, tNVDA, 1_000e18, 135_000e6);
        _position(bob, idNVDA, tNVDA, 1_000e18, 135_000e6);
        uint256 debt = market.debtOf(idNVDA, alice);
        orc.setPrice(NVDA, debt * 1.25e9); // c × 0.8 = debt exactly
        assertEq(market.healthFactor(idNVDA, alice), 1e18);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(alice));
        assertEq(market.position(idNVDA, alice).auctionId, 0, "HF = 1 stays");
        orc.setPrice(NVDA, debt * 1.25e9 - 1e9);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(bob));
        assertGt(market.position(idNVDA, bob).auctionId, 0, "HF < 1 goes");
    }

    /// E-M-15: 129 positions: the first lot fills at 128 and the next one — flagged in a later call — goes into
    ///         the next tranche instead of reverting `TooManyPositions`.
    function test_E_M15_lotOver128PositionsRollsIntoATranche() public {
        _intraday();
        address[] memory bs = new address[](129);
        for (uint256 i; i < 129; ++i) {
            bs[i] = address(uint160(0x10000 + i));
            _position(bs[i], idNVDA, tNVDA, 10e18, 1_350e6);
        }
        orc.setPrice(NVDA, 150e18);
        address[] memory first = new address[](128);
        for (uint256 i; i < 128; ++i) {
            first[i] = bs[i];
        }
        vm.prank(keeper);
        market.flagForAuction(idNVDA, first);
        uint64 lot1 = market.position(idNVDA, bs[0]).auctionId;
        assertEq(market.lotBorrowers(lot1).length, 128);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(bs[128]));
        uint64 lot2 = market.position(idNVDA, bs[128]).auctionId;
        assertTrue(lot2 != 0 && lot2 != lot1, "next tranche");
        assertEq(house.auction(lot2).tranche, 1);
    }

    /// E-M-16: a borrower flagged after the current INTRADAY lot was fixed starts a new lot (not
    ///         `LotAlreadyReleased`).
    function test_E_M16_flagAfterTheLotWasFixedStartsANewLot() public {
        _intraday();
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        _position(bob, idNVDA, tNVDA, 1_000e18, 130_000e6);
        orc.setPrice(NVDA, 150e18);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(alice));
        uint64 lot1 = market.position(idNVDA, alice).auctionId;
        vm.warp(block.timestamp + 15);
        house.fixLots(lot1);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(bob));
        uint64 lot2 = market.position(idNVDA, bob).auctionId;
        assertTrue(lot2 != 0 && lot2 != lot1);
        assertEq(uint8(house.auction(lot2).kind), uint8(AuctionKind.INTRADAY));
    }

    /// E-M-17: the REOPEN queue window is [openPrintAt, openPrintAt + 120 s): flagging at + 119 s joins, at
    ///         + 120 s it is refused.
    function test_E_M17_reopenQueueWindowEdge() public {
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        _position(bob, idNVDA, tNVDA, 1_000e18, 130_000e6);
        uint40 at = _openAt(0, 1);
        vm.warp(at);
        _reopen(_session(0, 1), 1, at, [uint128(150e18), 200e18, 250e18]);
        orc.setPrice(NVDA, 150e18);
        vm.warp(at + 119);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(alice));
        assertGt(market.position(idNVDA, alice).auctionId, 0);
        vm.warp(at + 120);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICredenceErrors.ActionNotAllowedInState.selector, MarketAction.FLAG_FOR_AUCTION, ClockState.REOPEN
            )
        );
        market.flagForAuction(idNVDA, _one(bob));
    }

    /// E-M-18: state change mid-flow: the clock goes HALTED between a borrower's approval and the borrow; the
    ///         borrow is then held to the safe LTV on projected debt (not maxLtv), and flagging is refused.
    function test_E_M18_haltBetweenQuoteAndBorrow() public {
        _collateral(alice, idNVDA, tNVDA, 1_000e18);
        clk.setState(NVDA, ClockState.HALTED);
        engine.setSafeLtv(NVDA, 1, 0.5e18);
        vm.prank(alice);
        vm.expectPartialRevert(ICredenceErrors.LtvAboveLimit.selector);
        market.borrow(idNVDA, 135_000e6, alice);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICredenceErrors.ActionNotAllowedInState.selector, MarketAction.FLAG_FOR_AUCTION, ClockState.HALTED
            )
        );
        market.flagForAuction(idNVDA, _one(alice));
    }
}
