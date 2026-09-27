// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ISequencerHealth} from "../interfaces/ISequencerHealth.sol";

/// @title SequencerHealth: L2 block-timestamp gap detector (Build Guide §8.3.3, R-20).
/// @notice Records the time of every AssetClock poke. The clock turns a gap of more than 120 s between observed
///         pokes during an open phase into a phase extension. No Chainlink uptime feed on testnet: `isUp` is always
///         true; the mainnet implementation adds it behind the same interface.
contract SequencerHealth is ISequencerHealth {
    address public immutable deployer;
    address public clock;
    uint40 public lastSeen;

    constructor() {
        deployer = msg.sender;
    }

    /// @inheritdoc ISequencerHealth
    function setClock(address clock_) external {
        if (msg.sender != deployer) revert Unauthorized();
        if (clock != address(0)) revert AlreadyWired();
        if (clock_ == address(0)) revert ZeroAddress();
        clock = clock_;
        emit ClockSet(clock_);
    }

    /// @inheritdoc ISequencerHealth
    /// @custom:state any
    function recordPoke() external returns (uint40 previousSeen) {
        if (msg.sender != clock) revert Unauthorized();
        previousSeen = lastSeen;
        lastSeen = uint40(block.timestamp);
    }

    /// @inheritdoc ISequencerHealth
    function gapSince(uint40 t) external view returns (uint40) {
        uint40 ref = lastSeen > t ? lastSeen : t;
        return block.timestamp > ref ? uint40(block.timestamp) - ref : 0;
    }

    /// @inheritdoc ISequencerHealth
    function isUp() external pure returns (bool up, uint40 upSince) {
        return (true, 0);
    }
}
