// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {
    Auction,
    AuctionKind,
    AuctionPhase,
    Bid,
    Gda,
    Inventory,
    ClockState,
    LotInfo
} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";

/// @notice AuctionHouse (§8.7) with the real market and pool; clearing through the risk-core port of `clear`.
contract AuctionHouseTest is RiskFixture {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address b1 = makeAddr("bidder1");
    address b2 = makeAddr("bidder2");
    address b3 = makeAddr("bidder3");

    function setUp() public {
        setUpRisk();
        _underwrite(uw1, 500_000e6);
        vm.warp(_openAt(0, 1) + 1 hours); // Tue 10:30 ET
        _day(0, 1);
    }

    function _fund(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(address(house), type(uint256).max);
    }

    function _flag(bytes32 id, address b) internal returns (uint64 auctionId) {
        address[] memory bs = new address[](1);
        bs[0] = b;
        vm.prank(keeper);
        market.flagForAuction(id, bs);
        auctionId = market.position(id, b).auctionId;
    }

    function _settle(uint64 auctionId, address b) internal {
        address[] memory bs = new address[](1);
        bs[0] = b;
        market.settlePositions(auctionId, bs);
    }

    function _commit(address who, uint64 id, uint128 qty, uint128 price, uint128 maxNotional, bytes32 salt)
        internal
    {
        bytes32 c = keccak256(abi.encode(block.chainid, address(house), id, who, qty, price, salt));
        vm.prank(who);
        house.commitBid(id, c, maxNotional);
    }

    // ───────────── INTRADAY: open bids, pool backstop, settlement, claims ─────────────

    function test_intradayClearsAtUniformPriceWithBackstop() public {
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        orc.setPrice(NVDA, 150e18); // HF 0.92
        uint64 id = _flag(idNVDA, alice);
        Auction memory a = house.auction(id);
        assertEq(uint8(a.kind), uint8(AuctionKind.INTRADAY));
        assertEq(a.startPrice, 150e18);
        assertEq(a.deadlines[0], block.timestamp + 15);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TooEarly.selector, a.deadlines[0]));
        house.fixLots(id);

        vm.warp(a.deadlines[0]);
        house.fixLots(id);
        a = house.auction(id);
        uint256 q = a.lot;
        assertGt(q, 0);
        assertEq(tNVDA.balanceOf(address(house)), q);
        assertEq(a.reserve, 145.5e18); // (1 − 3%) × 150
        assertEq(uint8(a.phase), uint8(AuctionPhase.OPEN_BIDDING));

        // b1 wants 40% of the lot at $148, b2 wants 30% at $146, b3 bids below the reserve
        _fund(b1, 1_000_000e6);
        _fund(b2, 1_000_000e6);
        _fund(b3, 1_000_000e6);
        uint128 q1 = uint128(q * 40 / 100);
        uint128 q2 = uint128(q * 30 / 100);
        vm.prank(b1);
        house.placeBid(id, q1, 148e18);
        vm.prank(b2);
        house.placeBid(id, q2, 146e18);
        vm.prank(b3);
        house.placeBid(id, uint128(q), 140e18);
        vm.prank(b1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.AlreadyBid.selector, id, b1));
        house.placeBid(id, 1e18, 150e18);

        vm.warp(a.deadlines[3]);
        uint256 poolCashBefore = usdc.balanceOf(address(up));
        house.clear(id);
        a = house.auction(id);
        assertEq(uint8(a.phase), uint8(AuctionPhase.CLEARED));
        assertEq(a.pStar, 146e18, "p* = the last bid needed");
        assertEq(a.filled, q1 + q2);
        assertEq(a.qPool, q - q1 - q2);
        // INV-AH-01: cash in = fills × p* (rounded up per bidder) + what the pool paid = proceeds
        uint256 pay1 = (uint256(q1) * 146e18 + 1e30 - 1) / 1e30;
        uint256 pay2 = (uint256(q2) * 146e18 + 1e30 - 1) / 1e30;
        uint256 poolPaid = poolCashBefore - usdc.balanceOf(address(up));
        assertEq(poolPaid, uint256(a.qPool) * 145.5e18 / 1e30);
        assertEq(a.proceeds, pay1 + pay2 + poolPaid);
        Inventory memory inv = up.inventory(NVDA);
        assertEq(inv.qty, a.qPool);
        assertEq(inv.cost, poolPaid);
        assertEq(tNVDA.balanceOf(address(up)), a.qPool);
        // the market holds the proceeds; the position settles
        LotInfo memory li = market.lotInfo(id);
        assertEq(li.proceeds, a.proceeds);
        _settle(id, alice);
        assertTrue(house.auction(id).settled);
        assertTrue(house.allReopenLotsSettled(VENUE, 0));

        // claims: INV-AH-02 every winner pays p*; the low bidder gets everything back
        vm.prank(b1);
        house.claim(id);
        assertEq(tNVDA.balanceOf(b1), q1);
        assertEq(usdc.balanceOf(b1), 1_000_000e6 - pay1);
        vm.prank(b2);
        house.claim(id);
        assertEq(usdc.balanceOf(b2), 1_000_000e6 - pay2);
        vm.prank(b3);
        house.claim(id);
        assertEq(usdc.balanceOf(b3), 1_000_000e6);
        assertEq(tNVDA.balanceOf(b3), 0);
        vm.prank(b3);
        vm.expectRevert(ICredenceErrors.NothingToClaim.selector);
        house.claim(id);
        // INV-AH-04: collateral in = collateral out
        assertEq(tNVDA.balanceOf(address(house)), 0);
    }

    // ───────────── REOPEN: sealed commit–reveal, bonds, completion ─────────────

    function test_reopenSealedAuction() public {
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        // Tuesday's closure: NVDA opens Wednesday at $140 (HF < 1 at the open print)
        _closed(1, 2);
        uint40 printAt = _openAt(0, 2);
        vm.warp(printAt + 30);
        _reopen(1, 2, printAt, [uint128(140e18), 200e18, 250e18]);
        orc.setPrice(NVDA, 140e18);
        uint64 id = _flag(idNVDA, alice);
        Auction memory a = house.auction(id);
        assertEq(uint8(a.kind), uint8(AuctionKind.REOPEN));
        assertEq(a.venueEpoch, 1);
        assertEq(a.deadlines[0], printAt + 120);
        assertEq(a.deadlines[3], printAt + 420);
        assertFalse(house.allReopenLotsSettled(VENUE, 1));
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.ReopenNotOver.selector, NVDA));
        vm.warp(printAt + 121);
        house.completeReopen(NVDA);

        house.fixLots(id);
        a = house.auction(id);
        uint128 q = a.lot;
        assertEq(a.reserve, 135.8e18); // (1 − 3%) × P°
        _fund(b1, 1_000_000e6);
        _fund(b2, 1_000_000e6);
        _fund(b3, 1_000_000e6);
        // honest bidder (whole lot at $139), low-ball (below R), non-revealer
        _commit(b1, id, q, 139e18, 200_000e6, "s1");
        _commit(b2, id, q, 100e18, 200_000e6, "s2");
        _commit(b3, id, q, 150e18, 200_000e6, "s3");
        assertEq(usdc.balanceOf(address(house)), 60_000e6, "3 bonds of 10%");
        vm.prank(b1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TooEarly.selector, a.deadlines[2]));
        house.revealBid(id, q, 139e18, "s1");

        vm.warp(a.deadlines[2]);
        vm.prank(b1);
        vm.expectRevert(ICredenceErrors.BadReveal.selector);
        house.revealBid(id, q, 138e18, "s1");
        vm.prank(b1);
        house.revealBid(id, q, 139e18, "s1");
        vm.prank(b2);
        house.revealBid(id, q, 100e18, "s2");
        Bid memory bid1 = house.bid(id, b1);
        assertTrue(bid1.revealed);
        assertEq(bid1.escrow, (uint256(q) * 139e18 + 1e30 - 1) / 1e30);

        vm.warp(a.deadlines[3]);
        uint256 poolBefore = usdc.balanceOf(address(up));
        house.clear(id);
        a = house.auction(id);
        assertEq(a.pStar, 139e18);
        assertEq(a.filled, q);
        assertEq(a.qPool, 0);
        // the non-revealer's bond went to the pool; the REOPEN is over (last tranche, queue window passed)
        assertEq(usdc.balanceOf(address(up)) - poolBefore, 20_000e6);
        assertFalse(_clockData(NVDA).reopenPending);
        assertEq(clk.reopenCompletions(), 1);
        vm.prank(b3);
        vm.expectRevert(ICredenceErrors.NothingToClaim.selector);
        house.claim(id);
        vm.prank(b2);
        house.claim(id);
        assertEq(usdc.balanceOf(b2), 1_000_000e6, "low-ball: bond refunded");
        _settle(id, alice);
        assertTrue(house.allReopenLotsSettled(VENUE, 1));
        assertTrue(house.reopenSettled(NVDA, 2));
    }

    function test_completeReopenWithoutAuctions() public {
        _closed(1, 2);
        uint40 printAt = _openAt(0, 2);
        vm.warp(printAt + 10);
        _reopen(1, 2, printAt, [uint128(180e18), 200e18, 250e18]);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TooEarly.selector, printAt + 120));
        house.completeReopen(NVDA);
        vm.warp(printAt + 120);
        house.completeReopen(NVDA);
        assertFalse(_clockData(NVDA).reopenPending);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.ReopenNotPending.selector, NVDA));
        house.completeReopen(NVDA);
    }

    // ───────────── empty and cancelled lots ─────────────

    function test_emptyLotCountsAsSettled() public {
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        orc.setPrice(NVDA, 150e18);
        uint64 id = _flag(idNVDA, alice);
        orc.setPrice(NVDA, 180e18); // cured before the lot is fixed
        vm.warp(block.timestamp + 15);
        house.fixLots(id);
        Auction memory a = house.auction(id);
        assertEq(a.lot, 0);
        assertEq(uint8(a.phase), uint8(AuctionPhase.CLEARED));
        assertTrue(a.settled);
        assertEq(market.position(idNVDA, alice).auctionId, 0);
    }

    function test_lotThatCanNoLongerBeFixedIsCancelled() public {
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        orc.setPrice(NVDA, 150e18);
        uint64 id = _flag(idNVDA, alice);
        clk.setState(NVDA, ClockState.EXTENDED); // the keeper was late: the close came first
        vm.warp(block.timestamp + 15);
        house.fixLots(id);
        Auction memory a = house.auction(id);
        assertEq(uint8(a.phase), uint8(AuctionPhase.CANCELLED));
        assertTrue(a.settled);
        assertEq(market.position(idNVDA, alice).auctionId, 0, "the position is free again");
        assertEq(market.position(idNVDA, alice).collateral, 1_000e18);
    }

    // ───────────── bidding rules ─────────────

    function test_bidRules() public {
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        orc.setPrice(NVDA, 150e18);
        uint64 id = _flag(idNVDA, alice);
        _fund(b1, 1_000_000e6);
        vm.prank(b1);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.PhaseClosed.selector, uint8(AuctionPhase.QUEUE))
        );
        house.placeBid(id, 1e18, 150e18);
        vm.warp(block.timestamp + 15);
        house.fixLots(id);
        vm.prank(b1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.BidTooSmall.selector, 75e6, 100e6));
        house.placeBid(id, 0.5e18, 150e18);
        vm.prank(b1);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.WrongKind.selector, uint8(AuctionKind.INTRADAY))
        );
        house.commitBid(id, bytes32(uint256(1)), 1_000e6);
        vm.prank(b1);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.WrongKind.selector, uint8(AuctionKind.INTRADAY))
        );
        house.revealBid(id, 1, 1, "");
        // 64 bids at most
        for (uint256 i; i < 64; ++i) {
            address x = address(uint160(0x1000 + i));
            _fund(x, 200e6);
            vm.prank(x);
            house.placeBid(id, 1e18, 150e18);
        }
        vm.prank(b1);
        vm.expectRevert(ICredenceErrors.TooManyBids.selector);
        house.placeBid(id, 1e18, 150e18);
        vm.warp(block.timestamp + 45);
        vm.prank(b1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TooLate.selector, uint40(block.timestamp)));
        house.placeBid(id, 1e18, 150e18);
        house.clear(id); // 64 bids clear within the gas bound
        assertEq(house.auction(id).bidCount, 64);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.UnknownAuction.selector, 999));
        house.clear(999);
    }

    function test_sealedRevealRules() public {
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        _closed(1, 2);
        uint40 printAt = _openAt(0, 2);
        vm.warp(printAt + 30);
        _reopen(1, 2, printAt, [uint128(140e18), 200e18, 250e18]);
        orc.setPrice(NVDA, 140e18);
        uint64 id = _flag(idNVDA, alice);
        vm.warp(printAt + 120);
        house.fixLots(id);
        _fund(b1, 1_000_000e6);
        vm.prank(b1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.BidTooSmall.selector, 50e6, 100e6));
        house.commitBid(id, bytes32(uint256(1)), 50e6);
        _commit(b1, id, 100e18, 139e18, 10_000e6, "x"); // declares $10k but bids $13.9k
        vm.prank(b1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.AlreadyBid.selector, id, b1));
        house.commitBid(id, bytes32(uint256(2)), 1_000e6);
        vm.warp(printAt + 300);
        vm.prank(b1);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.RevealAboveMaxNotional.selector, 13_900e6, 10_000e6)
        );
        house.revealBid(id, 100e18, 139e18, "x");
        vm.prank(b2);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NoBid.selector, id, b2));
        house.revealBid(id, 1, 1, "");
    }

    // ───────────── GDA resale of the backstop inventory ─────────────

    function test_gdaResale() public {
        test_intradayClearsAtUniformPriceWithBackstop();
        Inventory memory inv = up.inventory(NVDA);
        uint256 navBefore = up.nav();
        uint64 g = up.resellInventory(NVDA);
        Gda memory gd = house.gda(g);
        assertEq(gd.qty, inv.qty);
        assertEq(gd.k, 150e18 * 102 / 100);
        assertEq(up.nav(), navBefore, "listing moves no value");
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.GdaRunning.selector, g));
        up.resellInventory(NVDA);
        // nothing emitted yet at t = 0
        vm.expectPartialRevert(ICredenceErrors.GdaInsufficient.selector);
        house.gdaPrice(g, 1e18);
        vm.warp(block.timestamp + 1 days);
        uint256 q = gd.qty / 4;
        uint256 cost = house.gdaPrice(g, q);
        // after 24 h the oldest units cost about half of k: the price of q lies between k/2·q and k·q
        assertGt(cost, q * 153e18 / 2 / 1e30);
        assertLt(cost, q * 153e18 / 1e30);
        _fund(b1, 1_000_000e6);
        vm.prank(b1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.CostAboveMax.selector, cost, cost - 1));
        house.gdaBuy(g, q, cost - 1);
        uint256 poolCash = usdc.balanceOf(address(up));
        vm.prank(b1);
        house.gdaBuy(g, q, cost);
        assertEq(usdc.balanceOf(address(up)) - poolCash, cost);
        assertEq(up.inventory(NVDA).qty, inv.qty - q);
        // the rest comes back when the pool closes the resale after its emission period
        vm.expectPartialRevert(ICredenceErrors.TooEarly.selector);
        up.closeResale(NVDA);
        vm.warp(block.timestamp + 3 days);
        up.closeResale(NVDA);
        assertEq(up.inventory(NVDA).inGda, 0);
        assertEq(tNVDA.balanceOf(address(up)), inv.qty - q);
        assertFalse(house.gda(g).active);
    }

    function test_governance() public {
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        house.setLimits(10, 1, 1);
        vm.startPrank(timelock);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        house.setLimits(65, 1, 1);
        house.setLimits(32, 1_000e6, 500);
        assertEq(house.maxBids(), 32);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        house.setTimings(AuctionKind.INTRADAY, [uint40(20), 10, 60, 60]);
        house.setTimings(AuctionKind.INTRADAY, [uint40(10), 10, 30, 30]);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        house.setTimings(AuctionKind.PRECLOSE, [uint40(30), 300, 30, 30]);
        vm.expectRevert(ICredenceErrors.AlreadyWired.selector);
        house.initializeWiring(address(market), address(up), address(clk), address(tips), VENUE, 1);
        vm.stopPrank();
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        house.startGda(NVDA, address(tNVDA), 1, 1, 1, 1);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        house.lotSettled(1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.WrongVenue.selector, bytes32("USBANK")));
        house.allReopenLotsSettled(bytes32("USBANK"), 0);
    }
}
