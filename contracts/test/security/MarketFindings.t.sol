// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {MarketState} from "../../src/libraries/Types.sol";

/// @title Lending-core findings (QA-sec S4; triage QA-05, QA-06). Regression tests of the fixes in 61761b9.
contract MarketFindingsTest is RiskFixture {
    function setUp() public {
        setUpRisk();
        _underwrite(uw1, 100_000e6);
    }

    /// @dev A $7 loan left alone: step time forward 60 s at a time (one unit of interest every ~225 s) until the
    ///      accrued view of senior supply changes, and return the first step at which it went down, if any.
    function _dip() internal returns (uint256 before, uint256 after_) {
        _position(makeAddr("b"), idNVDA, tNVDA, 1e18, 7e6);
        before = market.marketState(idNVDA).totalSupplyAssets;
        uint256 t = vm.getBlockTimestamp(); // via-IR may reuse one read of block.timestamp across the loop
        for (uint256 i; i < 3_000; ++i) {
            t += 60;
            vm.warp(t);
            after_ = market.marketState(idNVDA).totalSupplyAssets;
            if (after_ < before) return (before, after_);
            before = after_;
        }
    }

    /// @notice Regression of QA-06 (Low, fixed 61761b9). Senior supply (and so `vault.totalAssets()`, the vault share price) must
    ///         never fall with time alone (INV-SV-01): floor the fee total once (fees = i × (ρJ + ρp) / BPS, fp = i × ρJ /
    ///         BPS, ft = fees − fp), so the senior remainder is non-decreasing in i.
    function test_QA06_accruedSeniorSupplyNeverFallsWithTime() public {
        (uint256 b, uint256 a) = _dip();
        assertGe(a, b);
    }

    /// @notice Regression of QA-05 (Low, fixed 61761b9). ERC-4626 `deposit` must return the shares the receiver got: on the first
    ///         deposit it returns 1e3 more (the dead shares come out of the depositor's mint after the return value is
    ///         computed), so an integrator that books the return value over-counts.
    function test_QA05_firstDepositReturnsTheSharesMinted() public {
        SeniorVaultLike v = SeniorVaultLike(_freshVault());
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(v), 1_000e6);
        uint256 ret = v.deposit(1_000e6, address(this));
        assertEq(ret, v.balanceOf(address(this)));
    }

    function _freshVault() internal returns (address) {
        return deployCode(
            "SeniorVault.sol:SeniorVault",
            abi.encode(address(usdc), "v", "v", timelock, address(market), allocator)
        );
    }
}

interface SeniorVaultLike {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
}
