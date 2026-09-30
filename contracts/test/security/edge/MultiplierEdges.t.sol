// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClockFixture} from "../../utils/ClockFixture.sol";
import {ClockState, ClosureType, FeedMarketStatus, Session} from "../../../src/libraries/Types.sol";

/// @title ERC-8056 multiplier edge cases on the real XNYS calendar (matrix rows E-K-*, `docs/qa/edge-cases.md`;
///        ADR-0119). The token price = share price × multiplier: a step ≤ 2 % is cached at the next poke; a larger one
///        opens a corporate action (no borrow, no liquidation) that ends only when the new multiplier and a post-action
///        share price are both in.
contract MultiplierEdgesTest is ClockFixture {
    uint256 internal constant MON_NOV02 = 22;
    uint256 internal constant THU_NOV05 = 25;
    uint256 internal constant FRI_NOV06 = 26;
    uint256 internal constant MON_NOV09 = 27;
    uint256 internal constant P = 200e18; // share price

    function setUp() public {
        setUpStack();
    }

    /// @dev List the asset just before session `i` (no missed closures to replay).
    function _start(uint256 i) internal {
        vm.warp(sessions[i].extOpen - 1);
        _list();
    }

    /// @dev Friday's official close on both feeds, at the close.
    function _fridayClose(Session memory fri) internal {
        vm.warp(fri.close);
        _closePrint(feedA, NVDA, P, fri.open, fri.close);
        _closePrint(feedB, NVDA, P, fri.open, fri.close);
    }

    /// @dev REGULAR at `t` inside session `i`, both feeds printing `price` per share.
    function _regularAt(uint256 t, uint256 price) internal returns (ClockState) {
        vm.warp(t);
        _liveBoth(price, FeedMarketStatus.REGULAR);
        return _poke();
    }

    function _schedule(uint256 m, uint256 at) internal {
        vm.prank(issuer);
        token.scheduleUIMultiplier(m, at);
    }

    function _mult() internal view returns (uint256) {
        return oracle.sharesPerToken(NVDA);
    }

    /// E-K-01: a small dividend step (+1.2 %) is applied at once: the next poke caches it, the asset stays REGULAR and the
    ///         token is valued at the share price × the new multiplier.
    function test_E_K01_smallDividendAppliedAtOnce() public {
        _start(MON_NOV02);
        Session memory s = sessions[MON_NOV02];
        assertEq(uint8(_regularAt(s.open + 1 hours, P)), uint8(ClockState.REGULAR));
        assertEq(oracle.valuationPrice(NVDA), P);
        vm.prank(issuer);
        token.setSharesPerToken(1.012e18); // effective now
        assertEq(_mult(), 1e18, "not cached before a poke");
        assertEq(uint8(_regularAt(s.open + 1 hours + 10, P)), uint8(ClockState.REGULAR));
        assertEq(_mult(), 1.012e18);
        assertFalse(clock.multiplierAction(NVDA));
        assertEq(oracle.valuationPrice(NVDA), P * 1012 / 1000);
    }

    /// E-K-02: a 2:1 split scheduled for Monday's open, announced on Thursday: no effect on Thursday and Friday (the
    ///         update is more than a day away), CORP_ACTION from Sunday (MULTIPLIER_LEAD) over the scheduled weekend
    ///         closure, and Monday reopens only with the new multiplier and a post-split open print: the token's open
    ///         price equals Friday's close (the split changes nothing per token).
    function test_E_K02_twoForOneSplitAcrossAWeekend() public {
        Session memory thu = sessions[THU_NOV05];
        Session memory fri = sessions[FRI_NOV06];
        Session memory mon = sessions[MON_NOV09];
        _start(THU_NOV05);
        _regularAt(thu.open + 1 hours, P);
        _schedule(2e18, mon.open);
        assertEq(
            uint8(_regularAt(thu.open + 2 hours, P)), uint8(ClockState.REGULAR), "Thursday: > 1 day away"
        );
        vm.warp(fri.open);
        _openPrint(feedA, NVDA, P, fri.open);
        _openPrint(feedB, NVDA, P, fri.open);
        assertEq(
            uint8(_regularAt(fri.close - 1 hours, P)),
            uint8(ClockState.REOPEN),
            "Friday: > 1 day away, no action"
        );
        assertFalse(clock.multiplierAction(NVDA));
        _fridayClose(fri);
        vm.warp(fri.close + 1);
        _poke();
        assertEq(_info().refPrice, P, "Friday's close per token (multiplier 1)");
        vm.warp(mon.open - 1 days);
        assertEq(uint8(_poke()), uint8(ClockState.CORP_ACTION), "Sunday: the split is within a day");
        assertTrue(clock.multiplierAction(NVDA));
        assertEq(oracle.valuationPrice(NVDA), P, "valued at the reference while the action holds");
        // Monday: the multiplier switches at the open; the relayers print the post-split share price
        vm.warp(mon.open);
        assertEq(uint8(_poke()), uint8(ClockState.CORP_ACTION), "no print since effectiveAt yet");
        _openPrint(feedA, NVDA, P / 2, mon.open);
        _openPrint(feedB, NVDA, P / 2, mon.open);
        vm.warp(mon.open + 1 minutes);
        _liveBoth(P / 2, FeedMarketStatus.REGULAR);
        ClockState st = _poke();
        assertEq(_mult(), 2e18, "cached after a post-split print");
        assertFalse(clock.multiplierAction(NVDA));
        assertEq(uint8(st), uint8(ClockState.REOPEN), "the weekend closure reopens on the open print");
        assertEq(_info().openPrint, P, "open per token = P/2 x 2 = Friday's close");
    }

    /// E-K-03: a 1:3 reverse split (multiplier 1/3): a relayer that still prints the old share price after
    ///         `effectiveAt` does not end the action (the token would be valued at a third); the post-split price
    ///         (×3) does.
    function test_E_K03_oneForThreeReverseSplitNeedsAPostActionPrice() public {
        Session memory fri = sessions[FRI_NOV06];
        Session memory mon = sessions[MON_NOV09];
        _start(FRI_NOV06);
        _regularAt(fri.open + 1 hours, P);
        uint256 third = uint256(1e18) / 3;
        _schedule(third, mon.open);
        _fridayClose(fri);
        vm.warp(fri.close + 1);
        _poke();
        vm.warp(mon.open - 12 hours);
        assertEq(uint8(_poke()), uint8(ClockState.CORP_ACTION));
        vm.warp(mon.open + 30);
        _liveBoth(P, FeedMarketStatus.REGULAR); // a stale relayer: the pre-split price, stamped after effectiveAt
        assertEq(uint8(_poke()), uint8(ClockState.CORP_ACTION), "P x 1/3 is 67 % off the reference");
        assertEq(_mult(), 1e18);
        _openPrint(feedA, NVDA, P * 3, mon.open);
        _openPrint(feedB, NVDA, P * 3, mon.open);
        vm.warp(mon.open + 60);
        _liveBoth(P * 3, FeedMarketStatus.REGULAR);
        assertEq(uint8(_poke()), uint8(ClockState.REOPEN));
        assertEq(_mult(), third);
        assertApproxEqRel(_info().openPrint, P, 1e9, "per token unchanged");
    }

    /// E-K-04: a large update (+50 %) scheduled 2 h ahead while positions are open in REGULAR hours: CORP_ACTION at
    ///         once (no borrow, no liquidation: MarketLib / BorrowLogic refuse CORP_ACTION), the token valued at the
    ///         reference (the per-token price when the action began) until it ends; after the switch and a post-action
    ///         print the corporate-action closure reopens on that first fresh cross-checked price (the HALT /
    ///         CORP_ACTION open-print rule), which equals the reference per token.
    function test_E_K04_largeUpdateDuringOpenPositions() public {
        Session memory thu = sessions[THU_NOV05];
        _start(THU_NOV05);
        _regularAt(thu.open + 1 hours, P);
        _schedule(1.5e18, thu.open + 3 hours);
        assertEq(uint8(_regularAt(thu.open + 1 hours + 1, P)), uint8(ClockState.CORP_ACTION));
        assertEq(uint8(_info().closureType), uint8(ClosureType.CORP_ACTION));
        uint256 ref = _info().refPrice;
        assertEq(ref, P, "per token when the action began");
        assertEq(oracle.valuationPrice(NVDA), ref);
        // after the switch, with a post-action share price (P / 1.5): the multiplier is cached, the action ends
        vm.warp(thu.open + 3 hours + 5);
        _liveBoth(P * 2 / 3, FeedMarketStatus.REGULAR);
        ClockState st = _poke();
        assertEq(_mult(), 1.5e18);
        assertFalse(clock.multiplierAction(NVDA));
        assertEq(uint8(st), uint8(ClockState.REOPEN), "reopens on the first fresh post-action price");
        assertApproxEqRel(_info().openPrint, P, 1e9, "per token unchanged");
    }

    /// E-K-05: a multiplier step inside a scheduled closure that is small (+1.5 %, a dividend over the weekend) is cached
    ///         during the closure without a corporate action; the reopen values the token with it. Then a ×2 jump
    ///         effective at once holds CORP_ACTION while the relayers print the old share price; the timelock confirms it.
    function test_E_K05_multiplierChangesAcrossAClosure() public {
        Session memory fri = sessions[FRI_NOV06];
        Session memory mon = sessions[MON_NOV09];
        _start(FRI_NOV06);
        _regularAt(fri.close - 1 hours, P);
        _fridayClose(fri);
        vm.warp(fri.close + 1 hours);
        _poke();
        vm.prank(issuer);
        token.setSharesPerToken(1.015e18);
        vm.warp(fri.close + 1 days);
        assertEq(uint8(_poke()), uint8(ClockState.CLOSED));
        assertEq(_mult(), 1.015e18, "small step cached inside the closure");
        vm.warp(mon.open);
        _openPrint(feedA, NVDA, P, mon.open);
        _openPrint(feedB, NVDA, P, mon.open);
        vm.warp(mon.open + 60);
        _liveBoth(P, FeedMarketStatus.REGULAR);
        assertEq(uint8(_poke()), uint8(ClockState.REOPEN));
        assertEq(_info().openPrint, P * 1015 / 1000);
        // a ×2 jump effective at once: CORP_ACTION from the next poke; a relayer still printing the old share price
        // keeps it (2 × P is 100 % off the reference); the timelock can end it at any time
        vm.warp(mon.open + 2 hours);
        _liveBoth(P, FeedMarketStatus.REGULAR);
        vm.prank(issuer);
        token.setSharesPerToken(2.03e18);
        assertEq(uint8(_poke()), uint8(ClockState.CORP_ACTION));
        vm.warp(mon.open + 3 hours);
        _liveBoth(P, FeedMarketStatus.REGULAR);
        assertEq(uint8(_poke()), uint8(ClockState.CORP_ACTION), "the old share price never ends it");
        assertTrue(clock.multiplierAction(NVDA));
        vm.prank(timelock);
        clock.confirmCorporateAction(NVDA, 2.03e18);
        assertFalse(clock.multiplierAction(NVDA));
        assertEq(_mult(), 2.03e18);
    }

    /// E-K-06: a cancelled update before it takes effect: the action ends by itself and nothing is cached.
    function test_E_K06_cancelledUpdateEndsTheAction() public {
        Session memory thu = sessions[THU_NOV05];
        _start(THU_NOV05);
        _regularAt(thu.open + 1 hours, P);
        _schedule(2e18, thu.open + 4 hours);
        assertEq(uint8(_regularAt(thu.open + 1 hours + 1, P)), uint8(ClockState.CORP_ACTION));
        vm.prank(issuer);
        token.cancelUIMultiplierUpdate();
        _regularAt(thu.open + 1 hours + 2, P);
        assertFalse(clock.multiplierAction(NVDA));
        assertEq(_mult(), 1e18);
    }
}
