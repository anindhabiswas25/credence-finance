// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";

/// @title QA-07 regression (fixed in 61761b9, `PoolLib.advanceHead`): FIFO priority of older unpaid withdrawals must
///        hold beyond the first 64 withdrawal epochs (§8.6.3).
/// @notice 65 small withdrawal epochs are settled and paid in full; then the pool's cash runs short (it backstops an
///         unsold lot), an old withdrawer (epoch 65) and a newer one (epoch 66) are both reserved more than the cash,
///         and the newer one claims first. The older one must still be paid in full.
contract PoolFindingsTest is RiskFixture {
    address internal small = makeAddr("small");
    address internal alice = makeAddr("alice");

    function _calendarWeeks() internal pure override returns (uint256) {
        return 16;
    }

    function setUp() public {
        setUpRisk();
        _underwrite(uw1, 250_000e6);
        _underwrite(uw2, 150_000e6);
        _underwrite(small, 100e6);
    }

    function _open(uint256 s) internal view returns (uint40) {
        return _openAt(s / 5, s % 5);
    }

    function _one(address b) internal pure returns (address[] memory bs) {
        bs = new address[](1);
        bs[0] = b;
    }

    function test_QA07_fifoBeyondSixtyFourWithdrawalEpochs() public {
        for (uint64 e; e < 65; ++e) {
            vm.warp(_open(e) + 1 hours);
            vm.prank(small);
            up.requestWithdraw(1e18);
            vm.warp(_open(e + 1) + 10 minutes);
            up.settleEpoch(e);
            vm.prank(small);
            up.claimWithdraw(e);
        }
        // session 65: an unsold INTRADAY lot is backstopped with pool cash; uw1 queues its whole stake (epoch 65)
        vm.warp(_open(65) + 1 hours);
        _day(13, 0);
        _position(alice, idNVDA, tNVDA, 1_000e18, 130_000e6);
        orc.setPrice(NVDA, 150e18);
        vm.prank(keeper);
        market.flagForAuction(idNVDA, _one(alice));
        uint64 id = market.position(idNVDA, alice).auctionId;
        vm.warp(_open(65) + 1 hours + 15);
        house.fixLots(id);
        vm.warp(house.auction(id).deadlines[3]);
        house.clear(id);
        market.settlePositions(id, _one(alice));
        uint256 a = up.balanceOf(uw1);
        vm.prank(uw1);
        assertEq(up.requestWithdraw(a), 65);
        vm.warp(_open(66) + 10 minutes);
        up.settleEpoch(65);
        // session 66: uw2 queues everything (epoch 66)
        vm.warp(_open(66) + 1 hours);
        uint256 b = up.balanceOf(uw2);
        vm.prank(uw2);
        assertEq(up.requestWithdraw(b), 66);
        vm.warp(_open(67) + 10 minutes);
        up.settleEpoch(66);
        uint256 owedA = up.epoch(65).withdrawAssetsReserved;
        uint256 owedB = up.epoch(66).withdrawAssetsReserved;
        assertGt(owedA + owedB, usdc.balanceOf(address(up)), "cash is short of what is reserved");
        // the newer claimant goes first: it may take only what the older one does not need
        vm.prank(uw2);
        try up.claimWithdraw(66) {} catch {}
        vm.prank(uw1);
        assertEq(up.claimWithdraw(65), owedA, "the older withdrawal is paid in full (FIFO)");
    }
}
