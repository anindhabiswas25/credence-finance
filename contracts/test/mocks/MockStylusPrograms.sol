// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskParams} from "../../src/libraries/Types.sol";

/// @notice Solidity stand-in for the Stylus PricingEngine program (forge cannot run WASM): returns values derived from
///         its inputs, so a test can check the router forwards every argument, and records the writes.
contract MockPricingProgram {
    address public timelock;
    address public sigmaOracle;
    RiskParams internal _p;
    mapping(bytes32 => mapping(uint8 => uint256)) public sigmaOf;
    mapping(bytes32 => mapping(uint8 => uint256)) public floorOf;
    mapping(bytes32 => mapping(uint8 => uint32)) public setN;

    constructor(address owner_) {
        timelock = owner_;
        sigmaOracle = owner_;
        _p = RiskParams(0.001e18, 0.03e18, 1e18, 0.15e18, 4e18, 0.975e18, 0.5e18, 0.5e6, 256);
    }

    function setOwners(address t, address s) external {
        (timelock, sigmaOracle) = (t, s);
    }

    function safeLtv(bytes32, uint8 t, uint256 maxLtv, uint256 dividend) external pure returns (uint256) {
        return maxLtv - t - dividend;
    }

    function bellStatus(bytes32, uint8 t, uint256 c, uint256 d, uint256, uint256, bool covered)
        external
        pure
        returns (uint8, uint256, uint256)
    {
        return (covered ? 2 : t, c, d);
    }

    function quoteCover(bytes32, uint8, uint16 days_, uint256 c, uint256 d, uint256 u)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return (days_ + u, c, d);
    }

    function setScenarioSet(bytes32 a, uint8 t, uint256[] calldata, uint32 n) external {
        require(msg.sender == timelock, "owner");
        setN[a][t] = n;
    }

    function setParams(RiskParams calldata p) external {
        require(msg.sender == timelock, "owner");
        _p = p;
    }

    function setSigmaFloor(bytes32 a, uint8 t, uint256 f) external {
        require(msg.sender == timelock, "owner");
        floorOf[a][t] = f;
    }

    function updateSigma(bytes32 a, uint8 t, uint256 s) external {
        require(msg.sender == sigmaOracle, "sigma");
        sigmaOf[a][t] = s;
    }

    function sigma(bytes32 a, uint8 t) external view returns (uint256) {
        return sigmaOf[a][t];
    }

    function params() external view returns (RiskParams memory) {
        return _p;
    }

    function scenarioHash(bytes32 a, uint8 t) external pure returns (bytes32) {
        return keccak256(abi.encode(a, t));
    }

    function sigmaAt(bytes32 a, uint8 t) external view returns (uint64) {
        return uint64(sigmaOf[a][t] / 1e12);
    }
}

/// @notice Solidity stand-in for the Stylus AuctionMath program.
contract MockAuctionMathProgram {
    address public owner;
    mapping(bytes32 => uint32) public jointK;

    constructor(address owner_) {
        owner = owner_;
    }

    function setOwner(address o) external {
        owner = o;
    }

    function setJointColumn(bytes32 a, uint256[] calldata, uint32 k) external {
        require(msg.sender == owner, "owner");
        jointK[a] = k;
    }

    function jointHash(bytes32 a) external pure returns (bytes32) {
        return keccak256(abi.encode("joint", a));
    }

    function coverLossVector(bytes32, uint256 sigma, uint256 kappa, uint32 k, uint256 c, uint256 d)
        external
        pure
        returns (uint256[] memory v)
    {
        v = new uint256[](5);
        (v[0], v[1], v[2], v[3], v[4]) = (sigma, kappa, k, c, d);
    }

    function poolCapacity(
        uint256[] calldata cur,
        uint256[] calldata add,
        bytes32[] calldata assets,
        uint256[] calldata sigmas,
        uint256[] calldata,
        uint256[] calldata,
        uint256 equity,
        uint256 kappa,
        uint256 uMax,
        uint32 k
    ) external pure returns (bool, uint256, uint256) {
        uint256 s;
        for (uint256 i; i < sigmas.length; ++i) {
            s += sigmas[i];
        }
        return (assets.length == sigmas.length, s + cur.length + add.length + kappa + uMax, equity + k);
    }

    function liquidationLot(uint256 debt, uint256 qty, uint256, uint256, uint256, uint256, uint256, uint8, uint8)
        external
        pure
        returns (uint256)
    {
        return debt + qty;
    }

    function precloseLot(uint256 debt, uint256 qty, uint256, uint256, uint256, uint256, uint8, uint8)
        external
        pure
        returns (uint256)
    {
        return debt * qty;
    }

    function clear(uint256[] calldata q, uint256[] calldata, bytes32[] calldata, uint256 lot, uint256 reserve)
        external
        pure
        returns (uint256, uint256[] memory fills, uint256)
    {
        fills = q;
        return (reserve, fills, lot);
    }
}
