// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ITokenHook} from "./HookToken.sol";

/// @title Reenterer: an attacker account (borrower, bidder, keeper, underwriter or lender) with a HookToken hook.
/// @notice The test arms a plan of calls. Each time one of the attacker's own transfers of the chosen token fires the
///         chosen side of the hook, the next armed call runs and its outcome (success, return or revert data) is
///         recorded, so a test can prove the protocol's guard reverted it (`ReentrancyGuardReentrantCall`) or show
///         what an unguarded path let the attacker see or do mid-transfer.
contract Reenterer is ITokenHook {
    enum Side {
        SEND, // tokensToSend: before the balances move (the attacker is the sender)
        RECEIVE // tokensReceived: after the balances moved (the attacker is the recipient)
    }

    struct Action {
        address token; // the transfer of this token triggers it
        Side side;
        address target;
        bytes data;
    }

    struct Outcome {
        bool fired;
        bool ok;
        bytes ret;
    }

    Action[] internal _plan;
    Outcome[] internal _out;
    uint256 public next;
    /// @notice While set, every incoming transfer reverts (a blocklisted or hostile recipient).
    bool public rejecting;

    /// @notice Run any call as the attacker (approve, borrow, bid, register the hook …). Bubbles a revert.
    function exec(address target, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// @notice Append a call to run on the next matching hook.
    function arm(address token, Side side, address target, bytes calldata data) external returns (uint256 i) {
        i = _plan.length;
        _plan.push(Action(token, side, target, data));
        _out.push();
    }

    function setRejecting(bool r) external {
        rejecting = r;
    }

    function outcome(uint256 i) external view returns (bool fired, bool ok, bytes memory ret) {
        Outcome storage o = _out[i];
        return (o.fired, o.ok, o.ret);
    }

    function tokensToSend(address, address, uint256) external {
        _fire(Side.SEND);
    }

    function tokensReceived(address, address, uint256) external {
        if (rejecting) revert("rejecting");
        _fire(Side.RECEIVE);
    }

    function _fire(Side side) internal {
        uint256 i = next;
        if (i >= _plan.length) return;
        Action storage a = _plan[i];
        if (a.token != msg.sender || a.side != side) return;
        next = i + 1;
        (bool ok, bytes memory ret) = a.target.call(a.data);
        _out[i] = Outcome(true, ok, ret);
    }
}
