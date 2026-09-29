// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {
    ClockState,
    AuctionKind,
    MarketKind,
    Settlement,
    SettlementStatus,
    SolverLot,
    RedemptionClaim,
    MarketAction,
    MarketParams
} from "../../src/libraries/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {ISettlementEvents, IUnderwriterPoolEvents} from "../../src/libraries/Events.sol";
import {SettlementAdapter} from "../../src/settlement/SettlementAdapter.sol";
import {SolverAuction} from "../../src/settlement/SolverAuction.sol";
import {NavFixture} from "../utils/NavFixture.sol";

/// @notice SettlementAdapter + SolverAuction + UnderwriterPool.fallbackAdvance / claimRedemption (Guide §8.8, §8.6.1,
///         ADR-0111): the solver fill, the pool advance and its T+1 redemption, the issuer gate, the NAV REOPEN, and
///         every access and timing rule of the J10 contract.
contract NavSettlementTest is NavFixture {
    address internal ben;

    function setUp() public {
        vm.warp(1_791_000_000); // Fri 2026-10-02 (the calendar starts Monday 2026-09-28)
        setUpNav();
        vm.warp(_morning(1, 1)); // Tue of week 1, 10:00 ET
        _seed(1_000_000e6, 250_000e6);
        ben = _borrower("ben", 1_000e18, 89_900e6); // $100,000 of tTBILL, 89.9 % LTV
        orc.setPrice(TBILL, 96.5e18); // HF = 96,500 × 0.93 / 89,900 = 0.998
    }

    // ───────────── helpers ─────────────

    function _open() internal returns (uint64 id) {
        vm.prank(keeper);
        id = adapter.openSettlement(idTBILL, _one(ben));
    }

    /// @dev F-4.5a with the mock engine's arithmetic: x = (H*·D − q·P·LT) / (H*·R·(1−λ) − P·LT), rounded up.
    function _expectedLot(uint256 debt, uint256 q, uint256 p) internal pure returns (uint256) {
        uint256 r = p * 995 / 1000;
        uint256 lhs = 1.1e18 * (debt * 1e12);
        uint256 rhs = q * (p * 0.93e18) / 1e18;
        uint256 hr = 1.1e18 * r * 0.99e18 / 1e18;
        uint256 pl = p * 0.93e18;
        return ((lhs - rhs) * 1e18 + (hr - pl) - 1) / (hr - pl);
    }

    // ───────────── open ─────────────

    function test_open_sizesAtKappaNav_movesLotToVenue() public {
        uint256 debt = market.debtOf(idTBILL, ben);
        uint256 x = _expectedLot(debt, 1_000e18, 96.5e18);
        uint256 floorPrice = uint256(96.5e18) * 995 / 1000;
        uint256 kb = usdc.balanceOf(keeper);
        vm.expectEmit(true, true, false, true, address(adapter));
        emit ISettlementEvents.SettlementOpened(
            1, idTBILL, address(solver), x, floorPrice, uint40(block.timestamp + 15 minutes)
        );
        uint64 id = _open();
        assertEq(id, 1);
        Settlement memory s = adapter.settlement(id);
        assertEq(uint8(s.status), uint8(SettlementStatus.OPEN));
        assertEq(uint8(s.kind), uint8(AuctionKind.INTRADAY));
        assertEq(s.qty, x);
        assertEq(s.floorPrice, floorPrice);
        assertEq(s.positions, 1);
        assertEq(s.endsAt, block.timestamp + 15 minutes);
        assertEq(fund.balanceOf(address(solver)), x);
        assertEq(fund.balanceOf(address(adapter)), 0);
        assertEq(market.position(idTBILL, ben).collateral, 1_000e18 - x);
        (uint128 q,) = market.lotPosition(id, ben);
        assertEq(q, x);
        // FLAG (forwarded from the market) + OPEN_SETTLEMENT
        assertEq(usdc.balanceOf(keeper) - kb, 2 * TIP);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        SolverLot memory l = solver.lot(id);
        assertEq(l.qty, x);
        assertEq(solver.minBid(id), floorPrice);
    }

    function test_open_nothingEligible_reverts() public {
        orc.setPrice(TBILL, NAV0);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NothingToSettle.selector, idTBILL));
        _open();
    }

    function test_open_rejectsBadInput() public {
        vm.expectRevert(ICredenceErrors.ZeroAmount.selector);
        adapter.openSettlement(idTBILL, new address[](0));
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TooManyPositions.selector, 129, 128));
        adapter.openSettlement(idTBILL, new address[](129));
    }

    function test_open_unknownOrEquityMarket_reverts() public {
        bytes32 bogus = keccak256("nope");
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.MarketNotFound.selector, bogus));
        adapter.openSettlement(bogus, _one(ben));
        // an equity-kind market on the same singleton is not the adapter's business
        MarketParams memory p = _navParams();
        p.collateralToken = address(new MockERC20("x", "x", 18));
        p.kind = MarketKind.EQUITY;
        p.maxLtv = 0.75e18;
        p.lt = 0.8e18;
        vm.prank(timelock);
        bytes32 eq = market.createMarket(p);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.WrongKind.selector, uint8(MarketKind.EQUITY)));
        adapter.openSettlement(eq, _one(ben));
    }

    function test_directFlag_onNavMarket_reverts() public {
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        market.flagForAuction(idTBILL, _one(ben));
    }

    function test_open_whenHalted_reverts_repayStaysOpen() public {
        clk.setState(TBILL, ClockState.HALTED);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICredenceErrors.ActionNotAllowedInState.selector,
                MarketAction.FLAG_FOR_AUCTION,
                ClockState.HALTED
            )
        );
        _open();
        usdc.mint(ben, 1_000e6);
        vm.startPrank(ben);
        usdc.approve(address(market), 1_000e6);
        market.repay(idTBILL, ben, 1_000e6, 0);
        vm.stopPrank();
    }

    function test_open_whenClosedOrCorpAction_reverts() public {
        ClockState[2] memory ss = [ClockState.CLOSED, ClockState.CORP_ACTION];
        for (uint256 i; i < 2; ++i) {
            clk.setState(TBILL, ss[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ICredenceErrors.ActionNotAllowedInState.selector, MarketAction.FLAG_FOR_AUCTION, ss[i]
                )
            );
            _open();
        }
    }

    function test_open_noVenue_reverts() public {
        vm.prank(timelock);
        adapter.setVenues(new address[](0));
        vm.expectRevert(ICredenceErrors.NoVenue.selector);
        _open();
    }

    // ───────────── bidding ─────────────

    function test_bid_rules_andOutbidRefund() public {
        uint64 id = _open();
        Settlement memory s = adapter.settlement(id);
        _fundSolver(solverA, 100_000e6);
        _fundSolver(solverB, 100_000e6);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NotAllowlisted.selector, stranger));
        solver.bid(id, s.floorPrice);
        vm.prank(solverA);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.SolverBidTooLow.selector, s.floorPrice - 1, s.floorPrice)
        );
        solver.bid(id, s.floorPrice - 1);

        vm.prank(solverA);
        solver.bid(id, s.floorPrice);
        uint256 escrowA = _escrow(s.qty, s.floorPrice);
        assertEq(usdc.balanceOf(solverA), 100_000e6 - escrowA);
        uint256 min = (uint256(s.floorPrice) * 10_001 + 9_999) / 10_000;
        assertEq(solver.minBid(id), min);
        vm.prank(solverB);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.SolverBidTooLow.selector, min - 1, min));
        solver.bid(id, min - 1);
        vm.prank(solverB);
        solver.bid(id, min);
        assertEq(usdc.balanceOf(solverA), 100_000e6, "outbid solver refunded at once");
        assertEq(usdc.balanceOf(address(solver)), _escrow(s.qty, min));
        (address best, uint256 price) = solver.best(id);
        assertEq(best, solverB);
        assertEq(price, min);

        vm.warp(s.endsAt);
        vm.prank(solverA);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TooLate.selector, s.endsAt));
        solver.bid(id, min * 2);
    }

    function test_bid_unknownSettlement_andCompliance() public {
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownSettlement.selector, 7));
        solver.bid(7, 1e18);
        uint64 id = _open();
        registry.setAllowed(solverA, false); // allowlisted solver, but it cannot hold the fund
        vm.prank(solverA);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NotAllowlisted.selector, solverA));
        solver.bid(id, 100e18);
    }

    function _escrow(uint256 qty, uint256 price) internal pure returns (uint256) {
        return (qty * price * 1e6 + 1e36 - 1) / 1e36;
    }

    // ───────────── finalize: solver fill ─────────────

    function test_finalize_fill_settlesPosition() public {
        uint64 id = _open();
        Settlement memory s = adapter.settlement(id);
        _fundSolver(solverA, 100_000e6);
        vm.prank(solverA);
        solver.bid(id, s.floorPrice);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TooEarly.selector, s.endsAt));
        adapter.finalize(id);

        vm.warp(s.endsAt);
        uint256 debtBefore = market.debtOf(idTBILL, ben);
        uint256 proceeds = _escrow(s.qty, s.floorPrice);
        uint256 kb = usdc.balanceOf(keeper);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit ISettlementEvents.SettlementFinalized(id, true, solverA, s.floorPrice, proceeds, 0);
        vm.prank(keeper);
        adapter.finalize(id);

        s = adapter.settlement(id);
        assertEq(uint8(s.status), uint8(SettlementStatus.FILLED));
        assertTrue(s.settled);
        assertEq(s.solver, solverA);
        assertEq(s.proceeds, proceeds);
        assertEq(fund.balanceOf(solverA), s.qty);
        assertEq(fund.balanceOf(address(solver)), 0);
        assertEq(usdc.balanceOf(address(solver)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        // F-4.5d partial: debt − (1 − λ) P
        uint256 penalty = proceeds / 100;
        assertApproxEqAbs(market.debtOf(idTBILL, ben), debtBefore - (proceeds - penalty), 2);
        assertGe(market.healthFactor(idTBILL, ben), 1.1e18 - 1e15, "HF back to H* at the floor");
        // SETTLE (forwarded) + FINALIZE_SETTLEMENT
        assertEq(usdc.balanceOf(keeper) - kb, 2 * TIP);
        assertEq(market.position(idTBILL, ben).auctionId, 0);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.SettlementNotOpen.selector, id));
        adapter.finalize(id);
    }

    function test_finalize_unknown_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownSettlement.selector, 9));
        adapter.finalize(9);
    }

    // ───────────── finalize: pool advance and T+1 redemption ─────────────

    function test_finalize_noBid_poolAdvances_thenClaimsAtT1() public {
        uint64 id = _open();
        Settlement memory s = adapter.settlement(id);
        vm.warp(s.endsAt);
        uint256 navBefore = up.nav();
        uint256 cashBefore = usdc.balanceOf(address(up));
        uint256 cost = uint256(s.qty) * s.floorPrice / 1e30;
        vm.expectEmit(true, true, true, true, address(up));
        emit IUnderwriterPoolEvents.RedemptionRequested(0, 1, idTBILL, address(fund), s.qty, cost);
        vm.prank(keeper);
        adapter.finalize(id);

        s = adapter.settlement(id);
        assertEq(uint8(s.status), uint8(SettlementStatus.ADVANCED));
        assertEq(s.requestId, 1);
        assertEq(s.proceeds, cost);
        assertEq(usdc.balanceOf(address(up)), cashBefore - cost + cost / 100 / 3);
        assertEq(up.redemptionClaimsOutstanding(), cost);
        assertEq(fund.pendingRedeemRequest(1, address(up)), s.qty);
        // NAV: cash → claim at cost, plus the pool's penalty third
        assertEq(up.nav(), navBefore + cost / 100 / 3);
        RedemptionClaim memory c = up.redemptionClaim(1);
        assertEq(c.cost, cost);
        assertEq(c.qty, s.qty);

        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.RequestNotClaimable.selector, 1));
        up.claimRedemption(1);

        // T+1: the issuer fulfils at the next session's NAV
        vm.warp(_morning(1, 2));
        vm.startPrank(issuer);
        fund.publishNav(96.5e18);
        uint256 assets = fund.fulfillRedeem(1);
        vm.stopPrank();
        assertEq(assets, uint256(s.qty) * 96.5e18 / 1e30);
        uint256 navMid = up.nav();
        vm.expectEmit(true, true, false, true, address(up));
        emit IUnderwriterPoolEvents.RedemptionClaimed(0, 1, assets, int256(assets) - int256(cost));
        vm.prank(keeper);
        assertEq(up.claimRedemption(1), assets);
        assertEq(up.redemptionClaimsOutstanding(), 0);
        assertEq(up.nav(), navMid + assets - cost, "the 0.5 % discount is earned at the claim");
        assertApproxEqRel(assets - cost, cost * 5 / 995, 1e12);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.RequestAlreadyClaimed.selector, 1));
        up.claimRedemption(1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownRedemption.selector, 2));
        up.claimRedemption(2);
    }

    function test_finalize_noBid_whileGated_revertsUntilUngated() public {
        uint64 id = _open();
        vm.warp(adapter.settlement(id).endsAt);
        vm.prank(issuer);
        fund.setRedemptionsGated(true);
        vm.expectRevert(ICredenceErrors.RedemptionsGated.selector);
        adapter.finalize(id);
        vm.prank(issuer);
        fund.setRedemptionsGated(false);
        adapter.finalize(id);
        assertEq(uint8(adapter.settlement(id).status), uint8(SettlementStatus.ADVANCED));
    }

    function test_finalize_winnerLostAllowlist_fallsBackToPool() public {
        uint64 id = _open();
        Settlement memory s = adapter.settlement(id);
        _fundSolver(solverA, 100_000e6);
        vm.prank(solverA);
        solver.bid(id, s.floorPrice + 1e18);
        registry.setAllowed(solverA, false);
        vm.warp(s.endsAt);
        adapter.finalize(id);
        assertEq(uint8(adapter.settlement(id).status), uint8(SettlementStatus.ADVANCED));
        assertEq(usdc.balanceOf(solverA), 100_000e6, "void bid refunded");
        assertEq(fund.balanceOf(solverA), 0);
    }

    function test_finalize_poolShortOfCash_paysWhatItHas() public {
        uint64 id = _open();
        Settlement memory s = adapter.settlement(id);
        // the pool's free cash drops below qty × floor: an underwriter withdrawal is reserved
        uint256 free = up.freeCash();
        uint256 full = uint256(s.qty) * s.floorPrice / 1e30;
        vm.prank(address(up));
        usdc.transfer(address(0xdead), free - full / 2);
        vm.warp(s.endsAt);
        uint256 debt = market.debtOf(idTBILL, ben);
        adapter.finalize(id);
        s = adapter.settlement(id);
        assertEq(s.proceeds, full / 2);
        assertEq(up.redemptionClaim(s.requestId).cost, full / 2);
        assertLe(uint256(s.price) * s.qty / 1e30, s.proceeds, "p-bar rounds down");
        assertApproxEqAbs(market.debtOf(idTBILL, ben), debt - (full / 2) * 99 / 100, 2);
    }

    // ───────────── REOPEN ─────────────

    function test_reopen_settlementBlocksCompleteReopenUntilFinalized() public {
        clk.setState(TBILL, ClockState.REOPEN);
        clk.setReopen(TBILL, 4, 6, true);
        clk.setOpenPrint(TBILL, 96.5e18, uint40(block.timestamp));
        uint64 id = _open();
        assertEq(uint8(adapter.settlement(id).kind), uint8(AuctionKind.REOPEN));
        assertEq(adapter.settlement(id).closureId, 4);
        assertEq(adapter.openReopenSettlements(TBILL, 4), 1);

        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.TooEarly.selector, uint40(block.timestamp + 120))
        );
        adapter.completeReopen(TBILL);
        vm.warp(block.timestamp + 121);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.ReopenNotOver.selector, TBILL));
        adapter.completeReopen(TBILL);
        // after the queue window no new REOPEN settlement can open (the market's flag rule)
        address dev = _borrower2();
        vm.expectRevert(
            abi.encodeWithSelector(
                ICredenceErrors.ActionNotAllowedInState.selector,
                MarketAction.FLAG_FOR_AUCTION,
                ClockState.REOPEN
            )
        );
        adapter.openSettlement(idTBILL, _one(dev));

        vm.warp(adapter.settlement(id).endsAt);
        adapter.finalize(id);
        assertEq(adapter.openReopenSettlements(TBILL, 4), 0);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit ISettlementEvents.NavReopenCompleted(TBILL, 4);
        adapter.completeReopen(TBILL);
        assertEq(uint8(clk.state(TBILL)), uint8(ClockState.REGULAR));
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.ReopenNotPending.selector, TBILL));
        adapter.completeReopen(TBILL);
    }

    function _borrower2() internal returns (address dev) {
        orc.setPrice(TBILL, NAV0);
        clk.setState(TBILL, ClockState.REGULAR);
        dev = _borrower("dev", 100e18, 8_990e6);
        clk.setState(TBILL, ClockState.REOPEN);
        orc.setPrice(TBILL, 96.5e18);
    }

    function test_completeReopen_equityAsset_revertsWrongKind() public {
        bytes32 nvda = keccak256("NVDA:XNAS");
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.WrongKind.selector, uint8(MarketKind.EQUITY)));
        adapter.completeReopen(nvda);
    }

    // ───────────── access and parameters ─────────────

    function test_access() public {
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        adapter.getOrCreate(AuctionKind.INTRADAY, idTBILL, TBILL, 0);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        adapter.lotSettled(1);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        adapter.nextTranche(1);
        vm.prank(address(market));
        assertEq(adapter.nextTranche(1), 0);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        adapter.setWindow(10 minutes);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        adapter.setVenues(new address[](0));
        vm.startPrank(timelock);
        vm.expectRevert(ICredenceErrors.AlreadyWired.selector);
        adapter.initializeWiring(address(market), address(up), address(tips), new address[](0));
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        adapter.setWindow(4 minutes);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        adapter.setWindow(1 days + 1);
        adapter.setWindow(30 minutes);
        address[] memory bad = new address[](1);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        adapter.setVenues(bad);
        vm.stopPrank();
        assertEq(adapter.window(), 30 minutes);
        assertEq(adapter.kappaNav(), 0.005e18);
        assertEq(adapter.venues()[0], address(solver));
        assertEq(adapter.market(), address(market));
        assertEq(adapter.pool(), address(up));

        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        solver.open(1, address(fund), 1, 1, uint40(block.timestamp + 1));
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        solver.finalize(1);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        solver.setSolver(solverA, false);
        vm.startPrank(timelock);
        vm.expectRevert(ICredenceErrors.AlreadyWired.selector);
        solver.initializeWiring(address(adapter), address(usdc));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        solver.setSolver(address(0), true);
        vm.stopPrank();
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        up.fallbackAdvance(idTBILL, 1, 1);
        vm.expectRevert(ICredenceErrors.NothingToClaim.selector);
        solver.withdrawRefund();
    }

    function test_constructorsAndWiringGuards() public {
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new SettlementAdapter(address(0));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new SolverAuction(address(0));
        SettlementAdapter a2 = new SettlementAdapter(timelock);
        SolverAuction s2 = new SolverAuction(timelock);
        vm.startPrank(timelock);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        a2.initializeWiring(address(0), address(up), address(tips), new address[](0));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        s2.initializeWiring(address(0), address(usdc));
        vm.stopPrank();
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        a2.initializeWiring(address(market), address(up), address(tips), new address[](0));
    }

    function test_venue_openGuards() public {
        vm.startPrank(address(adapter));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        solver.open(50, address(0), 1, 1, uint40(block.timestamp + 1));
        vm.expectRevert(ICredenceErrors.ZeroAmount.selector);
        solver.open(50, address(fund), 0, 1, uint40(block.timestamp + 1));
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        solver.open(50, address(fund), 1, 1, uint40(block.timestamp));
        solver.open(50, address(fund), 1, 1, uint40(block.timestamp + 1));
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        solver.open(50, address(fund), 1, 1, uint40(block.timestamp + 1));
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.TooEarly.selector, uint40(block.timestamp + 1))
        );
        solver.finalize(50);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownSettlement.selector, 51));
        solver.finalize(51);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownSettlement.selector, 51));
        solver.minBid(51);
    }

    function test_poolAdvance_wrongKindAndZero() public {
        vm.startPrank(address(adapter));
        vm.expectRevert(ICredenceErrors.ZeroAmount.selector);
        up.fallbackAdvance(idTBILL, 0, 1e18);
        vm.stopPrank();
    }
}
