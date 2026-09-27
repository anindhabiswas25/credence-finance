// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {IComplianceEvents} from "../libraries/Events.sol";

/// @title Compliance hook consulted by collateral tokens and the AuctionHouse (Build Guide §8.7.3, §8.12).
interface ICompliance {
    function canTransfer(address from, address to) external view returns (bool);
    function canHold(address account) external view returns (bool);
}

/// @title The testnet allowlist registry.
interface IComplianceRegistry is ICompliance, IComplianceEvents, ICredenceErrors {
    function setAllowed(address account, bool allowed) external; // onlyOperator
    function setAllowedBatch(address[] calldata accounts, bool allowed) external; // onlyOperator
    function setOperator(address operator, bool allowed) external; // onlyOwner
    function isAllowed(address account) external view returns (bool);
    function isOperator(address operator) external view returns (bool);
}
