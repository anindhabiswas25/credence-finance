// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {EdgeFixture} from "./EdgeFixture.sol";
import {Auction, AuctionPhase} from "../../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../../src/libraries/Errors.sol";

/// @title Auction house edge cases (matrix rows E-A-*, `docs/qa/edge-cases.md`).
contract AuctionEdgesTest is EdgeFixture {
    address internal b1 = makeAddr("bidder1");
    address internal b2 = makeAddr("bidder2");

    function setUp() public {
        setUpEdge();
        for (uint256 i; i < 2; ++i) {
            address b = [b1, b2][i];
            usdc.mint(b, 1_000_000e6);
            vm.prank(b);
            usdc.approve(address(house), type(uint256).max);
        }
    }

    /// An INTRADAY lot of alice's position, flagged now (its deadlines: fix + 15 s, bids until + 60 s).
    function _intradayLot() internal returns (uint64 id, Auction memory a) {
        vm.warp(_openAt(0, 1) + 1 hours);
        _day(0, 1);
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        orc.setPrice(NVDA, 150e18);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(alice));
        id = market.position(idNVDA, alice).auctionId;
        a = house.auction(id);
    }

    /// E-A-01: a bid sent in the fixing second but ordered before `fixLots` in the block reverts `PhaseClosed(QUEUE)`
    ///         (the bot must retry after the fix); `fixLots` at deadline − 1 s is `TooEarly`.
    function test_E_A01_bidOrderedBeforeFixLotsInTheSameBlock() public {
        (uint64 id, Auction memory a) = _intradayLot();
        vm.warp(a.deadlines[0] - 1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TooEarly.selector, a.deadlines[0]));
        house.fixLots(id);
        vm.warp(a.deadlines[0]);
        vm.prank(b1);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.PhaseClosed.selector, uint8(AuctionPhase.QUEUE))
        );
        house.placeBid(id, 1e18, 150e18);
        house.fixLots(id);
        vm.prank(b1);
        house.placeBid(id, 1e18, 150e18);
    }

    /// E-A-02: bidding closes at deadlines[2]: the last second is accepted, the next is `TooLate`; `clear` before
    ///         deadlines[3] is `TooEarly`, and a second `clear` is `PhaseClosed`.
    function test_E_A02_biddingLastSecondAndClearTwice() public {
        (uint64 id, Auction memory a) = _intradayLot();
        vm.warp(a.deadlines[0]);
        house.fixLots(id);
        vm.warp(a.deadlines[2] - 1);
        vm.prank(b1);
        house.placeBid(id, 1e18, 150e18);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TooEarly.selector, a.deadlines[3]));
        house.clear(id);
        vm.warp(a.deadlines[2]);
        vm.prank(b2);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TooLate.selector, a.deadlines[2]));
        house.placeBid(id, 1e18, 150e18);
        vm.warp(a.deadlines[3]);
        house.clear(id);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.PhaseClosed.selector, uint8(AuctionPhase.CLEARED))
        );
        house.clear(id);
        vm.startPrank(b1);
        house.claim(id);
        vm.expectRevert(ICredenceErrors.NothingToClaim.selector);
        house.claim(id);
        vm.stopPrank();
    }

    /// E-A-03: two bidders at the same price in one block, together over the lot: the fills sum to exactly the lot,
    ///         neither is filled above its quantity, the pool takes nothing, and cash is conserved.
    function test_E_A03_tieAtTheSamePriceOverTheLot() public {
        (uint64 id, Auction memory a) = _intradayLot();
        vm.warp(a.deadlines[0]);
        house.fixLots(id);
        a = house.auction(id);
        uint128 q = uint128(a.lot);
        uint128 each = q * 3 / 4;
        vm.prank(b1);
        house.placeBid(id, each, 149e18);
        vm.prank(b2);
        house.placeBid(id, each, 149e18);
        vm.warp(a.deadlines[3]);
        house.clear(id);
        a = house.auction(id);
        assertEq(a.pStar, 149e18);
        assertEq(a.filled, q, "fills sum to the lot");
        assertEq(a.qPool, 0);
        uint256 f1 = house.bid(id, b1).fill;
        uint256 f2 = house.bid(id, b2).fill;
        assertEq(f1 + f2, q);
        assertLe(f1, each);
        assertLe(f2, each);
        vm.prank(b1);
        house.claim(id);
        vm.prank(b2);
        house.claim(id);
        assertEq(tNVDA.balanceOf(address(house)), 0, "collateral in = out");
        uint256 paid = 2_000_000e6 - usdc.balanceOf(b1) - usdc.balanceOf(b2);
        assertEq(paid, a.proceeds, "cash in = proceeds");
    }

    /// E-A-04: a 1-wei bid rounds up to a notional below the minimum: `BidTooSmall`, no slot taken.
    function test_E_A04_dustBidIsRefused() public {
        (uint64 id, Auction memory a) = _intradayLot();
        vm.warp(a.deadlines[0]);
        house.fixLots(id);
        vm.prank(b1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.BidTooSmall.selector, 1, 100e6));
        house.placeBid(id, 1, 150e18);
        assertEq(house.auction(id).bidCount, 0);
    }

    /// E-A-05: REOPEN where every bidder commits and nobody reveals: every bond goes to the pool, the pool backstops
    ///         the whole lot at R, and a non-revealer's claim is `NothingToClaim`. A reveal at deadlines[3] is late.
    function test_E_A05_reopenNobodyReveals() public {
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        _closed(1, 2);
        uint40 printAt = _openAt(0, 2);
        vm.warp(printAt + 30);
        _reopen(1, 2, printAt, [uint128(140e18), 200e18, 250e18]);
        orc.setPrice(NVDA, 140e18);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(alice));
        uint64 id = market.position(idNVDA, alice).auctionId;
        Auction memory a = house.auction(id);
        vm.warp(a.deadlines[0]);
        house.fixLots(id);
        a = house.auction(id);
        for (uint256 i; i < 2; ++i) {
            address b = [b1, b2][i];
            bytes32 c = keccak256(
                abi.encode(block.chainid, address(house), id, b, a.lot, uint128(139e18), bytes32(i))
            );
            vm.prank(b);
            house.commitBid(id, c, 200_000e6);
        }
        vm.warp(a.deadlines[3]);
        vm.prank(b1);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TooLate.selector, a.deadlines[3]));
        house.revealBid(id, uint128(a.lot), 139e18, bytes32(0));
        uint256 poolBefore = usdc.balanceOf(address(up));
        house.clear(id);
        a = house.auction(id);
        assertEq(a.filled, 0);
        assertEq(a.qPool, a.lot, "the pool backstops everything");
        uint256 backstop = uint256(a.lot) * a.reserve / 1e30;
        assertEq(
            poolBefore + 40_000e6 - backstop, usdc.balanceOf(address(up)), "two 10 % bonds in, backstop out"
        );
        vm.prank(b1);
        vm.expectRevert(ICredenceErrors.NothingToClaim.selector);
        house.claim(id);
    }
}
