// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NavFixture} from "../utils/NavFixture.sol";
import {HookToken} from "./mocks/HookToken.sol";
import {Reenterer} from "./mocks/Reenterer.sol";
import {AccountingProbe} from "./mocks/AccountingProbe.sol";
import {Settlement} from "../../src/libraries/Types.sol";
import {SettlementAdapter} from "../../src/settlement/SettlementAdapter.sol";
import {SolverAuction} from "../../src/settlement/SolverAuction.sol";
import {UnderwriterPool} from "../../src/pool/UnderwriterPool.sol";

/// @title Reentrancy suite, NAV settlement (§8.8; QA-sec S4 item B, after BE-chain's 6da23ce).
/// @notice USDC carries ERC-777-style hooks. The fund token (tTBILL) is the real testnet CredenceTreasuryFund, whose
///         only hook is a view compliance check, so the attacker's control points are its USDC legs: a solver's bid
///         escrow and refund, the keeper's forwarded tips, and the borrower's refund. Each must hit a guard.
contract SettlementReentrancyTest is NavFixture {
    bytes4 internal constant REENTRANT = bytes4(keccak256("ReentrancyGuardReentrantCall()"));
    Reenterer.Side internal constant SEND = Reenterer.Side.SEND;
    Reenterer.Side internal constant RECV = Reenterer.Side.RECEIVE;

    address internal ben;
    AccountingProbe internal probe;

    function setUp() public {
        vm.warp(1_791_000_000);
        setUpNav();
        vm.etch(address(usdc), address(new HookToken("hook", "HOOK", 6)).code);
        vm.warp(_morning(1, 1));
        _seed(1_000_000e6, 250_000e6);
        ben = _borrower("ben", 1_000e18, 89_900e6);
        orc.setPrice(TBILL, 96.5e18); // HF 0.998
        probe = new AccountingProbe(market, vault, up, idTBILL);
    }

    function _attacker(bool asSolver) internal returns (Reenterer r) {
        r = new Reenterer();
        r.exec(address(usdc), abi.encodeCall(HookToken.setHook, (address(r))));
        r.exec(
            address(usdc),
            abi.encodeWithSignature("approve(address,uint256)", address(solver), type(uint256).max)
        );
        if (asSolver) {
            vm.prank(timelock);
            solver.setSolver(address(r), true);
            registry.setAllowed(address(r), true);
        }
    }

    function _assertGuarded(Reenterer r, uint256 i) internal view {
        (bool fired, bool ok, bytes memory ret) = r.outcome(i);
        assertTrue(fired, "the hook fired");
        assertFalse(ok, "the re-entry must revert");
        assertEq(bytes4(ret), REENTRANT, "reverted by the reentrancy guard");
    }

    function _open() internal returns (uint64 id) {
        vm.prank(keeper);
        id = adapter.openSettlement(idTBILL, _one(ben));
    }

    // ───────────── SolverAuction ─────────────

    function test_solver_bid() public {
        uint64 id = _open();
        Settlement memory s = adapter.settlement(id);
        Reenterer r = _attacker(true);
        usdc.mint(address(r), 200_000e6);
        r.arm(
            address(usdc),
            SEND,
            address(solver),
            abi.encodeCall(SolverAuction.bid, (id, uint256(s.floorPrice) * 2))
        );
        r.exec(address(solver), abi.encodeCall(SolverAuction.bid, (id, s.floorPrice)));
        _assertGuarded(r, 0);
        (address best,) = solver.best(id);
        assertEq(best, address(r));
    }

    /// @dev The outbid solver's refund is pushed inside the better bid: its hook re-enters the auction.
    function test_solver_outbidRefund() public {
        uint64 id = _open();
        Settlement memory s = adapter.settlement(id);
        Reenterer r = _attacker(true);
        usdc.mint(address(r), 200_000e6);
        r.exec(address(solver), abi.encodeCall(SolverAuction.bid, (id, s.floorPrice)));
        r.arm(
            address(usdc),
            RECV,
            address(solver),
            abi.encodeCall(SolverAuction.bid, (id, uint256(s.floorPrice) * 2))
        );
        _fundSolver(solverB, 200_000e6);
        uint256 min = solver.minBid(id);
        vm.prank(solverB);
        solver.bid(id, min);
        _assertGuarded(r, 0);
        (address best,) = solver.best(id);
        assertEq(best, solverB, "the re-entry could not take the lead back mid-refund");
        assertEq(usdc.balanceOf(address(r)), 200_000e6, "refunded once, in full");
    }

    /// @dev A refund the recipient refuses is owed, never blocks the better bid, and is withdrawn once.
    function test_solver_withdrawRefund() public {
        uint64 id = _open();
        Settlement memory s = adapter.settlement(id);
        Reenterer r = _attacker(true);
        usdc.mint(address(r), 200_000e6);
        r.exec(address(solver), abi.encodeCall(SolverAuction.bid, (id, s.floorPrice)));
        r.setRejecting(true);
        _fundSolver(solverB, 200_000e6);
        uint256 min = solver.minBid(id);
        vm.prank(solverB);
        solver.bid(id, min);
        uint256 owed = solver.refundOwed(address(r));
        assertGt(owed, 0, "a refused refund is owed, the better bid went through");
        r.setRejecting(false);
        r.arm(address(usdc), RECV, address(solver), abi.encodeCall(SolverAuction.withdrawRefund, ()));
        r.exec(address(solver), abi.encodeCall(SolverAuction.withdrawRefund, ()));
        _assertGuarded(r, 0);
        assertEq(usdc.balanceOf(address(r)), 200_000e6);
        assertEq(solver.refundOwed(address(r)), 0);
    }

    // ───────────── SettlementAdapter ─────────────

    /// @dev openSettlement forwards the market's FLAG tip to the keeper mid-function, before the solver window opens.
    function test_adapter_openSettlement_viaForwardedTip() public {
        Reenterer k = _attacker(false);
        k.arm(
            address(usdc),
            RECV,
            address(adapter),
            abi.encodeCall(SettlementAdapter.openSettlement, (idTBILL, _one(ben)))
        );
        k.arm(address(usdc), RECV, address(adapter), abi.encodeCall(SettlementAdapter.finalize, (1)));
        bytes memory ret =
            k.exec(address(adapter), abi.encodeCall(SettlementAdapter.openSettlement, (idTBILL, _one(ben))));
        _assertGuarded(k, 0);
        _assertGuarded(k, 1);
        assertEq(abi.decode(ret, (uint64)), 1);
    }

    function test_adapter_finalizeFill_viaForwardedTip() public {
        uint64 id = _open();
        Settlement memory s = adapter.settlement(id);
        _fundSolver(solverA, 200_000e6);
        vm.prank(solverA);
        solver.bid(id, s.floorPrice);
        vm.warp(s.endsAt);
        Reenterer k = _attacker(false);
        k.arm(address(usdc), RECV, address(adapter), abi.encodeCall(SettlementAdapter.finalize, (id)));
        k.arm(address(usdc), RECV, address(probe), abi.encodeCall(AccountingProbe.snap, ()));
        k.exec(address(adapter), abi.encodeCall(SettlementAdapter.finalize, (id)));
        _assertGuarded(k, 0);
        // the second forwarded tip (FINALIZE) comes after every position settled: the accounting is final
        (bool fired, bool ok, bytes memory snapRet) = k.outcome(1);
        assertTrue(fired && ok);
        AccountingProbe.Snap memory mid = abi.decode(snapRet, (AccountingProbe.Snap));
        AccountingProbe.Snap memory end_ = probe.snap();
        assertEq(mid.poolNav, end_.poolNav);
        assertEq(mid.vaultAssets, end_.vaultAssets);
        assertEq(mid.marketBorrows, end_.marketBorrows);
    }

    /// @dev No bid: the pool advances against a fund redemption; the keeper's forwarded tip re-enters the pool.
    function test_adapter_finalizeAdvance_andPoolClaim_viaTip() public {
        uint64 id = _open();
        vm.warp(adapter.settlement(id).endsAt);
        Reenterer k = _attacker(false);
        k.arm(
            address(usdc),
            RECV,
            address(adapter),
            abi.encodeCall(SettlementAdapter.openSettlement, (idTBILL, _one(ben)))
        );
        k.exec(address(adapter), abi.encodeCall(SettlementAdapter.finalize, (id)));
        _assertGuarded(k, 0);
        uint256 req = adapter.settlement(id).requestId;
        vm.warp(_morning(1, 2));
        vm.startPrank(issuer);
        fund.publishNav(96.5e18);
        fund.fulfillRedeem(req);
        vm.stopPrank();
        k.arm(address(usdc), RECV, address(up), abi.encodeCall(UnderwriterPool.claimRedemption, (req)));
        k.exec(address(up), abi.encodeCall(UnderwriterPool.claimRedemption, (req)));
        _assertGuarded(k, 1);
        assertEq(up.redemptionClaimsOutstanding(), 0);
    }
}
