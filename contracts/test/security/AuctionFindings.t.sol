// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {Auction, ClockState} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";

/// @title Auction house and backstop-resale findings (QA-sec S4; triage QA-02, QA-03, QA-04).
/// @notice Regression tests of findings fixed by BE-chain in 61761b9 (ADR-0113): each asserts the fixed behaviour.
contract AuctionFindingsTest is RiskFixture {
    address internal alice = makeAddr("alice");
    address internal honest = makeAddr("honest");

    function setUp() public {
        setUpRisk();
        _underwrite(uw1, 500_000e6);
    }

    function _one(address b) internal pure returns (address[] memory bs) {
        bs = new address[](1);
        bs[0] = b;
    }

    function _fund(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(address(house), type(uint256).max);
    }

    /// @dev alice under water at $150 on weekday `d` of week `w` (REGULAR): an INTRADAY lot, fixed.
    function _intraday(uint256 w, uint256 d) internal returns (uint64 id) {
        vm.warp(_openAt(w, d) + 1 hours);
        _day(w, d);
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        orc.setPrice(NVDA, 150e18);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(alice));
        id = market.position(idNVDA, alice).auctionId;
        vm.warp(block.timestamp + 15);
        house.fixLots(id);
    }

    /// @dev 64 attacker accounts try to take every bid slot with a minimum-notional bid far below the reserve ($1 a
    ///      token): since the fix (61761b9) each is refused, so no slot is taken.
    function _fillSlotsBelowReserve(uint64 id) internal {
        for (uint256 i; i < 64; ++i) {
            address g = address(uint160(0xBAD000 + i));
            _fund(g, 100e6);
            vm.prank(g);
            vm.expectRevert(ICredenceErrors.BidBelowReserve.selector);
            house.placeBid(id, 100e18, 1e18); // notional $100 = the testnet minimum
        }
        assertEq(house.auction(id).bidCount, 0);
    }

    // ───────────── QA-02: bid-slot griefing ─────────────

    /// @notice Regression of QA-02 (Medium, fixed 61761b9). A bid that can never fill (below the reserve) must not be able to
    ///         keep a bid that can out of a full auction: reject it at placement, or let a better bid evict the lowest
    ///         one when the book is full.
    function test_QA02_aBidAtTheReserveIsNeverLockedOut() public {
        uint64 id = _intraday(0, 1);
        _fillSlotsBelowReserve(id);
        Auction memory a = house.auction(id);
        _fund(honest, 1_000_000e6);
        vm.prank(honest);
        house.placeBid(id, a.lot, 149e18);
        vm.warp(a.deadlines[3]);
        house.clear(id);
        assertEq(house.auction(id).pStar, 149e18);
    }

    /// @notice Regression of QA-02, sealed variant. A REOPEN commit that reveals below the reserve gets its bond back, so the
    ///         64 commit slots cost the griefer nothing either: its bond should be forfeited like a non-reveal's.
    function test_QA02_revealBelowReserveForfeitsTheBond() public {
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        _closed(1, 2);
        uint40 printAt = _openAt(0, 2);
        vm.warp(printAt + 30);
        _reopen(1, 2, printAt, [uint128(140e18), 200e18, 250e18]);
        orc.setPrice(NVDA, 140e18);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(alice));
        uint64 id = market.position(idNVDA, alice).auctionId;
        vm.warp(printAt + 120);
        house.fixLots(id);
        address griefer = makeAddr("griefer");
        _fund(griefer, 1_000e6);
        bytes32 c = keccak256(
            abi.encode(
                block.chainid, address(house), id, griefer, uint128(100e18), uint128(1e18), bytes32("g")
            )
        );
        vm.prank(griefer);
        house.commitBid(id, c, 100e6); // bond $10
        vm.warp(printAt + 300);
        vm.prank(griefer);
        house.revealBid(id, 100e18, 1e18, bytes32("g"));
        vm.warp(printAt + 420);
        house.clear(id);
        vm.prank(griefer);
        try house.claim(id) {} catch {}
        assertEq(
            usdc.balanceOf(griefer), 1_000e6 - 10e6, "the low-ball's bond is forfeited, like a non-reveal's"
        );
    }

    // ───────────── QA-03: the GDA keeps decaying while the market is shut ─────────────

    /// @dev Friday 10:30 ET: no bidder, the pool backstops alice's lot at R = $145.50 and lists it (k = 1.02 V = $153).
    function _fridayGda() internal returns (uint64 g) {
        uint64 id = _intraday(0, 4);
        vm.warp(house.auction(id).deadlines[3]);
        house.clear(id);
        market.settlePositions(id, _one(alice));
        g = up.resellInventory(NVDA);
    }

    /// @notice Regression of QA-03 (High, fixed 61761b9; PM spec ruling pending). The pool must not sell backstop inventory while the asset's
    ///         market is shut, nor below (1 − κ) × V_live: pause the GDA's clock outside REGULAR (or floor the price).
    function test_QA03_gdaNeverSellsBelowTheReserveWhileShut() public {
        uint64 g = _fridayGda();
        _closed(4, 5);
        vm.warp(_openAt(1, 0) - 30 minutes);
        address buyer = makeAddr("buyer");
        _fund(buyer, 1_000e6);
        vm.prank(buyer);
        try house.gdaBuy(g, 1e18, 1_000e6) returns (uint256 cost) {
            assertGe(cost, 145.5e6, "never below (1 - kappa) x V");
        } catch {
            // refusing to sell while CLOSED is the other acceptable fix
        }
    }

    // ───────────── QA-04: resale listed at a closed-market valuation ─────────────

    /// @notice Regression of QA-04 (Medium, fixed 61761b9). `resellInventory` is permissionless and sets k = 1.02 × V from
    ///         `valuationPrice`, which in CLOSED / HALTED is min(frozen reference, DEX TWAP): a depressed or manipulated
    ///         weekend DEX print sets the whole resale's start price. List only in REGULAR (live cross-checked price).
    function test_QA04_resaleIsNotListedWhileClosed() public {
        uint64 id = _intraday(0, 4);
        vm.warp(house.auction(id).deadlines[3]);
        house.clear(id);
        market.settlePositions(id, _one(alice));
        _closed(4, 5);
        vm.warp(_closeAt(0, 4) + 1 days); // Saturday
        orc.setPrice(NVDA, 75e18); // min(ref, a thin weekend DEX TWAP at half the close)
        vm.expectRevert();
        up.resellInventory(NVDA);
    }
}
