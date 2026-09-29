// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SecurityFixture} from "./SecurityFixture.sol";
import {Reenterer} from "./mocks/Reenterer.sol";
import {AccountingProbe} from "./mocks/AccountingProbe.sol";
import {Auction} from "../../src/libraries/Types.sol";
import {CredenceMarket} from "../../src/core/CredenceMarket.sol";
import {SeniorVault} from "../../src/core/SeniorVault.sol";
import {UnderwriterPool} from "../../src/pool/UnderwriterPool.sol";
import {AuctionHouse} from "../../src/auction/AuctionHouse.sol";

/// @title Reentrancy suite (Build Guide §15.1 "reentrancy via the collateral token hook"; QA-sec S4 item B).
/// @notice USDC and tNVDA carry ERC-777-style hooks (HookToken). For every money function, an attacker account that
///         sends or receives a token in it re-enters the protocol from its hook and must hit a reentrancy guard.
///         The cross-contract section re-enters a *different* contract (per-contract guards do not stop that) and
///         checks that the state it can read or act on mid-transfer is already final (AccountingProbe).
///         Functions that never move a token to or from an account the caller controls are listed in
///         docs/security/reentrancy.md with the reason, instead of a test.
contract ReentrancyTest is SecurityFixture {
    Reenterer.Side internal constant SEND = Reenterer.Side.SEND;
    Reenterer.Side internal constant RECV = Reenterer.Side.RECEIVE;

    address internal alice = makeAddr("alice");
    AccountingProbe internal probe;

    function setUp() public {
        setUpSecurity();
        _underwrite(uw1, 500_000e6);
        probe = new AccountingProbe(market, vault, up, idNVDA);
    }

    // ───────────── helpers ─────────────

    function _borrower(uint256 q, uint256 debt) internal returns (Reenterer r) {
        r = _attacker();
        tNVDA.mint(address(r), q);
        r.exec(address(market), abi.encodeCall(CredenceMarket.addCollateral, (idNVDA, address(r), q)));
        if (debt != 0) {
            r.exec(address(market), abi.encodeCall(CredenceMarket.borrow, (idNVDA, debt, address(r))));
        }
    }

    function _one(address b) internal pure returns (address[] memory bs) {
        bs = new address[](1);
        bs[0] = b;
    }

    /// @dev alice (an EOA) under water at $150 in REGULAR on Tuesday: an INTRADAY auction with its lot fixed.
    function _intraday() internal returns (uint64 id) {
        vm.warp(_openAt(0, 1) + 1 hours);
        _day(0, 1);
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        orc.setPrice(NVDA, 150e18);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(alice));
        id = market.position(idNVDA, alice).auctionId;
        vm.warp(block.timestamp + 15);
        house.fixLots(id);
    }

    /// @dev alice under water at the Wednesday open print ($140): a REOPEN auction with its lot fixed (commit phase).
    function _reopenAuction() internal returns (uint64 id, uint40 printAt) {
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        _closed(1, 2);
        printAt = _openAt(0, 2);
        vm.warp(printAt + 30);
        _reopen(1, 2, printAt, [uint128(140e18), 200e18, 250e18]);
        orc.setPrice(NVDA, 140e18);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(alice));
        id = market.position(idNVDA, alice).auctionId;
        vm.warp(printAt + 120);
        house.fixLots(id);
    }

    function _snap() internal view returns (AccountingProbe.Snap memory) {
        return probe.snap();
    }

    function _decodeSnap(bytes memory ret) internal pure returns (AccountingProbe.Snap memory) {
        return abi.decode(ret, (AccountingProbe.Snap));
    }

    function _assertSameSnap(AccountingProbe.Snap memory a, AccountingProbe.Snap memory b) internal pure {
        assertEq(a.vaultAssets, b.vaultAssets, "vault totalAssets mid-transfer");
        assertEq(a.vaultSupply, b.vaultSupply, "vault supply mid-transfer");
        assertEq(a.poolNav, b.poolNav, "pool NAV mid-transfer");
        assertEq(a.poolSupply, b.poolSupply, "pool supply mid-transfer");
        assertEq(a.poolFreeCash, b.poolFreeCash, "pool free cash mid-transfer");
        assertEq(a.marketLiquidity, b.marketLiquidity, "market liquidity mid-transfer");
        assertEq(a.marketBorrows, b.marketBorrows, "market borrows mid-transfer");
    }

    // ═════════════════════════════ CredenceMarket ═════════════════════════════

    function test_market_addCollateral() public {
        Reenterer r = _borrower(1_000e18, 0);
        tNVDA.mint(address(r), 10e18);
        r.arm(
            address(tNVDA),
            SEND,
            address(market),
            abi.encodeCall(CredenceMarket.withdrawCollateral, (idNVDA, 1_000e18, address(r)))
        );
        r.exec(address(market), abi.encodeCall(CredenceMarket.addCollateral, (idNVDA, address(r), 10e18)));
        _assertGuarded(r, 0);
        assertEq(market.position(idNVDA, address(r)).collateral, 1_010e18);
    }

    function test_market_withdrawCollateral() public {
        Reenterer r = _borrower(1_000e18, 0);
        r.arm(
            address(tNVDA),
            RECV,
            address(market),
            abi.encodeCall(CredenceMarket.withdrawCollateral, (idNVDA, 500e18, address(r)))
        );
        r.exec(
            address(market), abi.encodeCall(CredenceMarket.withdrawCollateral, (idNVDA, 500e18, address(r)))
        );
        _assertGuarded(r, 0);
        assertEq(market.position(idNVDA, address(r)).collateral, 500e18, "withdrawn once");
        assertEq(tNVDA.balanceOf(address(r)), 500e18);
    }

    function test_market_borrow() public {
        Reenterer r = _borrower(1_000e18, 0);
        r.arm(
            address(usdc),
            RECV,
            address(market),
            abi.encodeCall(CredenceMarket.borrow, (idNVDA, 10_000e6, address(r)))
        );
        r.exec(address(market), abi.encodeCall(CredenceMarket.borrow, (idNVDA, 50_000e6, address(r))));
        _assertGuarded(r, 0);
        assertEq(usdc.balanceOf(address(r)), 50_000e6, "borrowed once");
    }

    function test_market_repay() public {
        Reenterer r = _borrower(1_000e18, 50_000e6);
        r.arm(
            address(usdc),
            SEND,
            address(market),
            abi.encodeCall(CredenceMarket.withdrawCollateral, (idNVDA, 900e18, address(r)))
        );
        r.exec(address(market), abi.encodeCall(CredenceMarket.repay, (idNVDA, address(r), 10_000e6, 0)));
        _assertGuarded(r, 0);
        assertEq(market.position(idNVDA, address(r)).collateral, 1_000e18);
    }

    function test_market_buyCoverFromWallet() public {
        Reenterer r = _borrower(1_000e18, 130_000e6);
        engine.setQuote(250e6, 0, 0);
        vm.warp(_closeAt(0, 0) - 1 hours); // Bell window
        r.arm(
            address(usdc),
            SEND,
            address(market),
            abi.encodeCall(CredenceMarket.borrow, (idNVDA, 1e6, address(r)))
        );
        r.exec(address(market), abi.encodeCall(CredenceMarket.buyCover, (idNVDA, 250e6, false)));
        _assertGuarded(r, 0);
        assertEq(market.position(idNVDA, address(r)).coverClosureId, 1);
    }

    function test_market_borrowWithCover() public {
        Reenterer r = _borrower(1_000e18, 0);
        engine.setQuote(250e6, 0, 0);
        vm.warp(_closeAt(0, 0) - 1 hours);
        r.arm(
            address(usdc),
            RECV,
            address(market),
            abi.encodeCall(CredenceMarket.repay, (idNVDA, address(r), 1e6, 0))
        );
        r.exec(
            address(market),
            abi.encodeCall(CredenceMarket.borrowWithCover, (idNVDA, 100_000e6, address(r), 250e6))
        );
        _assertGuarded(r, 0);
        assertEq(market.position(idNVDA, address(r)).coverClosureId, 1);
    }

    /// @dev The keeper's tip is a transfer to the caller: a hooked loan token hands every keeper job to the keeper
    ///      mid-loop. enforceBell (auto-cover through the pool) must stay locked.
    function test_market_enforceBell_viaKeeperTip() public {
        _position(alice, idTSLA, tTSLA, 100e18, 18_000e6);
        engine.setSafeLtv(TSLA, 1, 0.6e18); // 72% needs action at the Bell
        vm.warp(_closeAt(0, 0) - 10 minutes);
        Reenterer k = _attacker();
        k.arm(
            address(usdc),
            RECV,
            address(market),
            abi.encodeCall(CredenceMarket.enforceBell, (idTSLA, _one(alice)))
        );
        k.exec(address(market), abi.encodeCall(CredenceMarket.enforceBell, (idTSLA, _one(alice))));
        _assertGuarded(k, 0);
        assertEq(market.position(idTSLA, alice).coverClosureId, 1, "auto-covered once");
    }

    function test_market_flagForAuction_viaKeeperTip() public {
        vm.warp(_openAt(0, 1) + 1 hours);
        _day(0, 1);
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        orc.setPrice(NVDA, 150e18);
        Reenterer k = _attacker();
        k.arm(
            address(usdc),
            RECV,
            address(market),
            abi.encodeCall(CredenceMarket.withdrawCollateral, (idNVDA, 1e18, address(k)))
        );
        k.exec(address(market), abi.encodeCall(CredenceMarket.flagForAuction, (idNVDA, _one(alice))));
        _assertGuarded(k, 0);
        assertGt(market.position(idNVDA, alice).auctionId, 0);
    }

    function test_market_settlePositions_viaKeeperTip() public {
        uint64 id = _intraday();
        vm.warp(house.auction(id).deadlines[3]);
        house.clear(id);
        Reenterer k = _attacker();
        k.arm(
            address(usdc),
            RECV,
            address(market),
            abi.encodeCall(CredenceMarket.settlePositions, (id, _one(alice)))
        );
        k.exec(address(market), abi.encodeCall(CredenceMarket.settlePositions, (id, _one(alice))));
        _assertGuarded(k, 0);
        assertEq(market.lotInfo(id).settledCount, 1);
    }

    /// @dev A borrower whose position is sold in full above its debt gets the refund pushed to it (F-4.5d): the
    ///      refund hook re-enters the settlement.
    function test_market_settlePositions_viaBorrowerRefund() public {
        vm.warp(_openAt(0, 1) + 1 hours);
        _day(0, 1);
        Reenterer r = _borrower(100e18, 13_400e6); // 74.4% of $18k at $180
        orc.setPrice(NVDA, 140e18); // HF = 11,200 / 13,400: the lot is the whole position
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(address(r)));
        uint64 id = market.position(idNVDA, address(r)).auctionId;
        vm.warp(block.timestamp + 15);
        house.fixLots(id);
        Auction memory a = house.auction(id);
        // a bidder takes the whole lot well above the debt, so a full close refunds the borrower
        address bidder = makeAddr("bidder");
        usdc.mint(bidder, 1_000_000e6);
        vm.startPrank(bidder);
        usdc.approve(address(house), type(uint256).max);
        house.placeBid(id, a.lot, 140e18);
        vm.stopPrank();
        vm.warp(a.deadlines[3]);
        house.clear(id);
        r.arm(
            address(usdc),
            RECV,
            address(market),
            abi.encodeCall(CredenceMarket.settlePositions, (id, _one(address(r))))
        );
        market.settlePositions(id, _one(address(r)));
        _assertGuarded(r, 0);
        assertEq(market.position(idNVDA, address(r)).collateral, 0, "full close");
        assertGt(usdc.balanceOf(address(r)), 13_400e6, "refunded once");
        assertEq(market.lotInfo(id).settledCount, 1);
    }

    function test_market_claimFees_isLockedDuringASettlement() public {
        uint64 id = _intraday();
        vm.warp(house.auction(id).deadlines[3]);
        house.clear(id);
        Reenterer k = _attacker();
        k.arm(address(usdc), RECV, address(market), abi.encodeCall(CredenceMarket.claimFees, (idNVDA)));
        k.exec(address(market), abi.encodeCall(CredenceMarket.settlePositions, (id, _one(alice))));
        _assertGuarded(k, 0);
    }

    // ═════════════════════════════ SeniorVault ═════════════════════════════

    function test_vault_deposit() public {
        Reenterer r = _attacker();
        usdc.mint(address(r), 20_000e6);
        r.exec(address(vault), abi.encodeWithSignature("deposit(uint256,address)", 10_000e6, address(r)));
        r.arm(
            address(usdc),
            SEND,
            address(vault),
            abi.encodeWithSignature("withdraw(uint256,address,address)", 5_000e6, address(r), address(r))
        );
        r.exec(address(vault), abi.encodeWithSignature("deposit(uint256,address)", 10_000e6, address(r)));
        _assertGuarded(r, 0);
        assertEq(usdc.balanceOf(address(r)), 0);
    }

    function test_vault_withdraw() public {
        Reenterer r = _attacker();
        usdc.mint(address(r), 20_000e6);
        r.exec(address(vault), abi.encodeWithSignature("deposit(uint256,address)", 20_000e6, address(r)));
        r.arm(
            address(usdc),
            RECV,
            address(vault),
            abi.encodeWithSignature("withdraw(uint256,address,address)", 5_000e6, address(r), address(r))
        );
        r.exec(
            address(vault),
            abi.encodeWithSignature("withdraw(uint256,address,address)", 5_000e6, address(r), address(r))
        );
        _assertGuarded(r, 0);
        assertEq(usdc.balanceOf(address(r)), 5_000e6, "withdrawn once");
    }

    function test_vault_redeem() public {
        Reenterer r = _attacker();
        usdc.mint(address(r), 20_000e6);
        r.exec(address(vault), abi.encodeWithSignature("deposit(uint256,address)", 20_000e6, address(r)));
        uint256 half = vault.balanceOf(address(r)) / 2;
        r.arm(
            address(usdc),
            RECV,
            address(vault),
            abi.encodeWithSignature("redeem(uint256,address,address)", half, address(r), address(r))
        );
        r.exec(
            address(vault),
            abi.encodeWithSignature("redeem(uint256,address,address)", half, address(r), address(r))
        );
        _assertGuarded(r, 0);
        assertEq(vault.balanceOf(address(r)), half);
    }

    function test_vault_redeemQueueClaim() public {
        Reenterer r = _attacker();
        usdc.mint(address(r), 20_000e6);
        r.exec(address(vault), abi.encodeWithSignature("deposit(uint256,address)", 20_000e6, address(r)));
        uint256 shares = vault.balanceOf(address(r));
        bytes memory ret =
            r.exec(address(vault), abi.encodeCall(SeniorVault.requestRedeem, (shares, address(r))));
        uint256 requestId = abi.decode(ret, (uint256));
        vault.processQueue(10);
        r.arm(address(usdc), RECV, address(vault), abi.encodeCall(SeniorVault.claimRedeem, (requestId)));
        r.exec(address(vault), abi.encodeCall(SeniorVault.claimRedeem, (requestId)));
        _assertGuarded(r, 0);
        assertApproxEqAbs(usdc.balanceOf(address(r)), 20_000e6, 1, "paid once");
    }

    // ═════════════════════════════ UnderwriterPool ═════════════════════════════

    function test_pool_deposit() public {
        Reenterer r = _attacker();
        usdc.mint(address(r), 10_000e6);
        r.arm(address(usdc), SEND, address(up), abi.encodeCall(UnderwriterPool.deposit, (1e6, address(r))));
        r.exec(address(up), abi.encodeCall(UnderwriterPool.deposit, (10_000e6, address(r))));
        _assertGuarded(r, 0);
    }

    function test_pool_claimWithdraw() public {
        Reenterer r = _attacker();
        usdc.mint(address(r), 10_000e6);
        r.exec(address(up), abi.encodeCall(UnderwriterPool.deposit, (10_000e6, address(r))));
        uint256 shares = up.balanceOf(address(r));
        r.exec(address(up), abi.encodeCall(UnderwriterPool.requestWithdraw, (shares))); // epoch 0
        vm.warp(_openAt(0, 1) + 10 minutes);
        up.settleEpoch(0);
        r.arm(address(usdc), RECV, address(up), abi.encodeCall(UnderwriterPool.claimWithdraw, (0)));
        r.exec(address(up), abi.encodeCall(UnderwriterPool.claimWithdraw, (0)));
        _assertGuarded(r, 0);
        assertApproxEqAbs(usdc.balanceOf(address(r)), 10_000e6, 1, "paid once");
    }

    function test_pool_epochLifecycle_viaKeeperTip() public {
        vm.warp(_closeAt(0, 0) - 1 hours);
        Reenterer k = _attacker();
        k.arm(address(usdc), RECV, address(up), abi.encodeCall(UnderwriterPool.snapshotEpoch, (0)));
        k.exec(address(up), abi.encodeCall(UnderwriterPool.openEpoch, (VENUE)));
        _assertGuarded(k, 0);
        vm.warp(_closeAt(0, 0) - 10 minutes);
        k.arm(address(usdc), RECV, address(up), abi.encodeCall(UnderwriterPool.openEpoch, (VENUE)));
        k.exec(address(up), abi.encodeCall(UnderwriterPool.snapshotEpoch, (0)));
        _assertGuarded(k, 1);
        _closed(0, 1);
        vm.warp(_openAt(0, 1) + 10 minutes);
        k.arm(address(usdc), RECV, address(up), abi.encodeCall(UnderwriterPool.releaseLossReserve, (0, NVDA)));
        k.exec(address(up), abi.encodeCall(UnderwriterPool.settleEpoch, (0)));
        _assertGuarded(k, 2);
    }

    /// @dev The backstop (clear → backstopBuy) and the GDA listing: a keeper that clears and lists re-enters.
    function test_pool_backstopAndResale_viaKeeperTip() public {
        uint64 id = _intraday();
        vm.warp(house.auction(id).deadlines[3]);
        Reenterer k = _attacker();
        k.arm(address(usdc), RECV, address(up), abi.encodeCall(UnderwriterPool.resellInventory, (NVDA)));
        k.exec(address(house), abi.encodeCall(AuctionHouse.clear, (id))); // no bids: the pool backstops the lot
        _assertRan(k, 0); // the pool is not locked by the auction house: listing after the backstop is final is fine
        assertGt(up.inventory(NVDA).inGda, 0);
        k.arm(address(usdc), RECV, address(up), abi.encodeCall(UnderwriterPool.closeResale, (NVDA)));
        vm.warp(block.timestamp + 3 days);
        k.exec(address(up), abi.encodeCall(UnderwriterPool.closeResale, (NVDA))); // no tip here: nothing fires
        k.exec(address(up), abi.encodeCall(UnderwriterPool.resellInventory, (NVDA)));
        _assertGuarded(k, 1);
    }

    // ═════════════════════════════ AuctionHouse ═════════════════════════════

    function test_auction_placeBid() public {
        uint64 id = _intraday();
        Reenterer r = _attacker();
        usdc.mint(address(r), 1_000_000e6);
        r.arm(address(usdc), SEND, address(house), abi.encodeCall(AuctionHouse.placeBid, (id, 1e18, 150e18)));
        r.exec(address(house), abi.encodeCall(AuctionHouse.placeBid, (id, 10e18, 148e18)));
        _assertGuarded(r, 0);
        assertEq(house.auction(id).bidCount, 1);
    }

    function test_auction_clearAndFixLots_viaKeeperTip() public {
        vm.warp(_openAt(0, 1) + 1 hours);
        _day(0, 1);
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        orc.setPrice(NVDA, 150e18);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(alice));
        uint64 id = market.position(idNVDA, alice).auctionId;
        vm.warp(block.timestamp + 15);
        Reenterer k = _attacker();
        k.arm(address(usdc), RECV, address(house), abi.encodeCall(AuctionHouse.clear, (id)));
        k.exec(address(house), abi.encodeCall(AuctionHouse.fixLots, (id)));
        _assertGuarded(k, 0);
        vm.warp(house.auction(id).deadlines[3]);
        k.arm(address(usdc), RECV, address(house), abi.encodeCall(AuctionHouse.fixLots, (id)));
        k.exec(address(house), abi.encodeCall(AuctionHouse.clear, (id)));
        _assertGuarded(k, 1);
    }

    function test_auction_claim() public {
        uint64 id = _intraday();
        Auction memory a = house.auction(id);
        Reenterer r = _attacker();
        usdc.mint(address(r), 1_000_000e6);
        r.exec(address(house), abi.encodeCall(AuctionHouse.placeBid, (id, a.lot, 148e18)));
        vm.warp(a.deadlines[3]);
        house.clear(id);
        r.arm(address(tNVDA), RECV, address(house), abi.encodeCall(AuctionHouse.claim, (id)));
        r.arm(address(usdc), RECV, address(house), abi.encodeCall(AuctionHouse.claim, (id)));
        r.exec(address(house), abi.encodeCall(AuctionHouse.claim, (id)));
        _assertGuarded(r, 0);
        assertEq(tNVDA.balanceOf(address(r)), a.lot, "filled once");
    }

    function test_auction_commitAndReveal() public {
        (uint64 id, uint40 printAt) = _reopenAuction();
        uint128 q = house.auction(id).lot;
        Reenterer r = _attacker();
        usdc.mint(address(r), 1_000_000e6);
        bytes32 c = keccak256(
            abi.encode(block.chainid, address(house), id, address(r), q, uint128(139e18), bytes32("s"))
        );
        r.arm(
            address(usdc),
            SEND,
            address(house),
            abi.encodeCall(AuctionHouse.commitBid, (id, bytes32("x"), 1_000e6))
        );
        r.exec(address(house), abi.encodeCall(AuctionHouse.commitBid, (id, c, 200_000e6)));
        _assertGuarded(r, 0);
        vm.warp(printAt + 300);
        r.arm(address(usdc), SEND, address(house), abi.encodeCall(AuctionHouse.clear, (id)));
        r.exec(address(house), abi.encodeCall(AuctionHouse.revealBid, (id, q, 139e18, bytes32("s"))));
        _assertGuarded(r, 1);
        assertTrue(house.bid(id, address(r)).revealed);
    }

    function test_auction_completeReopen_viaKeeperTip() public {
        _closed(1, 2);
        uint40 printAt = _openAt(0, 2);
        vm.warp(printAt + 120);
        _reopen(1, 2, printAt, [uint128(180e18), 200e18, 250e18]);
        Reenterer k = _attacker();
        k.arm(address(usdc), RECV, address(house), abi.encodeCall(AuctionHouse.completeReopen, (AAPL)));
        k.exec(address(house), abi.encodeCall(AuctionHouse.completeReopen, (NVDA)));
        _assertGuarded(k, 0);
    }

    function test_auction_gdaBuy() public {
        (uint64 g,) = _gda();
        vm.warp(block.timestamp + 1 days);
        Reenterer r = _attacker();
        uint256 q = house.gda(g).qty / 10;
        uint256 cost = house.gdaPrice(g, q);
        usdc.mint(address(r), 2 * cost);
        r.arm(address(tNVDA), RECV, address(house), abi.encodeCall(AuctionHouse.gdaBuy, (g, 1e18, cost)));
        r.exec(address(house), abi.encodeCall(AuctionHouse.gdaBuy, (g, q, cost)));
        _assertGuarded(r, 0);
        assertEq(tNVDA.balanceOf(address(r)), q, "bought once");
    }

    /// @dev Backstop inventory listed on a GDA: alice's INTRADAY lot finds no bidder, the pool buys it at R and lists.
    function _gda() internal returns (uint64 g, uint64 auctionId) {
        auctionId = _intraday();
        vm.warp(house.auction(auctionId).deadlines[3]);
        house.clear(auctionId);
        market.settlePositions(auctionId, _one(alice));
        g = up.resellInventory(NVDA);
    }

    // ═════════════════════════════ cross-contract (enter A, re-enter B) ═════════════════════════════

    /// @dev Mid-borrow (the loan token is on its way to the borrower): the vault, pool and market views are final.
    function test_cross_borrow_accountingIsFinal() public {
        Reenterer r = _borrower(1_000e18, 0);
        r.arm(address(usdc), RECV, address(probe), abi.encodeCall(AccountingProbe.snap, ()));
        r.exec(address(market), abi.encodeCall(CredenceMarket.borrow, (idNVDA, 50_000e6, address(r))));
        _assertSameSnap(_decodeSnap(_assertRan(r, 0)), _snap());
    }

    function test_cross_withdrawCollateral_accountingIsFinal() public {
        Reenterer r = _borrower(1_000e18, 50_000e6);
        r.arm(address(tNVDA), RECV, address(probe), abi.encodeCall(AccountingProbe.snap, ()));
        r.exec(
            address(market), abi.encodeCall(CredenceMarket.withdrawCollateral, (idNVDA, 100e18, address(r)))
        );
        _assertSameSnap(_decodeSnap(_assertRan(r, 0)), _snap());
    }

    function test_cross_vaultWithdraw_accountingIsFinal() public {
        Reenterer r = _attacker();
        usdc.mint(address(r), 20_000e6);
        r.exec(address(vault), abi.encodeWithSignature("deposit(uint256,address)", 20_000e6, address(r)));
        r.arm(address(usdc), RECV, address(probe), abi.encodeCall(AccountingProbe.snap, ()));
        r.exec(
            address(vault),
            abi.encodeWithSignature("withdraw(uint256,address,address)", 5_000e6, address(r), address(r))
        );
        _assertSameSnap(_decodeSnap(_assertRan(r, 0)), _snap());
    }

    /// @dev A cover premium pulled from the borrower's wallet: the pool has booked the premium as unearned before the
    ///      cash arrives, so its NAV is lower mid-transfer. That is harmless only because the epoch is open, so a pool
    ///      deposit made from the hook is queued (not priced). Proven here.
    function test_cross_buyCover_poolDepositFromTheHookIsQueued() public {
        Reenterer r = _borrower(1_000e18, 130_000e6);
        engine.setQuote(250e6, 0, 0);
        vm.warp(_closeAt(0, 0) - 1 hours);
        usdc.mint(address(r), 10_000e6);
        r.arm(
            address(usdc), SEND, address(up), abi.encodeCall(UnderwriterPool.deposit, (10_000e6, address(r)))
        );
        r.exec(address(market), abi.encodeCall(CredenceMarket.buyCover, (idNVDA, 250e6, false)));
        bytes memory ret = _assertRan(r, 0);
        assertEq(abi.decode(ret, (uint256)), 0, "queued, no shares at the mid-transfer NAV");
        assertEq(up.pendingDeposit(0, address(r)), 10_000e6);
    }

    function test_cross_auctionClaim_accountingIsFinal() public {
        uint64 id = _intraday();
        Auction memory a = house.auction(id);
        Reenterer r = _attacker();
        usdc.mint(address(r), 1_000_000e6);
        r.exec(address(house), abi.encodeCall(AuctionHouse.placeBid, (id, a.lot, 148e18)));
        vm.warp(a.deadlines[3]);
        house.clear(id);
        r.arm(address(tNVDA), RECV, address(probe), abi.encodeCall(AccountingProbe.snap, ()));
        r.exec(address(house), abi.encodeCall(AuctionHouse.claim, (id)));
        _assertSameSnap(_decodeSnap(_assertRan(r, 0)), _snap());
    }

    /// @notice FINDING QA-01 (Medium, BE-chain). `AuctionHouse.gdaBuy` sends the tokens to the buyer *before*
    ///         `pool.onGdaSale` books the sale. In the buyer's receive hook the pool already holds the sale's cash but
    ///         still counts the sold units in its inventory, so `nav()` is overstated by their cost basis.
    function test_cross_gdaBuy_poolNavIsFinal() public finding {
        (uint64 g,) = _gda();
        vm.warp(block.timestamp + 1 days);
        Reenterer r = _attacker();
        uint256 q = house.gda(g).qty / 10;
        uint256 cost = house.gdaPrice(g, q);
        usdc.mint(address(r), cost);
        r.arm(address(tNVDA), RECV, address(probe), abi.encodeCall(AccountingProbe.snap, ()));
        r.exec(address(house), abi.encodeCall(AuctionHouse.gdaBuy, (g, q, cost)));
        _assertSameSnap(_decodeSnap(_assertRan(r, 0)), _snap());
    }

    /// @notice FINDING QA-01, exploit. An underwriter with a withdrawal queued for epoch e settles e from inside its
    ///         own GDA purchase: `sharePriceAfter` — the price its withdrawal is paid at — includes the double-counted
    ///         inventory. The remaining underwriters pay the difference.
    function test_cross_gdaBuy_settleEpochInflatesTheWithdrawalPrice() public finding {
        // the attacker is an underwriter with its whole stake queued for Tuesday's epoch (1)
        Reenterer r = _attacker();
        usdc.mint(address(r), 100_000e6);
        r.exec(address(up), abi.encodeCall(UnderwriterPool.deposit, (100_000e6, address(r))));
        (uint64 g,) = _gda(); // Tuesday 10:30: backstop inventory listed
        uint256 shares = up.balanceOf(address(r));
        r.exec(address(up), abi.encodeCall(UnderwriterPool.requestWithdraw, (shares)));
        vm.warp(_closeAt(0, 1) - 2 hours);
        up.openEpoch(VENUE);
        vm.warp(_openAt(0, 2) + 10 minutes); // epoch 1 can settle
        _day(0, 2);
        uint256 q = house.gda(g).qty / 10;
        uint256 cost = house.gdaPrice(g, q);
        usdc.mint(address(r), cost);

        // reference: the same purchase, then the settlement
        uint256 snapId = vm.snapshotState();
        r.exec(address(house), abi.encodeCall(AuctionHouse.gdaBuy, (g, q, cost)));
        up.settleEpoch(1);
        uint256 fairPrice = up.epoch(1).sharePriceAfter;
        vm.revertToState(snapId);

        // attack: settle from the buyer's receive hook
        r.arm(address(tNVDA), RECV, address(up), abi.encodeCall(UnderwriterPool.settleEpoch, (1)));
        r.exec(address(house), abi.encodeCall(AuctionHouse.gdaBuy, (g, q, cost)));
        _assertRan(r, 0);
        emit log_named_uint("fair sharePriceAfter", fairPrice);
        emit log_named_uint("attack sharePriceAfter", up.epoch(1).sharePriceAfter);
        emit log_named_uint("attacker reserved", up.epoch(1).withdrawAssetsReserved);
        assertEq(up.epoch(1).sharePriceAfter, fairPrice, "withdrawal price must not include the sold units");
    }
}
