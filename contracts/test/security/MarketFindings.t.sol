// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {MarketState} from "../../src/libraries/Types.sol";

/// @title Lending-core findings (QA-sec S4; triage QA-05, QA-06). Same convention as AuctionFindings: a `finding` test
///        asserts the fixed behaviour and runs only with QA_FINDINGS=1; its companion pins today's behaviour.
contract MarketFindingsTest is RiskFixture {
    modifier finding() {
        if (!vm.envOr("QA_FINDINGS", false)) vm.skip(true);
        _;
    }

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

    /// @notice Today: the accrued view of senior supply can fall by one unit with time alone, because the pool's and
    ///         the treasury's 10% shares are floored separately (i = 290 → 29 + 29 → 232 < 233 at i = 289).
    function test_QA06_accruedSeniorSupplyViewDipsToday() public {
        (uint256 b, uint256 a) = _dip();
        emit log_named_uint("senior supply before", b);
        emit log_named_uint("senior supply 60 s later", a);
        assertLt(a, b, "time alone lowered senior supply");
        assertLe(b - a, 2, "dust only");
    }

    /// @notice FINDING QA-06 (Low, BE-chain). Senior supply (and so `vault.totalAssets()`, the vault share price) must
    ///         never fall with time alone (INV-SV-01): floor the fee total once (fees = i × (ρJ + ρp) / BPS, fp = i × ρJ /
    ///         BPS, ft = fees − fp), so the senior remainder is non-decreasing in i.
    function test_QA06_accruedSeniorSupplyNeverFallsWithTime() public finding {
        (uint256 b, uint256 a) = _dip();
        assertGe(a, b);
    }

    /// @notice FINDING QA-05 (Low, BE-chain). ERC-4626 `deposit` must return the shares the receiver got: on the first
    ///         deposit it returns 1e3 more (the dead shares come out of the depositor's mint after the return value is
    ///         computed), so an integrator that books the return value over-counts.
    function test_QA05_firstDepositReturnsTheSharesMinted() public finding {
        SeniorVaultLike v = SeniorVaultLike(_freshVault());
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(v), 1_000e6);
        uint256 ret = v.deposit(1_000e6, address(this));
        assertEq(ret, v.balanceOf(address(this)));
    }

    function test_QA05_firstDepositReturnValueToday() public {
        SeniorVaultLike v = SeniorVaultLike(_freshVault());
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(v), 1_000e6);
        uint256 ret = v.deposit(1_000e6, address(this));
        assertEq(ret - v.balanceOf(address(this)), 1e3);
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
