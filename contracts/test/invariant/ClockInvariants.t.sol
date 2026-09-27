// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ClockState, ClockData} from "../../src/libraries/Types.sol";
import {AssetClock} from "../../src/clock/AssetClock.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {ClockHandler} from "./ClockHandler.sol";

/// @title Clock and price-layer invariants (Build Guide §8.2.2, §8.3.2, §14.2).
/// @notice INV-CLK-01..03, INV-FAIL-01 and INV-ORA-01 over random sequences of time, prints, statuses, DEX moves,
///         guardian restrictions, corporate actions and auction completions. Default profile: 256 runs × depth 128.
contract ClockInvariantsTest is Test {
    ClockHandler h;
    AssetClock clock;
    OracleAdapter oracle;
    bytes32 constant NVDA = keccak256("NVDA:XNAS");

    function setUp() public {
        h = new ClockHandler();
        clock = AssetClock(address(h.clock_()));
        oracle = OracleAdapter(address(h.oracle_()));
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](11);
        sel[0] = ClockHandler.warp.selector;
        sel[1] = ClockHandler.poke.selector;
        sel[2] = ClockHandler.relay.selector;
        sel[3] = ClockHandler.officialPrints.selector;
        sel[4] = ClockHandler.haltStatus.selector;
        sel[5] = ClockHandler.dexMove.selector;
        sel[6] = ClockHandler.guardianRestrict.selector;
        sel[7] = ClockHandler.corporateAction.selector;
        sel[8] = ClockHandler.auctionDone.selector;
        sel[9] = ClockHandler.issuerFreeze.selector;
        sel[10] = ClockHandler.warp.selector; // time moves twice as often as anything else
        targetSelector(FuzzSelector(address(h), sel));
    }

    /// INV-CLK-01: closureId never decreases, and increments exactly once per scheduled close
    /// (plus once per halt / corporate-action closure).
    function invariant_CLK01_closureIdOncePerClose() public view {
        ClockData memory d = clock.closureInfo(NVDA);
        assertFalse(h.closureIdDecreased(), "closureId decreased");
        assertEq(
            d.closureId, h.scheduledClosures() + h.unscheduledClosures(), "closureId == closures announced"
        );
        assertEq(
            h.scheduledClosures(),
            d.closedSessions - h.closedAtList(),
            "one scheduled closure per processed close"
        );
        // every scheduled close up to the last poke was processed, and none after it
        uint256 due;
        for (uint256 i = h.closedAtList(); i < h.sessionCount(); ++i) {
            if (h.sessionClose(i) <= h.lastPokeTs()) due++;
        }
        assertEq(h.scheduledClosures(), due, "closes due by the last poke");
    }

    /// INV-CLK-02: the guardian only restricts: an active restriction is always applied, and no accepted
    /// restriction ever shortened an earlier one.
    function invariant_CLK02_guardianOnlyRestricts() public view {
        assertFalse(h.guardianViolated(), h.violation());
        assertFalse(h.restrictionShortened(), "restriction shortened");
        assertGe(clock.haltedUntil(NVDA), h.ghostHaltedUntil());
        assertGe(clock.closedUntil(NVDA), h.ghostClosedUntil());
    }

    /// INV-CLK-03: the open print is written at most once per closureId.
    function invariant_CLK03_oneOpenPrintPerClosure() public view {
        uint64 id = clock.closureInfo(NVDA).closureId;
        for (uint64 c = 0; c <= id; ++c) {
            assertLe(h.openPrintEvents(c), 1, "two open prints for one closure");
        }
        assertFalse(h.openPrintRewritten(), "open print rewritten");
    }

    /// INV-FAIL-01: calendar and oracle disagreeing → the more restrictive state.
    function invariant_FAIL01_failClosed() public view {
        assertFalse(h.failClosedViolated(), h.violation());
    }

    /// INV-ORA-01: in EXTENDED, CLOSED and HALTED, valuationPrice ≤ refPrice.
    function invariant_ORA01_offHoursNeverAboveRef() public view {
        ClockState st = clock.state(NVDA);
        if (st != ClockState.EXTENDED && st != ClockState.CLOSED && st != ClockState.HALTED) return;
        uint256 ref = clock.closureInfo(NVDA).refPrice;
        try oracle.valuationPrice(NVDA) returns (uint256 v) {
            assertLe(v, ref, "valuation above reference");
        } catch {
            // fail closed (no reference or no price): nothing can be valued, which is allowed
        }
    }

    function afterInvariant() public view {
        assertGt(h.calls(), 0);
    }
}
