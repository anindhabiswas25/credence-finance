// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CredenceMarket} from "../../../src/core/CredenceMarket.sol";
import {SeniorVault} from "../../../src/core/SeniorVault.sol";
import {UnderwriterPool} from "../../../src/pool/UnderwriterPool.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @notice Actors for the share-price invariants: lenders, underwriters, low-LTV borrowers (no liquidation, so no
///         loss), donors and time. After every action the handler checks that neither the vault's nor the pool's
///         share price went down, by cross-multiplication on the contracts' own virtual-share ratios:
///           vault  (totalAssets + 1) / (totalSupply + 1e6)        (OZ ERC-4626, decimals offset 6)
///           pool   (nav + 1) / (totalSupply + S),  S = 1e12     (UnderwriterPool._price)
contract SharePriceHandler is Test {
    CredenceMarket internal market;
    SeniorVault internal vault;
    UnderwriterPool internal pool;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;
    address[4] internal actors;

    uint256 internal vA; // vault totalAssets + 1
    uint256 internal vS; // vault supply + 1e6
    uint256 internal pN; // pool nav + 1
    uint256 internal pS; // pool supply + 1e12
    uint256 public ghostVaultDrops;
    uint256 public ghostVaultDustDrops; // ≤ 2 units: the accrued view floors the two fee shares apart (QA-06)
    uint256 public ghostPoolDrops;
    uint256 public ghostPoolDustDrops; // within 1 unit of the loan token per call (settlement rounding)
    uint256 public calls;

    constructor(CredenceMarket m, SeniorVault v, UnderwriterPool p, MockERC20 u, MockERC20 c, bytes32 id_) {
        (market, vault, pool, usdc, coll, id) = (m, v, p, u, c, id_);
        for (uint256 i; i < 4; ++i) {
            actors[i] = address(uint160(0xA11CE0 + i));
            vm.startPrank(actors[i]);
            usdc.approve(address(vault), type(uint256).max);
            usdc.approve(address(pool), type(uint256).max);
            usdc.approve(address(market), type(uint256).max);
            coll.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
        _record();
    }

    modifier checked() {
        ++calls;
        _;
        _check();
    }

    function _record() internal {
        (vA, vS) = (vault.totalAssets() + 1, vault.totalSupply() + 1e6);
        (pN, pS) = (pool.nav() + 1, pool.totalSupply() + 1e12);
    }

    function _check() internal {
        uint256 a = vault.totalAssets() + 1;
        uint256 s = vault.totalSupply() + 1e6;
        if (a * vS < vA * s) {
            if ((a + 2) * vS < vA * s) ++ghostVaultDrops;
            else ++ghostVaultDustDrops;
        }
        uint256 n = pool.nav() + 1;
        uint256 ps = pool.totalSupply() + 1e12;
        if (n * pS < pN * ps) {
            // a drop of less than one loan-token unit spread over the supply is rounding, anything more is a loss
            if ((n + 1) * pS < pN * ps) ++ghostPoolDrops;
            else ++ghostPoolDustDrops;
        }
        _record();
    }

    function _actor(uint256 i) internal view returns (address) {
        return actors[i % 4];
    }

    // ───────────── lenders ─────────────

    function lend(uint256 who, uint256 amt) external checked {
        address a = _actor(who);
        amt = bound(amt, 1, 2_000_000e6);
        usdc.mint(a, amt);
        vm.prank(a);
        try vault.deposit(amt, a) {} catch {}
    }

    function withdraw(uint256 who, uint256 pct) external checked {
        address a = _actor(who);
        uint256 max = vault.maxWithdraw(a);
        if (max == 0) return;
        vm.prank(a);
        try vault.withdraw(max * bound(pct, 1, 100) / 100, a, a) {} catch {}
    }

    function redeem(uint256 who, uint256 pct) external checked {
        address a = _actor(who);
        uint256 max = vault.maxRedeem(a);
        if (max == 0) return;
        vm.prank(a);
        try vault.redeem(max * bound(pct, 1, 100) / 100, a, a) {} catch {}
    }

    function requestRedeem(uint256 who, uint256 pct) external checked {
        address a = _actor(who);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        vm.prank(a);
        try vault.requestRedeem(bal * bound(pct, 1, 100) / 100, a) {} catch {}
    }

    function processQueue(uint256 n) external checked {
        vault.processQueue(bound(n, 1, 8));
    }

    // ───────────── borrowers (≤ 40% LTV: never liquidated, so never a loss) ─────────────

    function borrow(uint256 who, uint256 amt) external checked {
        address a = _actor(who);
        amt = bound(amt, 1e6, 200_000e6);
        uint256 q = amt * 1e12 * 3 / 180; // ≈ 33% LTV at $180
        coll.mint(a, q);
        vm.startPrank(a);
        try market.addCollateral(id, a, q) {} catch {}
        try market.borrow(id, amt, a) {} catch {}
        vm.stopPrank();
    }

    function repay(uint256 who, uint256 pct) external checked {
        address a = _actor(who);
        uint256 d = market.debtOf(id, a);
        if (d == 0) return;
        uint256 x = d * bound(pct, 1, 100) / 100;
        usdc.mint(a, x + 1);
        vm.prank(a);
        try market.repay(id, a, x, 0) {} catch {}
    }

    function claimFees() external checked {
        try market.claimFees(id) {} catch {}
    }

    // ───────────── underwriters ─────────────

    function underwrite(uint256 who, uint256 amt) external checked {
        address a = _actor(who);
        amt = bound(amt, 1, 1_000_000e6);
        usdc.mint(a, amt);
        vm.prank(a);
        try pool.deposit(amt, a) {} catch {}
    }

    function requestWithdraw(uint256 who, uint256 pct) external checked {
        address a = _actor(who);
        uint256 bal = pool.balanceOf(a);
        if (bal == 0) return;
        vm.prank(a);
        try pool.requestWithdraw(bal * bound(pct, 1, 100) / 100) {} catch {}
    }

    function _epochNow() internal view returns (uint64 e) {
        try pool.currentEpoch(pool.venue()) returns (uint64 x) {
            e = x;
        } catch {}
    }

    function settleEpoch(uint256 back) external checked {
        uint64 e = _epochNow();
        uint64 target = e > bound(back, 0, 3) ? e - uint64(bound(back, 0, 3)) : 0;
        try pool.settleEpoch(target) {} catch {}
    }

    function claimPool(uint256 who, uint256 back) external checked {
        address a = _actor(who);
        uint64 e = _epochNow();
        uint64 target = e > bound(back, 1, 4) ? e - uint64(bound(back, 1, 4)) : 0;
        vm.startPrank(a);
        try pool.claimWithdraw(target) {} catch {}
        try pool.claimDeposit(target) {} catch {}
        vm.stopPrank();
    }

    // ───────────── donations and time ─────────────

    function donate(bool toPool, uint256 amt) external checked {
        usdc.mint(toPool ? address(pool) : address(vault), bound(amt, 1, 1_000_000e6));
    }

    function warp(uint256 secs) external checked {
        vm.warp(block.timestamp + bound(secs, 1, 18 hours));
    }
}
