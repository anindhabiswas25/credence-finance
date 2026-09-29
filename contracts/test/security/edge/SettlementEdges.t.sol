// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NavFixture} from "../../utils/NavFixture.sol";
import {Settlement, SettlementStatus} from "../../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../../src/libraries/Errors.sol";

/// @title NAV settlement edge cases (matrix rows E-S-*, `docs/qa/edge-cases.md`).
contract SettlementEdgesTest is NavFixture {
    address internal ben;

    function setUp() public {
        vm.warp(1_791_000_000);
        setUpNav();
        vm.warp(_morning(1, 1));
        _seed(1_000_000e6, 250_000e6);
        ben = _borrower("ben", 1_000e18, 89_900e6);
        orc.setPrice(TBILL, 96.5e18); // HF 0.998
    }

    function _open() internal returns (uint64 id) {
        vm.prank(keeper);
        id = adapter.openSettlement(idTBILL, _one(ben));
    }

    /// E-S-01: the solver window's last second takes a bid; `finalize` one second early is `TooEarly`; at endsAt it
    ///         fills; a second `finalize` is `SettlementNotOpen`.
    function test_E_S01_solverWindowEdges() public {
        uint64 id = _open();
        Settlement memory s = adapter.settlement(id);
        _fundSolver(solverA, 200_000e6);
        vm.warp(s.endsAt - 1);
        vm.prank(solverA);
        solver.bid(id, s.floorPrice);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TooEarly.selector, s.endsAt));
        adapter.finalize(id);
        vm.warp(s.endsAt);
        adapter.finalize(id);
        assertEq(uint8(adapter.settlement(id).status), uint8(SettlementStatus.FILLED));
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.SettlementNotOpen.selector, id));
        adapter.finalize(id);
    }

    /// E-S-02: two solvers at the same price in one block: the second must beat the first by the minimum
    ///         increment, so a tie never displaces the incumbent.
    function test_E_S02_tieNeverDisplacesTheIncumbent() public {
        uint64 id = _open();
        Settlement memory s = adapter.settlement(id);
        _fundSolver(solverA, 200_000e6);
        _fundSolver(solverB, 200_000e6);
        vm.prank(solverA);
        solver.bid(id, s.floorPrice);
        uint256 min = solver.minBid(id);
        vm.prank(solverB);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.SolverBidTooLow.selector, s.floorPrice, min));
        solver.bid(id, s.floorPrice);
        (address best,) = solver.best(id);
        assertEq(best, solverA);
    }

    /// E-S-03: one settlement takes at most 128 positions; 129 reverts `TooManyPositions` (the keeper splits).
    function test_E_S03_moreThan128Positions() public {
        address[] memory bs = new address[](129);
        for (uint256 i; i < 129; ++i) {
            bs[i] = ben;
        }
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TooManyPositions.selector, 129, 128));
        adapter.openSettlement(idTBILL, bs);
    }

    /// E-S-04: the same borrower twice in one `openSettlement` is settled once (no double sale of the lot).
    function test_E_S04_duplicateBorrowerOpensOnce() public {
        address[] memory bs = new address[](2);
        (bs[0], bs[1]) = (ben, ben);
        vm.prank(keeper);
        uint64 id = adapter.openSettlement(idTBILL, bs);
        assertEq(adapter.settlement(id).positions, 1);
    }
}
