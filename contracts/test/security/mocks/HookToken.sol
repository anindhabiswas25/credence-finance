// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {MockERC20} from "../../mocks/MockERC20.sol";

/// @notice The two callbacks of an ERC-777-style token (tokensToSend before the balances move, tokensReceived after),
///         which is the shape a collateral token's transfer hook takes (§15.1 "reentrancy via the collateral token
///         hook").
interface ITokenHook {
    function tokensToSend(address from, address to, uint256 amount) external;
    function tokensReceived(address from, address to, uint256 amount) external;
}

/// @title HookToken: a malicious-by-design collateral / loan token for the reentrancy suite (QA-sec, S4).
/// @notice A MockERC20 whose every transfer calls a hook that the sender and the recipient registered for themselves
///         (like ERC-1820): `tokensToSend` on the sender before the balances move and `tokensReceived` on the recipient
///         after. So any attacker-controlled account (borrower, bidder, keeper, underwriter, lender) gets control flow
///         in the middle of every protocol transfer to or from it.
/// @dev Storage-compatible with MockERC20 (it only appends `hookOf`), so the suite can `vm.etch` its runtime code over
///      the fixture's USDC and collateral tokens and keep their balances: every protocol contract then runs against a
///      hooked token without any change to the fixture.
contract HookToken is MockERC20 {
    mapping(address account => address hook) public hookOf;

    constructor(string memory n, string memory s, uint8 d) MockERC20(n, s, d) {}

    /// @notice Register (or clear, with 0) the hook called on the caller's own transfers.
    function setHook(address hook) external {
        hookOf[msg.sender] = hook;
    }

    function _update(address from, address to, uint256 value) internal override {
        address hf = from == address(0) ? address(0) : hookOf[from];
        if (hf != address(0)) ITokenHook(hf).tokensToSend(from, to, value);
        super._update(from, to, value);
        address ht = to == address(0) ? address(0) : hookOf[to];
        if (ht != address(0)) ITokenHook(ht).tokensReceived(from, to, value);
    }
}
