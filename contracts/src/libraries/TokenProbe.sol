// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICompliance} from "../interfaces/ICompliance.sol";

/// @notice The compliance surface of a Robinhood Stock Token (ADR-0120): a pause (the token's or its registry's) and a
///         registry-wide blocklist. Transfers revert while paused, or when the sender, `from` or `to` is blocked.
interface IStockTokenCompliance {
    function paused() external view returns (bool);
    function ACCESS_CONTROLLED_REGISTRY() external view returns (address);
}

/// @notice The Robinhood `AccessControlsRegistry` view the tokens consult.
interface IAccessControlsRegistry {
    function isBlocked(address account) external view returns (bool);
}

/// @title TokenProbe: what a collateral token says about a holder, across the token kinds Credence lists (ADR-0120).
/// @dev Our test tokens and the treasury fund expose `canHold` / `frozen`; a Robinhood Stock Token exposes `paused` and
///      a blocklist registry instead. Tokens are listed by the timelock, so the probes trust their gas use.
library TokenProbe {
    /// @notice True if `who` cannot receive the token: `canHold` when the token has it, else the Robinhood registry's
    ///         `isBlocked`, else false (an open token).
    function blocked(address token, address who) internal view returns (bool) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(ICompliance.canHold, (who)));
        if (ok && ret.length >= 32) return !abi.decode(ret, (bool));
        (ok, ret) = token.staticcall(abi.encodeCall(IStockTokenCompliance.ACCESS_CONTROLLED_REGISTRY, ()));
        if (!ok || ret.length < 32) return false;
        address reg = abi.decode(ret, (address));
        if (reg == address(0) || reg.code.length == 0) return false;
        (ok, ret) = reg.staticcall(abi.encodeCall(IAccessControlsRegistry.isBlocked, (who)));
        return ok && ret.length >= 32 && abi.decode(ret, (bool));
    }
}
