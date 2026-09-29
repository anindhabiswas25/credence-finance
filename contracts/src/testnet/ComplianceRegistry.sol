// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IComplianceRegistry} from "../interfaces/ICompliance.sol";

/// @title ComplianceRegistry: the testnet allowlist (Build Guide §8.12, R-02).
/// @notice Models an issuer allowlist. On testnet, allowlisting is self-serve through the web app (a testnet
///         attestation, no KYC) via an operator key; mainnet requires the issuer's KYC.
/// @dev `canTransfer(from, to)`: both non-zero parties must be allowlisted (mint: `to` only; burn: `from` only).
contract ComplianceRegistry is IComplianceRegistry {
    address public owner;
    mapping(address => bool) public isOperator;
    mapping(address => bool) public isAllowed;

    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnerTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != owner && !isOperator[msg.sender]) revert Unauthorized();
        _;
    }

    /// @notice onlyOwner: hand the registry to a new owner.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @inheritdoc IComplianceRegistry
    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    /// @inheritdoc IComplianceRegistry
    function setAllowed(address account, bool allowed) external onlyOperator {
        _setAllowed(account, allowed);
    }

    /// @inheritdoc IComplianceRegistry
    function setAllowedBatch(address[] calldata accounts, bool allowed) external onlyOperator {
        for (uint256 i; i < accounts.length; ++i) {
            _setAllowed(accounts[i], allowed);
        }
    }

    function _setAllowed(address account, bool allowed) internal {
        if (account == address(0)) revert ZeroAddress();
        isAllowed[account] = allowed;
        emit AllowlistSet(account, allowed);
    }

    /// @notice Compliance hook: both non-zero parties must be allowlisted.
    function canTransfer(address from, address to) external view returns (bool) {
        return (from == address(0) || isAllowed[from]) && (to == address(0) || isAllowed[to]);
    }

    /// @notice Whether `account` is allowlisted.
    function canHold(address account) external view returns (bool) {
        return isAllowed[account];
    }
}
