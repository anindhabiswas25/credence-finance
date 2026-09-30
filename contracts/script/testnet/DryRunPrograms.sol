// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskParams} from "../../src/libraries/Types.sol";

/// @title Stand-ins for the two Stylus programs in the deploy DRY RUN on plain anvil only (ADR-0122).
/// @notice Anvil cannot run WASM. These keep exactly what the deploy writes and reads back (sets and joint columns as
///         keccak256 of the packed words, like the programs; params; σ floors; σ), so the dry run exercises the same
///         router wiring, timelock loading and hash verification as the real chain. They compute no risk numbers, and
///         the deploy never uses them outside DRY_RUN (anvil).
contract DryRunPricingProgram {
    address public immutable timelock; // the router: the only writer, as for the real program
    address public immutable sigmaOracle;
    RiskParams internal _p;
    mapping(bytes32 => mapping(uint8 => bytes32)) public scenarioHash;
    mapping(bytes32 => mapping(uint8 => uint256)) public floorOf;
    mapping(bytes32 => mapping(uint8 => uint256)) public sigma;

    error Unauthorized();

    constructor(address router) {
        (timelock, sigmaOracle) = (router, router);
    }

    function setScenarioSet(bytes32 a, uint8 t, uint256[] calldata packed, uint32) external {
        if (msg.sender != timelock) revert Unauthorized();
        scenarioHash[a][t] = keccak256(abi.encodePacked(packed));
    }

    function setParams(RiskParams calldata p) external {
        if (msg.sender != timelock) revert Unauthorized();
        _p = p;
    }

    function setSigmaFloor(bytes32 a, uint8 t, uint256 f) external {
        if (msg.sender != timelock) revert Unauthorized();
        floorOf[a][t] = f;
    }

    function updateSigma(bytes32 a, uint8 t, uint256 s) external {
        if (msg.sender != sigmaOracle) revert Unauthorized();
        sigma[a][t] = s;
    }

    function params() external view returns (RiskParams memory) {
        return _p;
    }

    function sigmaAt(bytes32 a, uint8 t) external view returns (uint64) {
        uint256 s = sigma[a][t];
        uint256 f = floorOf[a][t];
        return uint64(s > f ? s : f);
    }
}

contract DryRunAuctionMathProgram {
    address public immutable owner;
    mapping(bytes32 => bytes32) public jointHash;

    error Unauthorized();

    constructor(address router) {
        owner = router;
    }

    function setJointColumn(bytes32 a, uint256[] calldata packed, uint32) external {
        if (msg.sender != owner) revert Unauthorized();
        jointHash[a] = keccak256(abi.encodePacked(packed));
    }
}
