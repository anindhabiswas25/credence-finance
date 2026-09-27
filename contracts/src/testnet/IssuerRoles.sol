// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {ICollateralTokenEvents} from "../libraries/Events.sol";

/// @title Issuer + capped-minter roles shared by the testnet collateral tokens.
/// @dev The issuer (Credence ops multisig on testnet) mints without a cap; a minter (the Faucet) mints up to `cap`
///      in total. Minting is the only thing a minter can do.
abstract contract IssuerRoles is ICollateralTokenEvents, ICredenceErrors {
    address internal _issuer;
    mapping(address minter => uint256) public minterCap;
    mapping(address minter => uint256) public minterMinted;

    constructor(address issuer_) {
        if (issuer_ == address(0)) revert ZeroAddress();
        _issuer = issuer_;
        emit IssuerTransferred(address(0), issuer_);
    }

    modifier onlyIssuer() {
        if (msg.sender != _issuer) revert Unauthorized();
        _;
    }

    function transferIssuer(address newIssuer) external onlyIssuer {
        if (newIssuer == address(0)) revert ZeroAddress();
        emit IssuerTransferred(_issuer, newIssuer);
        _issuer = newIssuer;
    }

    /// @notice Set a minter's total cap (0 revokes). Already-minted amounts are kept.
    function setMinter(address minter, uint256 cap) external onlyIssuer {
        if (minter == address(0)) revert ZeroAddress();
        minterCap[minter] = cap;
        emit MinterSet(minter, cap);
    }

    /// @dev Checks the caller's right to mint `amount`, and books a minter's usage.
    function _authorizeMint(uint256 amount) internal {
        if (msg.sender == _issuer) return;
        uint256 used = minterMinted[msg.sender] + amount;
        if (used > minterCap[msg.sender]) revert Unauthorized();
        minterMinted[msg.sender] = used;
    }
}
