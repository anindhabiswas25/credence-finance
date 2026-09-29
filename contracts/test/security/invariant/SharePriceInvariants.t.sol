// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskFixture} from "../../utils/RiskFixture.sol";
import {SharePriceHandler} from "./SharePriceHandler.sol";

/// @title Share-price monotonicity outside losses (QA-sec S4 item C / D; Guide §15.1 "rounding / inflation attacks").
/// @notice With no liquidation in play, every flow into the vault and the pool (deposits, withdrawals, redeem queue,
///         interest, fee sweeps, epoch settlements, donations) must leave each share price at least where it was:
///         rounding always favours the remaining holders (§7.2). Complements INV-SV-01 (the vault price falls only
///         on a recorded waterfall loss) with the pool side, which §14.2 does not list.
contract SharePriceInvariantsTest is RiskFixture {
    SharePriceHandler internal h;

    function _calendarWeeks() internal pure override returns (uint256) {
        return 40; // depth 512 × up to 18 h per warp stays inside the calendar
    }

    function setUp() public {
        setUpRisk();
        _underwrite(uw1, 100_000e6);
        h = new SharePriceHandler(market, vault, up, usdc, tNVDA, idNVDA);
        targetContract(address(h));
        excludeSender(address(market));
        excludeSender(address(vault));
        excludeSender(address(up));
        excludeSender(address(house));
    }

    /// INV-QA-SP-01: the vault's share price never falls without a loss (beyond the ≤ 2-unit view dust of QA-06)
    function invariant_QA_SP01_vaultSharePriceNeverFalls() public view {
        assertEq(h.ghostVaultDrops(), 0);
    }

    /// INV-QA-SP-02: the pool's share price never falls without a loss (beyond 1 unit of settlement rounding)
    function invariant_QA_SP02_poolSharePriceNeverFalls() public view {
        assertEq(h.ghostPoolDrops(), 0);
    }

    /// INV-QA-SP-03: the vault holds the redeem-queue assets it owes (claimable) in cash
    function invariant_QA_SP03_vaultClaimablesInCash() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.claimableAssets());
    }

    function afterInvariant() external view {
        assertGt(h.calls(), 0);
    }
}
