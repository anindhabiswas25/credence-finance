// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title CredenceTimelock: the only address that changes a parameter (Build Guide §8.11, INV-GOV-01).
/// @notice OpenZeppelin `TimelockController`: `minDelay` 1 h on testnet, 48 h on mainnet. Proposer and canceller:
///         the Governance Safe. Executor: `address(0)` (anyone executes a ready operation). Admin: none, so the
///         role set can only change through the timelock itself.
contract CredenceTimelock is TimelockController {
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {}
}
