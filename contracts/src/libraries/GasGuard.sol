// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "./Errors.sol";

/// @title GasGuard: a caught external-call failure must not be one the caller manufactured by starving it of gas.
/// @notice Every `try … catch` in the protocol takes a fail-closed branch on failure (HALTED, no open print, no cover,
///         pool not paying). A permissionless caller could otherwise pick a gas limit at which only the inner call runs
///         out of gas (EIP-150 keeps 1/64 for the caller) and force that branch. `check(g)` in the catch, with `g`
///         the `gasleft()` read right before the call, reverts the whole transaction when the callee used up (nearly)
///         all the gas it was given. A genuine revert uses far less and keeps the catch branch (ADR-0109).
library GasGuard {
    function check(uint256 gasBefore) internal view {
        if (gasleft() < gasBefore / 63) revert ICredenceErrors.InsufficientGas();
    }
}
