// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {IKeeperTipsEvents} from "../libraries/Events.sol";

/// @title Keeper tip budget (Build Guide §8.10). Never reverts on an empty budget. Interface v1.
interface IKeeperTips is IKeeperTipsEvents, ICredenceErrors {
    /// @notice onlyPayer (wired money contracts). Pays min(tip, budget); never reverts for lack of budget.
    function pay(address keeper, uint8 job) external returns (uint256 paid);
    /// @notice onlyTimelock: the tip paid for a keeper job.
    function setTip(uint8 job, uint256 amount) external;
    /// @notice The tip paid for a keeper job (loan units).
    function tipFor(uint8 job) external view returns (uint256);
    /// @notice The tip budget held by this contract.
    function budget() external view returns (uint256);
    /// @notice The tip token (USDC).
    function token() external view returns (address);

    // ── v1 additions ──
    /// @notice Once, by the deployer: the wired money contracts allowed to call `pay`.
    function initializeWiring(address[] calldata payers) external;
    /// @notice onlyTimelock: add or remove a payer later (S3 contracts).
    function setPayer(address payer, bool allowed) external;
    /// @notice Whether `a` may pay tips (the money contracts).
    function isPayer(address a) external view returns (bool);
    /// @notice The governance timelock.
    function timelock() external view returns (address);
}
