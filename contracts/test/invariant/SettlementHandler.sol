// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ClockState, Settlement, SettlementStatus, SolverLot, LotInfo} from "../../src/libraries/Types.sol";
import {CredenceMarket} from "../../src/core/CredenceMarket.sol";
import {UnderwriterPool} from "../../src/pool/UnderwriterPool.sol";
import {SettlementAdapter} from "../../src/settlement/SettlementAdapter.sol";
import {SolverAuction} from "../../src/settlement/SolverAuction.sol";
import {CredenceTreasuryFund} from "../../src/testnet/CredenceTreasuryFund.sol";
import {ComplianceRegistry} from "../../src/testnet/ComplianceRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarketClock} from "../mocks/MockMarketClock.sol";
import {MockMarketOracle} from "../mocks/MockMarketOracle.sol";

struct NavSys {
    CredenceMarket market;
    UnderwriterPool pool;
    SettlementAdapter adapter;
    SolverAuction venue;
    CredenceTreasuryFund fund;
    ComplianceRegistry registry;
    MockERC20 usdc;
    MockMarketClock clk;
    MockMarketOracle orc;
    bytes32 id;
    bytes32 asset;
    address issuer;
    address[2] solvers;
}

/// @notice Drives the NAV settlement stack for the settlement invariants: borrows, NAV moves, clock states, the issuer
///         gate, openSettlement, solver bids, finalize, and T+1 redemption claims. Ghost variables record what each
///         settlement paid and moved, and whether any settlement ever opened while the clock forbade it.
contract SettlementHandler is Test {
    NavSys internal s;
    address[4] internal borrowers;
    uint256 internal constant NAV0 = 100e18;

    // ghosts
    uint64[] public ids;
    mapping(uint64 => uint256) public solverPaid; // what the winning solver paid for a FILLED settlement
    mapping(uint64 => uint256) public solverTokens; // fund tokens the winning solver received
    uint256[] public requestIds;
    bool public openedInForbiddenState;
    bool public filledBelowFloor;
    uint256 public opens;
    uint256 public fills;
    uint256 public advances;
    uint256 public claims;
    uint256 public borrows;
    uint256 public openFails;
    bytes4 public lastOpenErr;

    constructor(NavSys memory sys) {
        s = sys;
        for (uint256 i; i < 4; ++i) {
            borrowers[i] = makeAddr(string(abi.encodePacked("navB", vm.toString(i)))); // allowlisted by the test
        }
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function requestCount() external view returns (uint256) {
        return requestIds.length;
    }

    function borrowerList() external view returns (address[4] memory) {
        return borrowers;
    }

    // ───────────── borrowers and the NAV ─────────────

    function borrow(uint256 who, uint256 shares, uint256 ltvBps) external {
        address b = borrowers[who % 4];
        if (s.clk.state(s.asset) != ClockState.REGULAR) return;
        shares = bound(shares, 10e18, 2_000e18);
        vm.prank(s.issuer);
        s.fund.mint(b, shares);
        vm.startPrank(b);
        s.fund.approve(address(s.market), shares);
        s.market.addCollateral(s.id, b, shares);
        vm.stopPrank();
        uint256 lim = s.market.borrowLimitLtv(s.id, b);
        uint256 ltv = s.market.ltv(s.id, b);
        if (ltv + 0.01e18 >= lim) return;
        uint256 value = s.market.position(s.id, b).collateral * s.orc.valuationPrice(s.asset) / 1e30;
        uint256 room = (lim - ltv - 0.005e18) * value / 1e18;
        uint256 amt = bound(ltvBps, 5_000, 10_000) * room / 10_000; // leveraged book: HF < 1 must be reachable
        if (amt == 0 || amt > s.market.liquidity(s.id)) return;
        vm.prank(b);
        try s.market.borrow(s.id, amt, b) {
            ++borrows;
        } catch {}
    }

    function navMove(uint256 pctDownBps, bool up) external {
        uint256 p = s.orc.valuationPrice(s.asset);
        uint256 d = bound(pctDownBps, 0, up ? 150 : 800);
        p = up ? p * (10_000 + d) / 10_000 : p * (10_000 - d) / 10_000;
        if (p < 80e18) p = 80e18;
        if (p > 120e18) p = 120e18;
        s.orc.setPrice(s.asset, p);
    }

    /// @dev Sets the NAV so borrower `who` sits at HF ∈ [0.95, 1.0) (a small NAV move on a 90 % LTV book).
    function stress(uint256 who, uint256 hfBps) external {
        address b = borrowers[who % 4];
        uint256 debt = s.market.debtOf(s.id, b);
        uint256 q = s.market.position(s.id, b).collateral;
        if (debt == 0 || q == 0) return;
        uint256 hf = bound(hfBps, 9_500, 9_999);
        // HF = q × p × LT / D  →  p = HF × D / (q × LT)
        uint256 p = hf * debt * 1e12 * 1e18 / 10_000 * 1e18 / (q * 0.93e18);
        if (p < 50e18 || p > 150e18) return;
        s.orc.setPrice(s.asset, p);
    }

    function clockState(uint256 seed) external {
        uint256 k = seed % 6;
        if (k <= 2) s.clk.setState(s.asset, ClockState.REGULAR);
        else if (k == 3) s.clk.setState(s.asset, ClockState.HALTED);
        else if (k == 4) s.clk.setState(s.asset, ClockState.CLOSED);
        else s.clk.setState(s.asset, ClockState.CORP_ACTION);
    }

    function gate(bool on) external {
        vm.prank(s.issuer);
        s.fund.setRedemptionsGated(on);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 20 minutes));
    }

    // ───────────── settlement ─────────────

    function open(uint256 mask) external {
        address[] memory bs = new address[](4);
        uint256 n;
        for (uint256 i; i < 4; ++i) {
            if ((mask >> i) & 1 == 1 || mask % 5 == 0) bs[n++] = borrowers[i];
        }
        if (n == 0) return;
        assembly {
            mstore(bs, n)
        }
        ClockState st = s.clk.state(s.asset);
        try s.adapter.openSettlement(s.id, bs) returns (uint64 id) {
            if (st == ClockState.HALTED || st == ClockState.CLOSED || st == ClockState.CORP_ACTION) {
                openedInForbiddenState = true;
            }
            ids.push(id);
            ++opens;
        } catch (bytes memory err) {
            ++openFails;
            lastOpenErr = bytes4(err);
        }
    }

    function bid(uint256 who, uint256 which, uint256 raiseBps) external {
        if (ids.length == 0) return;
        uint64 id = ids[which % ids.length];
        SolverLot memory l = s.venue.lot(id);
        if (l.finalized || block.timestamp >= l.endsAt) return;
        address solver = s.solvers[who % 2];
        uint256 price = s.venue.minBid(id) * (10_000 + bound(raiseBps, 0, 300)) / 10_000;
        uint256 need = (uint256(l.qty) * price * 1e6 + 1e36 - 1) / 1e36;
        s.usdc.mint(solver, need);
        vm.startPrank(solver);
        s.usdc.approve(address(s.venue), need);
        try s.venue.bid(id, price) {} catch {}
        vm.stopPrank();
    }

    function finalize(uint256 which) external {
        if (ids.length == 0) return;
        uint64 id = ids[which % ids.length];
        Settlement memory before = s.adapter.settlement(id);
        if (before.status != SettlementStatus.OPEN || block.timestamp < before.endsAt) return;
        SolverLot memory l = s.venue.lot(id);
        uint256 tokBefore = l.best == address(0) ? 0 : s.fund.balanceOf(l.best);
        try s.adapter.finalize(id) {
            Settlement memory x = s.adapter.settlement(id);
            if (x.status == SettlementStatus.FILLED) {
                ++fills;
                solverPaid[id] = l.escrow;
                solverTokens[id] = s.fund.balanceOf(x.solver) - tokBefore;
                if (x.price < x.floorPrice) filledBelowFloor = true;
            } else {
                ++advances;
                requestIds.push(x.requestId);
            }
        } catch {}
    }

    /// @dev T+1: the issuer fulfils a pending request at the current NAV, then anyone claims it for the pool.
    function fulfillAndClaim(uint256 which) external {
        if (requestIds.length == 0) return;
        uint256 r = requestIds[which % requestIds.length];
        if (s.fund.pendingRedeemRequest(r, address(s.pool)) != 0) {
            vm.prank(s.issuer);
            try s.fund.fulfillRedeem(r) {} catch {}
        }
        if (s.fund.claimableRedeemRequest(r, address(s.pool)) != 0) {
            try s.pool.claimRedemption(r) {
                ++claims;
            } catch {}
        }
    }

    function repay(uint256 who, uint256 amt) external {
        address b = borrowers[who % 4];
        uint256 debt = s.market.debtOf(s.id, b);
        if (debt == 0) return;
        amt = bound(amt, 1, debt);
        s.usdc.mint(b, amt);
        vm.startPrank(b);
        s.usdc.approve(address(s.market), amt);
        try s.market.repay(s.id, b, amt, 0) {} catch {}
        vm.stopPrank();
    }

    function lotInfo(uint64 id) external view returns (LotInfo memory) {
        return s.market.lotInfo(id);
    }
}
