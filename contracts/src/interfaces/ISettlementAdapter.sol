// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {ISettlementEvents} from "../libraries/Events.sol";

/// @title NAV-stack liquidation: solver venue at T+0, pool-advance fallback (Build Guide §8.8). Implemented in S4.
interface ISettlementAdapter is ISettlementEvents, ICredenceErrors {
    /// @notice Permissionless, tipped. HF < 1; state ∉ {HALTED, CORP_ACTION}.
    function openSettlement(bytes32 marketId, address[] calldata borrowers) external;
    /// @notice After the window.
    function finalize(uint64 settlementId) external;
    function venues() external view returns (address[] memory);
}
