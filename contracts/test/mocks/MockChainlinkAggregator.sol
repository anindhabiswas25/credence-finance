// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @dev Replays recorded Chainlink rounds (phase-prefixed proxy round ids) up to a chosen head.
contract MockChainlinkAggregator {
    uint8 public immutable decimals;
    uint80[] internal _ids;
    int256[] internal _answers;
    uint256[] internal _updated;
    uint256 public head; // index of the latest visible round

    constructor(uint8 d) {
        decimals = d;
    }

    function load(uint80[] calldata ids, int256[] calldata answers, uint256[] calldata updated) external {
        for (uint256 i; i < ids.length; ++i) {
            _ids.push(ids[i]);
            _answers.push(answers[i]);
            _updated.push(updated[i]);
        }
        head = ids.length - 1;
    }

    function setHead(uint256 i) external {
        head = i;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_ids[head], _answers[head], _updated[head], _updated[head], _ids[head]);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 first = _ids[0];
        require(id >= first && id <= _ids[head], "No data present");
        uint256 i = id - first;
        return (_ids[i], _answers[i], _updated[i], _updated[i], _ids[i]);
    }
}
