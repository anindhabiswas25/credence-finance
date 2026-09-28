// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskParams} from "../../src/libraries/Types.sol";

/// @notice Stand-in for the Stylus Risk Engine in Solidity tests. The writers and hash views behave like the real
///         engine (auth, payload-length check, keccak256 of the packed words); the math views return values the
///         test injects, so market tests can use the doc's figures (e.g. scenario A premiums).
contract MockRiskEngine {
    error Unauthorized();
    error MathError(uint8 code);
    error UnknownSet(bytes32 assetId, uint8 closureType);

    address public timelock;
    address public sigmaOracle;
    RiskParams internal _params;

    mapping(bytes32 => bytes32) internal _setHash; // key = keccak256(abi.encodePacked(assetId, closureType))
    mapping(bytes32 => uint32) public setLength;
    mapping(bytes32 => bytes32) public jointHash;
    mapping(bytes32 => uint256) internal _sigma;
    mapping(bytes32 => uint256) internal _floor;

    constructor(address timelock_, address sigmaOracle_) {
        timelock = timelock_;
        sigmaOracle = sigmaOracle_;
    }

    function _key(bytes32 assetId, uint8 closureType) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(assetId, closureType));
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert Unauthorized();
        _;
    }

    function setScenarioSet(bytes32 assetId, uint8 closureType, uint256[] calldata packedSortedZ, uint32 n)
        external
        onlyTimelock
    {
        if (n == 0 || packedSortedZ.length != (uint256(n) + 15) / 16) revert MathError(1);
        bytes32 k = _key(assetId, closureType);
        _setHash[k] = keccak256(abi.encodePacked(packedSortedZ));
        setLength[k] = n;
    }

    function setJointColumn(bytes32 assetId, uint256[] calldata packedZ) external onlyTimelock {
        if (packedZ.length != (uint256(_params.kStress) + 15) / 16) revert MathError(1);
        jointHash[assetId] = keccak256(abi.encodePacked(packedZ));
    }

    function setParams(RiskParams calldata p) external onlyTimelock {
        _params = p;
    }

    function setSigmaFloor(bytes32 assetId, uint8 closureType, uint256 floor) external onlyTimelock {
        _floor[_key(assetId, closureType)] = floor;
    }

    function updateSigma(bytes32 assetId, uint8 closureType, uint256 s) external {
        if (msg.sender != sigmaOracle) revert Unauthorized();
        _sigma[_key(assetId, closureType)] = s;
    }

    function sigma(bytes32 assetId, uint8 closureType) external view returns (uint256) {
        return _sigma[_key(assetId, closureType)];
    }

    function sigmaFloor(bytes32 assetId, uint8 closureType) external view returns (uint256) {
        return _floor[_key(assetId, closureType)];
    }

    function params() external view returns (RiskParams memory) {
        return _params;
    }

    function scenarioHash(bytes32 assetId, uint8 closureType) external view returns (bytes32) {
        return _setHash[_key(assetId, closureType)];
    }
}
