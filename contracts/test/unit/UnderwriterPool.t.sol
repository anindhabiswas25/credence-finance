// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {Epoch, EpochPhase, CoverRequest, ClockState} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {IUnderwriterPoolEvents} from "../../src/libraries/Events.sol";

/// @notice UnderwriterPool (§8.6) against the real market, auction house and the risk-core ports of the engine.
contract UnderwriterPoolTest is RiskFixture, IUnderwriterPoolEvents {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        setUpRisk();
    }

    // ───────────── deposits and share price ─────────────

    function test_depositOutsideAnEpochMintsAtPrice() public {
        assertEq(up.sharePrice(), 1e18);
        uint256 sh = _underwrite(uw1, 100_000e6);
        assertEq(sh, 100_000e18);
        assertEq(up.nav(), 100_000e6);
        assertEq(up.sharePrice(), 1e18);
        uint256 sh2 = _underwrite(uw2, 50_000e6);
        assertEq(sh2, 50_000e18);
        assertEq(up.startEpoch(), 0);
        assertEq(up.venue(), VENUE);
        assertEq(up.asset(), address(usdc));
    }

    function test_depositRejectsZero() public {
        vm.expectRevert(ICredenceErrors.ZeroAmount.selector);
        up.deposit(0, uw1);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        up.deposit(1, address(0));
    }

    // ───────────── the full epoch ─────────────

    function test_epochLifecycle() public {
        vm.prank(timelock);
        market.setFeeSplit(idNVDA, 0, 0); // no risk-fee receivable: NAV moves only by the epoch's flows here
        _underwrite(uw1, 400_000e6);
        _underwrite(uw2, 100_000e6);
        // a withdrawal requested before Monday's Bell window belongs to epoch 0
        vm.prank(uw2);
        assertEq(up.requestWithdraw(20_000e18), 0);
        // a position that needs cover
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6); // 72% of $180k
        engine.setQuote(250e6, 100e6, 1_000e6);

        // 14:00 ET: the Bell window opens; the keeper opens epoch 0
        vm.warp(_closeAt(0, 0) - 2 hours);
        up.openEpoch(VENUE);
        Epoch memory e0 = up.epoch(0);
        assertEq(uint8(e0.phase), uint8(EpochPhase.OPEN));
        assertEq(e0.closeAt, _closeAt(0, 0));
        assertEq(e0.reopenAt, _openAt(0, 1));
        assertEq(e0.navBefore, 500_000e6);
        assertEq(e0.withdrawSharesQueued, 20_000e18);
        // a deposit now is queued into the open epoch; a withdrawal request now belongs to epoch 1
        usdc.mint(bob, 10_000e6);
        vm.startPrank(bob);
        usdc.approve(address(up), 10_000e6);
        assertEq(up.deposit(10_000e6, bob), 0);
        vm.stopPrank();
        assertEq(up.pendingDeposit(0, bob), 10_000e6);
        assertEq(up.nav(), 500_000e6, "queued cash is not NAV");
        vm.prank(uw1);
        assertEq(up.requestWithdraw(1e18), 1);

        // cover: the premium sits unearned
        _cover(alice, idNVDA, 250e6);
        e0 = up.epoch(0);
        assertEq(e0.premiums, 250e6);
        assertEq(e0.policies, 1);
        assertEq(up.unearnedPremiums(), 250e6);
        assertEq(up.nav(), 500_000e6);
        assertGt(up.worstCovered(0, NVDA), 0);
        assertGt(up.utilisation(0), 0);
        assertGt(up.capacityHeadroom(0), 0);

        // the Bell deadline: J is frozen
        vm.warp(_closeAt(0, 0) - 15 minutes);
        up.snapshotEpoch(0);
        assertEq(up.epoch(0).equityAtRisk, 500_000e6);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.EpochNotOpen.selector, 0));
        up.snapshotEpoch(0);

        // the closure; settlement waits for the reopen + delay
        _closed(0, 1);
        vm.warp(_openAt(0, 1) + 5 minutes);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.EpochNotReady.selector, 0, 1));
        up.settleEpoch(0);
        vm.warp(_openAt(0, 1) + 10 minutes);
        // the REOPEN of the assets is not complete yet: the covered asset's worst loss is held back (R-11)
        up.settleEpoch(0);
        e0 = up.epoch(0);
        assertEq(uint8(e0.phase), uint8(EpochPhase.SETTLED));
        uint256 reserveNVDA = up.worstCovered(0, NVDA);
        assertEq(e0.pendingLossReserve, reserveNVDA);
        assertEq(up.lossReserve(0, NVDA), reserveNVDA);
        // NAV after = 500k + 250 premium − reserve
        assertEq(e0.navAfter, 500_000e6 + 250e6 - reserveNVDA);
        uint256 price = e0.sharePriceAfter;
        assertEq(price, (uint256(e0.navAfter) + 1) * 1e30 / (500_000e18 + 1e12));
        // withdrawals burned at the price, deposits minted at it
        assertEq(e0.withdrawAssetsReserved, uint256(20_000e18) * price / 1e30);
        assertEq(e0.depositSharesMinted, uint256(10_000e6) * 1e30 / price);
        assertEq(up.totalSupply(), 500_000e18 - 20_000e18 + e0.depositSharesMinted);

        // claims
        vm.prank(uw2);
        uint256 got = up.claimWithdraw(0);
        assertEq(got, e0.withdrawAssetsReserved);
        vm.prank(uw2);
        vm.expectRevert(ICredenceErrors.NothingToClaim.selector);
        up.claimWithdraw(0);
        vm.prank(bob);
        assertEq(up.claimDeposit(0), e0.depositSharesMinted);
        assertEq(up.balanceOf(bob), e0.depositSharesMinted);

        // the reopen completes → the reserve is released
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.ReserveNotReleasable.selector, 0, NVDA));
        up.releaseLossReserve(0, NVDA);
        clk.setReopen(NVDA, 1, 0, false);
        uint256 navBefore = up.nav();
        up.releaseLossReserve(0, NVDA);
        assertEq(up.nav(), navBefore + reserveNVDA);
        assertEq(up.pendingLossReserve(), 0);
    }

    function test_writeCoverOpensTheEpochItself() public {
        _underwrite(uw1, 500_000e6);
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        engine.setQuote(250e6, 0, 0);
        vm.warp(_closeAt(0, 0) - 1 hours);
        _cover(alice, idNVDA, 250e6);
        (uint64 e, bool live) = up.activeEpoch();
        assertTrue(live);
        assertEq(e, 0);
        assertEq(up.currentEpoch(VENUE), 0);
        // after the Bell deadline the first write snapshots J
        _position(bob, idTSLA, tTSLA, 100e18, 18_000e6);
        engine.setSafeLtv(TSLA, 1, 0.6e18); // bob (72%) needs action at the Bell
        vm.warp(_closeAt(0, 0) - 10 minutes);
        vm.prank(keeper);
        address[] memory bs = new address[](1);
        bs[0] = bob;
        market.enforceBell(idTSLA, bs);
        assertEq(uint8(up.epoch(0).phase), uint8(EpochPhase.SNAPSHOT));
        assertEq(up.epoch(0).policies, 2);
        assertEq(market.position(idTSLA, bob).coverClosureId, 1);
    }

    function test_coverOutsideTheBellWindowIsRefused() public {
        _underwrite(uw1, 500_000e6);
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        engine.setQuote(250e6, 0, 0);
        vm.warp(_closeAt(0, 0) - 3 hours);
        usdc.mint(alice, 250e6);
        vm.startPrank(alice);
        usdc.approve(address(market), 250e6);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.EpochNotOpen.selector, 0));
        market.buyCover(idNVDA, 250e6, false);
        vm.stopPrank();
    }

    // ───────────── capacity (INV-POOL-02) ─────────────

    function test_capacityExceededReverts() public {
        _underwrite(uw1, 1_000e6); // J = $1,000: any real stress loss is > 50% of it
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        engine.setQuote(250e6, 0, 0);
        vm.warp(_closeAt(0, 0) - 1 hours);
        usdc.mint(alice, 250e6);
        vm.startPrank(alice);
        usdc.approve(address(market), 250e6);
        vm.expectPartialRevert(ICredenceErrors.CapacityExceeded.selector);
        market.buyCover(idNVDA, 250e6, false);
        vm.stopPrank();
    }

    function test_premiumAboveMaxReverts() public {
        _underwrite(uw1, 500_000e6);
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        engine.setQuote(250e6, 0, 0);
        vm.warp(_closeAt(0, 0) - 1 hours);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.PremiumAboveMax.selector, 250e6, 100e6));
        market.buyCover(idNVDA, 100e6, true);
    }

    function test_previewMatchesWrite() public {
        _underwrite(uw1, 500_000e6);
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        engine.setQuote(321e6, 0, 0);
        vm.warp(_closeAt(0, 0) - 1 hours);
        (,,, uint256 prem) = market.bellStatus(idNVDA, alice);
        assertEq(prem, 0, "SAFE before the Bell has no premium shown");
        CoverRequest memory r = CoverRequest({
            marketId: idNVDA,
            assetId: NVDA,
            borrower: alice,
            closureType: 1,
            closureDays: 1,
            closureId: 1,
            epochId: 0,
            collateralValue: 180_000e6,
            debtProjected: 130_000e6
        });
        (uint256 p, uint256 u) = up.previewCover(r);
        assertEq(p, 321e6);
        assertGt(u, 0);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        up.writeCover(r, 1_000e6);
    }

    // ───────────── losses ─────────────

    function test_payShortfallIsBoundedByFreeCash() public {
        _underwrite(uw1, 1_000e6);
        vm.prank(address(market));
        assertEq(up.payShortfall(400e6), 400e6);
        vm.prank(address(market));
        assertEq(up.payShortfall(5_000e6), 600e6);
        assertEq(usdc.balanceOf(address(market)) >= 1_000e6, true);
        assertEq(up.freeCash(), 0);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        up.payShortfall(1);
    }

    function test_incomeIsCreditedToTheOpenEpoch() public {
        _underwrite(uw1, 100_000e6);
        vm.warp(_closeAt(0, 0) - 2 hours);
        up.openEpoch(VENUE);
        usdc.mint(address(up), 30e6);
        vm.startPrank(address(market));
        up.creditRiskFee(10e6);
        up.creditPenalty(20e6);
        vm.stopPrank();
        vm.prank(address(house));
        up.creditBond(0);
        Epoch memory e0 = up.epoch(0);
        assertEq(e0.riskFees, 10e6);
        assertEq(e0.penalties, 20e6);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        up.creditBond(1);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        up.creditRiskFee(1);
    }

    // ───────────── epochs nobody opened ─────────────

    function test_settleAnEpochNobodyOpened() public {
        _underwrite(uw1, 100_000e6);
        vm.prank(uw1);
        up.requestWithdraw(10_000e18); // epoch 0
        vm.warp(_openAt(0, 1) + 11 minutes); // Tuesday: nobody opened Monday's epoch
        up.settleEpoch(0);
        Epoch memory e0 = up.epoch(0);
        assertEq(uint8(e0.phase), uint8(EpochPhase.SETTLED));
        assertEq(e0.withdrawAssetsReserved, 10_000e6);
        vm.prank(uw1);
        assertEq(up.claimWithdraw(0), 10_000e6);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.EpochAlreadySettled.selector, 0));
        up.settleEpoch(0);
    }

    function test_openEpochGuards() public {
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.WrongVenue.selector, bytes32("USBANK")));
        up.openEpoch(bytes32("USBANK"));
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NotInBellWindow.selector, 0, 0));
        up.openEpoch(VENUE);
        vm.warp(_closeAt(0, 0) - 1 hours);
        up.openEpoch(VENUE);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.EpochStillOpen.selector, 0));
        up.openEpoch(VENUE);
        // Tuesday's Bell window while Monday's epoch is unsettled: cover for Tuesday is unavailable
        vm.warp(_closeAt(0, 1) - 1 hours);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.EpochStillOpen.selector, 0));
        up.openEpoch(VENUE);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.SnapshotTooEarly.selector, _closeAt(0, 0) - 15 minutes)
        );
        this.snapshotBeforeBell();
    }

    function snapshotBeforeBell() external {
        vm.warp(_closeAt(0, 0) - 1 hours);
        up.snapshotEpoch(0);
    }

    function test_fallbackAdvanceIsS4() public {
        vm.expectRevert(ICredenceErrors.NotImplemented.selector);
        up.fallbackAdvance(idNVDA, 1, 1);
    }

    function test_wiringAndGovernance() public {
        vm.expectRevert(ICredenceErrors.AlreadyWired.selector);
        vm.prank(timelock);
        up.initializeWiring(address(market), address(house), address(0), address(clk), address(tips));
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        up.setSettleDelay(1);
        vm.prank(timelock);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        up.setSettleDelay(2 days);
        vm.prank(timelock);
        up.setSettleDelay(20 minutes);
        assertEq(up.settleDelay(), 20 minutes);
    }
}
