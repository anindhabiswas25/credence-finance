// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {console2} from "forge-std/Test.sol";
import {
    Settlement,
    SettlementStatus,
    SolverLot,
    LotInfo,
    RedemptionClaim
} from "../../src/libraries/Types.sol";
import {NavFixture} from "../utils/NavFixture.sol";
import {SettlementHandler, NavSys} from "./SettlementHandler.sol";

/// @notice NAV settlement invariants (Guide §8.8, S4 brief C; ADR-0111) at the default 256 runs × depth 128:
///         INV-SET-01 cash in = cash out, INV-SET-02 tokens conserved, INV-SET-03 the floor is respected,
///         INV-SET-04 no settlement opens while HALTED (nor CLOSED / CORP_ACTION, INV-LIQ-01), plus the pool's
///         redemption claims in NAV at cost (§8.6.1).
contract SettlementInvariantsTest is NavFixture {
    SettlementHandler internal h;

    function setUp() public {
        vm.warp(1_791_000_000);
        setUpNav();
        vm.warp(_morning(1, 1));
        _seed(5_000_000e6, 1_000_000e6);
        h = new SettlementHandler(
            NavSys({
                market: market,
                pool: up,
                adapter: adapter,
                venue: solver,
                fund: fund,
                registry: registry,
                usdc: usdc,
                clk: clk,
                orc: orc,
                id: idTBILL,
                asset: TBILL,
                issuer: issuer,
                solvers: [solverA, solverB]
            })
        );
        address[4] memory bs = h.borrowerList();
        for (uint256 i; i < 4; ++i) {
            registry.setAllowed(bs[i], true);
        }
        usdc.mint(address(tips), 10_000_000e6);
        targetContract(address(h));
        bytes4[] memory w = new bytes4[](16);
        bytes4[16] memory sel = [
            h.borrow.selector,
            h.borrow.selector,
            h.stress.selector,
            h.navMove.selector,
            h.stress.selector,
            h.open.selector,
            h.open.selector,
            h.bid.selector,
            h.bid.selector,
            h.warp.selector,
            h.finalize.selector,
            h.finalize.selector,
            h.fulfillAndClaim.selector,
            h.clockState.selector,
            h.gate.selector,
            h.repay.selector
        ];
        for (uint256 i; i < 16; ++i) {
            w[i] = sel[i];
        }
        targetSelector(FuzzSelector({addr: address(h), selectors: w}));
    }

    /// INV-SET-01: every finalized settlement paid the market exactly what came in (the solver's escrow, or the pool's
    /// advance), the adapter never keeps cash, and the venue holds exactly the live best bids plus unpaid refunds.
    function invariant_cashInEqualsCashOut() public view {
        uint256 liveEscrow;
        for (uint256 i; i < h.idCount(); ++i) {
            uint64 id = h.ids(i);
            Settlement memory s = adapter.settlement(id);
            LotInfo memory lot = market.lotInfo(id);
            if (s.status == SettlementStatus.OPEN) {
                SolverLot memory l = solver.lot(id);
                liveEscrow += l.escrow;
                assertFalse(lot.cleared);
                continue;
            }
            assertTrue(lot.cleared);
            assertEq(lot.proceeds, s.proceeds, "market received the settlement's proceeds");
            if (s.status == SettlementStatus.FILLED) {
                assertEq(h.solverPaid(id), s.proceeds, "solver paid = proceeds");
            } else {
                assertEq(up.redemptionClaim(s.requestId).cost, s.proceeds, "pool advanced = proceeds");
            }
            // per-position proceeds add up to the lot's, never more (F-4.5d, last position takes the dust)
            assertEq(lot.proceedsSettled, lot.proceeds);
        }
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter keeps no cash");
        uint256 owed = solver.refundOwed(solverA) + solver.refundOwed(solverB);
        assertEq(usdc.balanceOf(address(solver)), liveEscrow + owed, "venue holds only live escrow");
    }

    /// INV-SET-02: collateral in = collateral out. The market released `qty`; it is at the venue while open, then with
    /// the winning solver or redeeming for the pool. The adapter never keeps tokens.
    function invariant_tokensConserved() public view {
        uint256 atVenue;
        for (uint256 i; i < h.idCount(); ++i) {
            uint64 id = h.ids(i);
            Settlement memory s = adapter.settlement(id);
            assertEq(market.lotInfo(id).totalQty, s.qty, "released = settled qty");
            if (s.status == SettlementStatus.OPEN) {
                atVenue += s.qty;
            } else if (s.status == SettlementStatus.FILLED) {
                assertEq(h.solverTokens(id), s.qty, "solver got the lot");
            } else {
                assertEq(up.redemptionClaim(s.requestId).qty, s.qty, "pool redeems the lot");
            }
        }
        assertEq(fund.balanceOf(address(solver)), atVenue, "venue holds only open lots");
        assertEq(fund.balanceOf(address(adapter)), 0, "adapter keeps no tokens");
        assertEq(fund.balanceOf(address(up)), 0, "pool tokens go straight into redemption");
        assertEq(
            fund.balanceOf(address(market)), market.marketState(idTBILL).totalCollateral, "market collateral"
        );
    }

    /// INV-SET-03: no fill below the floor, every live best bid ≥ floor, floor = NAV × 99.5 % at the open.
    function invariant_floorRespected() public view {
        assertFalse(h.filledBelowFloor());
        for (uint256 i; i < h.idCount(); ++i) {
            uint64 id = h.ids(i);
            Settlement memory s = adapter.settlement(id);
            SolverLot memory l = solver.lot(id);
            assertEq(l.floorPrice, s.floorPrice);
            if (l.best != address(0)) assertGe(l.bestPrice, s.floorPrice);
            if (s.status == SettlementStatus.FILLED) assertGe(s.price, s.floorPrice);
        }
    }

    /// INV-SET-04 / INV-LIQ-01: no settlement opens while HALTED, CLOSED or CORP_ACTION.
    function invariant_noSettlementWhileHalted() public view {
        assertFalse(h.openedInForbiddenState());
    }

    /// §8.6.1: outstanding redemption claims are in NAV at cost, and only unclaimed ones.
    function invariant_claimsAtCost() public view {
        uint256 sum;
        for (uint256 i; i < h.requestCount(); ++i) {
            RedemptionClaim memory c = up.redemptionClaim(h.requestIds(i));
            if (!c.claimed) sum += c.cost;
        }
        assertEq(up.redemptionClaimsOutstanding(), sum);
    }

    function afterInvariant() external view {
        console2.log("opens", h.opens(), "fills", h.fills());
        console2.log("advances", h.advances(), "claims", h.claims());
        console2.log("borrows", h.borrows(), "openFails", h.openFails());
        console2.logBytes4(h.lastOpenErr());
    }
}

