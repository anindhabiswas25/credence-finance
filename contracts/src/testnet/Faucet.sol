// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFaucet} from "../interfaces/IFaucet.sol";

interface IMintableCollateral {
    function mint(address to, uint256 amount) external;
    function canHold(address a) external view returns (bool);
}

/// @title Faucet: testnet collateral with a 24-hour rate limit per (address, token) (Build Guide §8.12).
/// @notice Holds a capped minter role on each test token (e.g. 50 tNVDA, 20 tSPY, 100,000 tTBILL per drip).
///         Fund tokens require the caller to be allowlisted (self-serve on testnet through the web app).
contract Faucet is IFaucet {
    /// @inheritdoc IFaucet
    uint40 public constant COOLDOWN = 24 hours;

    struct Drip {
        uint256 amount;
        bool requiresAllowlist;
    }

    address public owner;
    mapping(address token => Drip) public drips;
    mapping(address account => mapping(address token => uint40)) public lastDrip;

    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnerTransferred(address(0), owner_);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @inheritdoc IFaucet
    function configure(address token, uint256 amount, bool requiresAllowlist) external {
        if (msg.sender != owner) revert Unauthorized();
        if (token == address(0)) revert ZeroAddress();
        drips[token] = Drip(amount, requiresAllowlist);
        emit DripConfigured(token, amount, requiresAllowlist);
    }

    /// @inheritdoc IFaucet
    function drip(address token) external returns (uint256 amount) {
        Drip memory d = drips[token];
        amount = d.amount;
        if (amount == 0) revert FaucetTokenNotConfigured(token);
        uint40 next = _nextDripAt(msg.sender, token);
        if (block.timestamp < next) revert FaucetCooldown(msg.sender, next);
        if (d.requiresAllowlist && !IMintableCollateral(token).canHold(msg.sender)) revert NotAllowlisted(msg.sender);
        lastDrip[msg.sender][token] = uint40(block.timestamp);
        IMintableCollateral(token).mint(msg.sender, amount);
        emit Dripped(msg.sender, token, amount);
    }

    /// @inheritdoc IFaucet
    function nextDripAt(address account, address token) external view returns (uint40) {
        return _nextDripAt(account, token);
    }

    /// @inheritdoc IFaucet
    function dripAmount(address token) external view returns (uint256) {
        return drips[token].amount;
    }

    function _nextDripAt(address account, address token) internal view returns (uint40) {
        uint40 last = lastDrip[account][token];
        return last == 0 ? 0 : last + COOLDOWN;
    }
}
