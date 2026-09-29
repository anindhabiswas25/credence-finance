// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {Auction, ClockState} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";

/// @title Auction house and backstop-resale findings (QA-sec S4; triage QA-02, QA-03, QA-04).
/// @notice Each `finding` test asserts the behaviour the fix must produce, and runs only with QA_FINDINGS=1 until the
///         fix lands (so an open finding never turns `forge test` red). The companion tests without the modifier pin
///         today's behaviour that the finding relies on, and stay green.
contract AuctionFindingsTest is RiskFixture {
    address internal alice = makeAddr("alice");
    address internal honest = makeAddr("honest");

    modifier finding() {
        if (!vm.envOr("QA_FINDINGS", false)) vm.skip(true);
        _;
    }

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

    /// @dev 64 attacker accounts take every bid slot with a minimum-notional bid far below the reserve ($1 a token).
    function _fillSlotsBelowReserve(uint64 id) internal returns (address[] memory griefers) {
        griefers = new address[](64);
        for (uint256 i; i < 64; ++i) {
            griefers[i] = address(uint160(0xBAD000 + i));
            _fund(griefers[i], 100e6);
            vm.prank(griefers[i]);
            house.placeBid(id, 100e18, 1e18); // notional $100 = the testnet minimum
        }
    }

    // ───────────── QA-02: bid-slot griefing ─────────────

    /// @notice Today: the 64 slots are free to take (every griefer gets its escrow back), and a real bidder at the
    ///         reserve is locked out, so the whole lot goes to the pool at R. Pins the mechanics of QA-02.
    function test_QA02_slotGriefingIsFreeToday() public {
        uint64 id = _intraday(0, 1);
        address[] memory g = _fillSlotsBelowReserve(id);
        Auction memory a = house.auction(id);
        _fund(honest, 1_000_000e6);
        vm.prank(honest);
        vm.expectRevert(ICredenceErrors.TooManyBids.selector);
        house.placeBid(id, a.lot, 149e18);
        vm.warp(a.deadlines[3]);
        house.clear(id);
        assertEq(house.auction(id).qPool, a.lot, "no bid fills: everything to the pool at R");
        for (uint256 i; i < g.length; ++i) {
            vm.prank(g[i]);
            house.claim(id);
            assertEq(usdc.balanceOf(g[i]), 100e6, "the griefer's whole escrow comes back");
        }
    }

    /// @notice FINDING QA-02 (Medium, BE-chain). A bid that can never fill (below the reserve) must not be able to
    ///         keep a bid that can out of a full auction: reject it at placement, or let a better bid evict the lowest
    ///         one when the book is full.
    function test_QA02_aBidAtTheReserveIsNeverLockedOut() public finding {
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

    /// @notice FINDING QA-02, sealed variant. A REOPEN commit that reveals below the reserve gets its bond back, so the
    ///         64 commit slots cost the griefer nothing either: its bond should be forfeited like a non-reveal's.
    function test_QA02_revealBelowReserveForfeitsTheBond() public finding {
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

    /// @notice Today: by Monday 09:00 ET (the market shut since Friday 16:00, so no arbitrage bid all weekend) the
    ///         oldest units cost a fraction of V, and anyone can buy them before the open. Pins QA-03's mechanics.
    function test_QA03_gdaSellsFarBelowValueAcrossAWeekendToday() public {
        uint64 g = _fridayGda();
        _closed(4, 5);
        vm.warp(_openAt(1, 0) - 30 minutes); // Monday 09:00 ET, still CLOSED
        uint256 perToken = house.gdaPrice(g, 1e18);
        emit log_named_decimal_uint("GDA price of the oldest token, Monday 09:00 ET", perToken, 6);
        assertLt(perToken, 30e6, "under 20% of V = $150 after the weekend's decay");
        address buyer = makeAddr("buyer");
        _fund(buyer, perToken);
        vm.prank(buyer);
        house.gdaBuy(g, 1e18, perToken); // no clock check: bought while the market is shut
    }

    /// @notice FINDING QA-03 (Medium, BE-chain + PM spec). The pool must not sell backstop inventory while the asset's
    ///         market is shut, nor below (1 − κ) × V_live: pause the GDA's clock outside REGULAR (or floor the price).
    function test_QA03_gdaNeverSellsBelowTheReserveWhileShut() public finding {
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

    /// @notice FINDING QA-04 (Medium, BE-chain). `resellInventory` is permissionless and sets k = 1.02 × V from
    ///         `valuationPrice`, which in CLOSED / HALTED is min(frozen reference, DEX TWAP): a depressed or manipulated
    ///         weekend DEX print sets the whole resale's start price. List only in REGULAR (live cross-checked price).
    function test_QA04_resaleIsNotListedWhileClosed() public finding {
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

    /// @notice Today's behaviour behind QA-04: the listing goes through on Saturday at k = 1.02 × $75.
    function test_QA04_resaleListsAtTheClosedValuationToday() public {
        uint64 id = _intraday(0, 4);
        vm.warp(house.auction(id).deadlines[3]);
        house.clear(id);
        market.settlePositions(id, _one(alice));
        _closed(4, 5);
        assertEq(uint8(clk.state(NVDA)), uint8(ClockState.CLOSED));
        vm.warp(_closeAt(0, 4) + 1 days);
        orc.setPrice(NVDA, 75e18);
        uint64 g = up.resellInventory(NVDA);
        assertEq(house.gda(g).k, 76.5e18);
    }
}
