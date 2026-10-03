// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IKeeperTips} from "../interfaces/IKeeperTips.sol";
import {KeeperJob} from "../libraries/Types.sol";

/// @title KeeperTips: a USDC tip budget for the permissionless keeper jobs (Build Guide §8.10).
/// @notice `pay` never reverts: an empty budget, a failing transfer or an unknown job pays nothing, so an unfunded
///         budget can never block a liquidation. Only wired money contracts (payers) may call it.
contract KeeperTips is IKeeperTips {
    using SafeERC20 for IERC20;

    address public immutable timelock;
    address public immutable token;
    address internal immutable deployer;
    bool internal wired;

    mapping(uint8 job => uint256) public tipFor;
    mapping(address => bool) public isPayer;

    constructor(address timelock_, address token_) {
        if (timelock_ == address(0) || token_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
        token = token_;
        deployer = msg.sender;
        // testnet defaults (§8.10), loan units of a 6-decimal USDC
        _setTip(KeeperJob.ENFORCE_BELL, 2e6);
        _setTip(KeeperJob.FLAG, 2e6);
        _setTip(KeeperJob.FIX_LOTS, 2e6);
        _setTip(KeeperJob.CLEAR, 2e6);
        _setTip(KeeperJob.SETTLE, 1e6);
        _setTip(KeeperJob.OPEN_SETTLEMENT, 2e6);
        _setTip(KeeperJob.FINALIZE_SETTLEMENT, 2e6);
        _setTip(KeeperJob.EPOCH, 1e6);
    }

    /// @inheritdoc IKeeperTips
    function initializeWiring(address[] calldata payers) external {
        if (msg.sender != deployer) revert Unauthorized();
        if (wired) revert AlreadyWired();
        wired = true;
        for (uint256 i; i < payers.length; ++i) {
            _setPayer(payers[i], true);
        }
    }

    /// @inheritdoc IKeeperTips
    function setPayer(address payer, bool allowed) external {
        if (msg.sender != timelock) revert Unauthorized();
        _setPayer(payer, allowed);
    }

    /// @inheritdoc IKeeperTips
    function setTip(uint8 job, uint256 amount) external {
        if (msg.sender != timelock) revert Unauthorized();
        _setTip(job, amount);
    }

    /// @inheritdoc IKeeperTips
    function pay(address keeper, uint8 job) external returns (uint256 paid) {
        if (!isPayer[msg.sender]) revert Unauthorized();
        uint256 owed = tipFor[job];
        if (owed == 0 || keeper == address(0)) return 0;
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal < owed) {
            emit TipSkipped(keeper, job, owed);
            return 0;
        }
        // A token that reverts (e.g. a blocklisted keeper) must not revert the caller's liquidation.
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (keeper, owed)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) {
            emit TipSkipped(keeper, job, owed);
            return 0;
        }
        emit TipPaid(keeper, job, owed);
        return owed;
    }

    /// @inheritdoc IKeeperTips
    function budget() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function _setTip(uint8 job, uint256 amount) internal {
        tipFor[job] = amount;
        emit TipSet(job, amount);
    }

    function _setPayer(address payer, bool allowed) internal {
        if (payer == address(0)) revert ZeroAddress();
        isPayer[payer] = allowed;
        emit PayerSet(payer, allowed);
    }
}
