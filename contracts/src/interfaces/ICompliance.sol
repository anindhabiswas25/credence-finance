// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {IComplianceEvents} from "../libraries/Events.sol";

/// @title Compliance hook consulted by collateral tokens and the AuctionHouse (Build Guide §8.7.3, §8.12).
interface ICompliance {
    /// @notice Whether `from` may send to `to` (both allowlisted).
    function canTransfer(address from, address to) external view returns (bool);
    /// @notice Whether `account` may hold the token.
    function canHold(address account) external view returns (bool);
}

/// @title The testnet allowlist registry.
interface IComplianceRegistry is ICompliance, IComplianceEvents, ICredenceErrors {
    /// @notice onlyOperator: add or remove one account.
    function setAllowed(address account, bool allowed) external;
    /// @notice onlyOperator: add or remove several accounts.
    function setAllowedBatch(address[] calldata accounts, bool allowed) external;
    /// @notice onlyOwner: grant or revoke the operator role.
    function setOperator(address operator, bool allowed) external;
    /// @notice Whether `account` is allowlisted.
    function isAllowed(address account) external view returns (bool);
    /// @notice Whether `operator` may edit the allowlist.
    function isOperator(address operator) external view returns (bool);
}
