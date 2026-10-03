// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CredenceMarket} from "../../../src/core/CredenceMarket.sol";
import {SeniorVault} from "../../../src/core/SeniorVault.sol";
import {UnderwriterPool} from "../../../src/pool/UnderwriterPool.sol";

/// @notice Read-only reentrancy probe: every accounting view another contract (or an integrator) prices from. An
///         attacker's hook calls `snap()` mid-transfer; the suite compares it with `snap()` after the transaction. A
///         difference is a window in which a second contract (or an integrator) reads a half-updated state.
contract AccountingProbe {
    struct Snap {
        uint256 vaultAssets;
        uint256 vaultSupply;
        uint256 poolNav;
        uint256 poolSupply;
        uint256 poolFreeCash;
        uint256 marketLiquidity;
        uint256 marketBorrows;
    }

    CredenceMarket internal immutable market;
    SeniorVault internal immutable vault;
    UnderwriterPool internal immutable pool;
    bytes32 internal immutable id;

    constructor(CredenceMarket m, SeniorVault v, UnderwriterPool p, bytes32 id_) {
        (market, vault, pool, id) = (m, v, p, id_);
    }

    function snap() external view returns (Snap memory s) {
        s.vaultAssets = vault.totalAssets();
        s.vaultSupply = vault.totalSupply();
        s.poolNav = pool.nav();
        s.poolSupply = pool.totalSupply();
        s.poolFreeCash = pool.freeCash();
        s.marketLiquidity = market.liquidity(id);
        s.marketBorrows = market.marketState(id).totalBorrowAssets;
    }
}
