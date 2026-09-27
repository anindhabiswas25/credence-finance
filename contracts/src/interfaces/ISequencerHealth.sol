// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICredenceErrors} from "../libraries/Errors.sol";
import {ISequencerHealthEvents} from "../libraries/Events.sol";

/// @title L2 sequencer health (Build Guide §8.3.3, R-20). Testnet: the gap detector only.
interface ISequencerHealth is ISequencerHealthEvents, ICredenceErrors {
    /// @notice Record an AssetClock poke: returns the previous `lastSeen` and sets it to `block.timestamp`.
    /// @custom:state any. onlyClock.
    function recordPoke() external returns (uint40 previousSeen);
    /// @notice Timestamp of the last recorded poke (0 before the first).
    function lastSeen() external view returns (uint40);
    /// @notice Seconds since `max(lastSeen, t)`; 0 if that is in the future.
    function gapSince(uint40 t) external view returns (uint40);
    /// @notice Mainnet: Chainlink L2 uptime feed. Testnet gap detector: always (true, 0).
    /// @return up Whether the sequencer is reported up.
    /// @return upSince When it last came up (0 = unknown / not tracked).
    function isUp() external view returns (bool up, uint40 upSince);
    function clock() external view returns (address);
    /// @notice One-time wiring of the AssetClock (deployer only).
    function setClock(address clock_) external;
}
