// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {ISettlementEvents} from "../libraries/Events.sol";

/// @title A settlement venue for fund collateral (Build Guide §8.8). Native SolverAuction on testnet.
interface ISolverVenue is ICredenceErrors {
    function open(uint64 settlementId, address token, uint256 qty, uint256 floorPrice, uint40 endsAt) external;
    function best(uint64 settlementId) external view returns (address solver, uint256 price);
    function finalize(uint64 settlementId) external returns (bool filled, uint256 proceeds);
}

/// @title The native allowlisted solver auction (testnet ISolverVenue). Implemented in S4.
interface ISolverAuction is ISolverVenue, ISettlementEvents {
    /// @notice Allowlisted solvers only; price ≥ floor and ≥ 1.0001 × best; escrows qty × price. Outbid → refunded.
    function bid(uint64 settlementId, uint256 price) external;
    function setSolver(address solver, bool allowed) external; // onlyTimelock
}
