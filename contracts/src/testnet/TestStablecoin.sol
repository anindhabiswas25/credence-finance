// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IssuerRoles} from "./IssuerRoles.sol";

/// @title TestStablecoin: a testnet loan token (tUSDG on Robinhood Chain testnet; ADR-0120).
/// @notice No USDG test token is documented for Robinhood Chain testnet, so the equity stack lends this: 6 decimals
///         like USDG, minted by its issuer (the Ops Safe) and by capped minters (the Faucet). Labelled a test asset.
contract TestStablecoin is IssuerRoles, ERC20, ERC20Permit {
    uint8 internal immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address issuer_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        IssuerRoles(issuer_)
    {
        _decimals = decimals_;
    }

    /// @notice The issuer, or a minter within its cap.
    function mint(address to, uint256 amount) external {
        _authorizeMint(amount);
        _mint(to, amount);
    }

    /// @notice The issuer.
    function issuer() external view returns (address) {
        return _issuer;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
