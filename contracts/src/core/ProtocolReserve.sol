// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {IProtocolReserve} from "../interfaces/IProtocolReserve.sol";
import {ICredenceMarket} from "../interfaces/ICredenceMarket.sol";
import {GasGuard} from "../libraries/GasGuard.sol";

/// @title ProtocolReserve: the second loss layer after the Underwriter Pool (Build Guide §8.10, Architecture §3.6).
/// @notice Receives ⅓ of penalties and a share of the protocol fee up to `targetSize` = max(targetFloor,
///         targetBps × Σ market borrows); anything above the target flows to the treasury. Only the market may draw
///         from it (`cover`), and it pays min(s, balance).
contract ProtocolReserve is IProtocolReserve {
    using SafeERC20 for IERC20;

    address public immutable timelock;
    address public immutable token;
    address public immutable treasury;
    address internal immutable deployer;
    address public market;

    /// @dev Floor of the target (loan units), set by the timelock; the effective target is the larger of the two.
    uint256 internal targetFloor;
    uint16 public targetBps = 500; // 5% of total borrows (§12.2)

    constructor(address timelock_, address token_, address treasury_) {
        if (timelock_ == address(0) || token_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
        token = token_;
        treasury = treasury_;
        deployer = msg.sender;
    }

    /// @inheritdoc IProtocolReserve
    function initializeWiring(address market_) external {
        if (msg.sender != deployer) revert Unauthorized();
        if (market != address(0)) revert AlreadyWired();
        if (market_ == address(0)) revert ZeroAddress();
        market = market_;
        emit MarketSet(market_);
    }

    /// @inheritdoc IProtocolReserve
    function setTargetSize(uint256 target) external {
        if (msg.sender != timelock) revert Unauthorized();
        targetFloor = target;
        emit TargetSizeSet(target);
    }

    /// @inheritdoc IProtocolReserve
    function setTargetBps(uint16 bps) external {
        if (msg.sender != timelock) revert Unauthorized();
        if (bps > 10_000) revert InvalidParam();
        targetBps = bps;
        emit TargetBpsSet(bps);
    }

    /// @inheritdoc IProtocolReserve
    /// @dev Pulls `amount` from the caller (it must approve first). The part above the target goes to the treasury.
    function fund(uint256 amount) external {
        if (amount == 0) return;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 target = targetSize();
        uint256 overflow = bal > target ? FPM.min(bal - target, amount) : 0;
        if (overflow != 0) IERC20(token).safeTransfer(treasury, overflow);
        emit ReserveFunded(amount - overflow, overflow);
    }

    /// @inheritdoc IProtocolReserve
    /// @dev Pays min(s, balance) to the market (the waterfall's second layer).
    function cover(uint256 s) external returns (uint256 paid) {
        if (msg.sender != market) revert Unauthorized();
        paid = FPM.min(s, IERC20(token).balanceOf(address(this)));
        if (paid != 0) IERC20(token).safeTransfer(market, paid);
        emit ReserveCovered(s, paid);
    }

    /// @inheritdoc IProtocolReserve
    function balance() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @inheritdoc IProtocolReserve
    function targetSize() public view returns (uint256) {
        uint256 byBorrows;
        if (market != address(0)) {
            uint256 g0 = gasleft();
            try ICredenceMarket(market).totalBorrowsAll() returns (uint256 b) {
                byBorrows = FPM.fullMulDiv(b, targetBps, 10_000);
            } catch {
                GasGuard.check(g0);
            }
        }
        return FPM.max(targetFloor, byBorrows);
    }
}
