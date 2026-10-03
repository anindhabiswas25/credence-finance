// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev The Robinhood `AccessControlsRegistry` views a Stock Token consults: a global pause and a blocklist.
contract MockAccessControlsRegistry {
    bool public paused;
    mapping(address => bool) public isBlocked;

    function setPaused(bool p) external {
        paused = p;
    }

    function setBlocked(address a, bool b) external {
        isBlocked[a] = b;
    }
}

/// @dev Behavioural copy of the Robinhood Stock Token implementation `Stock` on Robinhood Chain testnet (beacon
///      implementation 0xBd14156E05c6AF28ad39aA53a2AB8eB9CDf657DA, read 2026-09-30; ADR-0120): 18 decimals, ERC-8056
///      `uiMultiplier` with a scheduled `newUIMultiplier` / `effectiveAt`, `paused()` = its own pause OR the
///      registry's, and transfers / transferFrom / approve refused while paused or when the sender, `from` or `to` is
///      blocked. No `frozen()`, `issuer()`, `canHold()` or `sharesPerToken()`. `adminBurn` burns from any holder.
contract MockRobinhoodStock is ERC20 {
    error IsPaused();
    error Blocked(address account);

    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);

    address public immutable ACCESS_CONTROLLED_REGISTRY;
    bool internal _paused;
    uint256 internal _multiplier = 1e18;
    uint256 internal _next = 1e18;
    uint256 internal _at;

    constructor(string memory n, string memory s, address registry) ERC20(n, s) {
        ACCESS_CONTROLLED_REGISTRY = registry;
    }

    modifier onlyNotPaused() {
        if (paused()) revert IsPaused();
        _;
    }

    modifier onlyNotBlocked(address a) {
        if (MockAccessControlsRegistry(ACCESS_CONTROLLED_REGISTRY).isBlocked(a)) revert Blocked(a);
        _;
    }

    function paused() public view returns (bool) {
        return _paused || MockAccessControlsRegistry(ACCESS_CONTROLLED_REGISTRY).paused();
    }

    function tokenPaused() external view returns (bool) {
        return _paused;
    }

    function pause() external {
        _paused = true;
    }

    function unpause() external {
        _paused = false;
    }

    function uiMultiplier() public view returns (uint256) {
        return _at != 0 && block.timestamp >= _at ? _next : _multiplier;
    }

    function newUIMultiplier() external view returns (uint256) {
        return _next;
    }

    function effectiveAt() external view returns (uint256) {
        return _at;
    }

    function updateMultiplier(uint256 m) external onlyNotPaused {
        updateMultiplier(m, block.timestamp);
    }

    function updateMultiplier(uint256 m, uint256 at) public onlyNotPaused {
        uint256 cur = uiMultiplier();
        _multiplier = cur;
        (_next, _at) = (m, at);
        emit UIMultiplierUpdated(cur, m, at);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function adminBurn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function transfer(address to, uint256 v)
        public
        override
        onlyNotPaused
        onlyNotBlocked(to)
        onlyNotBlocked(msg.sender)
        returns (bool)
    {
        return super.transfer(to, v);
    }

    function transferFrom(address from, address to, uint256 v)
        public
        override
        onlyNotPaused
        onlyNotBlocked(from)
        onlyNotBlocked(to)
        onlyNotBlocked(msg.sender)
        returns (bool)
    {
        return super.transferFrom(from, to, v);
    }

    function approve(address spender, uint256 v)
        public
        override
        onlyNotPaused
        onlyNotBlocked(msg.sender)
        returns (bool)
    {
        return super.approve(spender, v);
    }
}
