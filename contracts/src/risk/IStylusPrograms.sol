// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskParams} from "../libraries/Types.sol";

/// @title The two Stylus programs of the split Risk Engine (R-24, ADR-0108), as the router calls them.
/// @dev Must match `cargo stylus export-abi` of stylus/risk-engine and stylus/auction-math in both directions
///      (`make stylus-abi-check`). Consumers use `IRiskEngine` on the router, never these.
interface IPricingEngine {
    // the IRiskEngine errors it raises (same selectors, so they bubble through the router unchanged)
    error Unauthorized();
    error NotSorted();
    error UnknownSet(bytes32 assetId, uint8 closureType);
    error SigmaDropTooFast(uint256 current, uint256 proposed, uint256 minAllowed);
    error SigmaBelowFloor(uint256 floor, uint256 proposed);
    error MathError(uint8 code);

    /// @notice Pricing program: F-4.2 safe LTV.
    function safeLtv(bytes32 assetId, uint8 closureType, uint256 maxLtv, uint256 dividend)
        external
        view
        returns (uint256);
    /// @notice Pricing program: F-4.2 Bell Check.
    function bellStatus(
        bytes32 assetId,
        uint8 closureType,
        uint256 collateralValue,
        uint256 debtProjected,
        uint256 maxLtv,
        uint256 dividend,
        bool covered
    ) external view returns (uint8, uint256, uint256);
    /// @notice Pricing program: F-4.3 premium.
    function quoteCover(
        bytes32 assetId,
        uint8 closureType,
        uint16 closureDays,
        uint256 collateralValue,
        uint256 debtProjected,
        uint256 utilAfter
    ) external view returns (uint256, uint256, uint256);
    /// @notice Pricing program, owner only: an (asset, closure type) scenario set.
    function setScenarioSet(bytes32 assetId, uint8 closureType, uint256[] calldata packedSortedZ, uint32 n)
        external;
    /// @notice Pricing program, owner only: the risk parameters.
    function setParams(RiskParams calldata p) external;
    /// @notice Pricing program, owner only: a σ floor.
    function setSigmaFloor(bytes32 assetId, uint8 closureType, uint256 floor) external;
    /// @notice Pricing program: σ from the σ oracle, rate-limited.
    function updateSigma(bytes32 assetId, uint8 closureType, uint256 sigma) external;
    /// @notice Pricing program: current σ.
    function sigma(bytes32 assetId, uint8 closureType) external view returns (uint256);
    /// @notice Pricing program: the risk parameters.
    function params() external view returns (RiskParams memory);
    /// @notice Pricing program: hash of a scenario set.
    function scenarioHash(bytes32 assetId, uint8 closureType) external view returns (bytes32);
    /// @notice Pricing program: σ as stored (packed).
    function sigmaAt(bytes32 assetId, uint8 closureType) external view returns (uint64);
    /// @notice Pricing program: its owner (the router).
    function timelock() external view returns (address);
    /// @notice Pricing program: the σ writer.
    function sigmaOracle() external view returns (address);
}

interface IAuctionMath {
    error Unauthorized();
    error UnknownSet(bytes32 assetId, uint8 closureType);
    error MathError(uint8 code);

    /// @notice Auction-math program, owner only: a joint stress column.
    function setJointColumn(bytes32 assetId, uint256[] calldata packedZ, uint32 k) external;
    /// @notice Auction-math program: hash of a joint column.
    function jointHash(bytes32 assetId) external view returns (bytes32);
    /// @notice Auction-math program: its owner (the router).
    function owner() external view returns (address);
    /// @notice Auction-math program: a policy's packed K-loss vector (§9.5).
    function coverLossVector(
        bytes32 assetId,
        uint256 sigma,
        uint256 kappa,
        uint32 k,
        uint256 collateralValue,
        uint256 debtProjected
    ) external view returns (uint256[] memory);
    /// @notice Auction-math program: F-4.4 capacity.
    function poolCapacity(
        uint256[] calldata packedCurrent,
        uint256[] calldata packedAdd,
        bytes32[] calldata uncAssets,
        uint256[] calldata uncSigmas,
        uint256[] calldata uncCollateralValue,
        uint256[] calldata uncSafeLtv,
        uint256 equity,
        uint256 kappa,
        uint256 uMax,
        uint32 k
    ) external view returns (bool, uint256, uint256);
    /// @notice Auction-math program: F-4.5a lot.
    function liquidationLot(
        uint256 debt,
        uint256 qty,
        uint256 sizingPrice,
        uint256 hfPrice,
        uint256 lt,
        uint256 hStar,
        uint256 lambda,
        uint8 collDec,
        uint8 loanDec
    ) external view returns (uint256);
    /// @notice Auction-math program: F-4.5b pre-close lot.
    function precloseLot(
        uint256 debt,
        uint256 qty,
        uint256 valuation,
        uint256 reserve,
        uint256 targetLtv,
        uint256 lambdaPre,
        uint8 collDec,
        uint8 loanDec
    ) external view returns (uint256);
    /// @notice Auction-math program: F-4.5c clearing.
    function clear(
        uint256[] calldata qtys,
        uint256[] calldata prices,
        bytes32[] calldata tieKeys,
        uint256 lot,
        uint256 reserve
    ) external view returns (uint256, uint256[] memory, uint256);
}
