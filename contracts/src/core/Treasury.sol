// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITreasury} from "../interfaces/ITreasury.sol";

/// @title Treasury: receives the protocol fee and ⅓ of penalties; funds keeper tips (Build Guide §8.10).
/// @notice Every outflow is timelocked. Inflows are plain transfers.
contract Treasury is ITreasury {
    using SafeERC20 for IERC20;

    address public immutable timelock;
    address public immutable token;
    address public immutable tips;

    constructor(address timelock_, address token_, address tips_) {
        if (timelock_ == address(0) || token_ == address(0) || tips_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
        token = token_;
        tips = tips_;
    }

    /// @inheritdoc ITreasury
    function fundTips(uint256 amount) external {
        if (msg.sender != timelock) revert Unauthorized();
        IERC20(token).safeTransfer(tips, amount);
        emit TipsFunded(amount);
    }

    /// @inheritdoc ITreasury
    function withdraw(address token_, address to, uint256 amount) external {
        if (msg.sender != timelock) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token_).safeTransfer(to, amount);
        emit Withdrawn(token_, to, amount);
    }
}
