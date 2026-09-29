// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SolverLot} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {ISettlementEvents} from "../libraries/Events.sol";

/// @title A settlement venue for fund collateral (Build Guide §8.8). Native SolverAuction on testnet.
/// @notice The adapter transfers `qty` tokens to the venue before `open`. `finalize` (at or after `endsAt`) sends the
///         tokens to the winner and its payment to the adapter, or returns the tokens to the adapter if nobody bid.
interface ISolverVenue is ICredenceErrors {
    /// @notice onlyAdapter.
    function open(uint64 settlementId, address token, uint256 qty, uint256 floorPrice, uint40 endsAt) external;
    function best(uint64 settlementId) external view returns (address solver, uint256 price);
    /// @notice onlyAdapter, at or after `endsAt`.
    function finalize(uint64 settlementId) external returns (bool filled, uint256 proceeds);
}

/// @title The native allowlisted solver auction (testnet ISolverVenue). Interface v3 (S4, ADR-0111).
interface ISolverAuction is ISolverVenue, ISettlementEvents {
    /// @notice Allowlisted solvers only (and the fund's `canHold`), before `endsAt`; price ≥ floor and
    ///         ≥ 1.0001 × best (rounded up). Escrows qty × price in USDC (rounded up). The outbid solver is
    ///         refunded at once (or, if the push fails, credited for `withdrawRefund`).
    function bid(uint64 settlementId, uint256 price) external;
    function setSolver(address solver, bool allowed) external; // onlyTimelock

    // ── v3 ──
    /// @notice Once, by the timelock: the adapter that may open and finalize windows, and the payment token.
    function initializeWiring(address adapter_, address loanToken_) external;
    /// @notice Pays a refund whose push failed.
    function withdrawRefund() external returns (uint256 amount);
    function isSolver(address solver) external view returns (bool);
    function lot(uint64 settlementId) external view returns (SolverLot memory);
    /// @notice The minimum next bid: max(floor, best × 1.0001 rounded up).
    function minBid(uint64 settlementId) external view returns (uint256);
    function refundOwed(address solver) external view returns (uint256);
    function adapter() external view returns (address);
    function loanToken() external view returns (address);
}
