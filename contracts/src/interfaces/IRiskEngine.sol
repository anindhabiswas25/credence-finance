// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskParams} from "../libraries/Types.sol";
import {IRiskEngineEvents} from "../libraries/Events.sol";

/// @title Risk Engine (Rust / Stylus) Solidity-facing ABI (Build Guide §8.9.1).
/// @dev Implemented by `RiskEngineRouter` in front of the two Stylus programs (R-24, ADR-0108). `liquidationLot`,
///      `precloseLot` and `clear` are `view` since v1 (they were `pure`): the router forwards them. Selectors unchanged.
interface IRiskEngine is IRiskEngineEvents {
    error Unauthorized();
    error NotSorted();
    error UnknownSet(bytes32 assetId, uint8 closureType);
    error SigmaDropTooFast(uint256 current, uint256 proposed, uint256 minAllowed);
    error SigmaBelowFloor(uint256 floor, uint256 proposed);
    error MathError(uint8 code);

    // closure risk
    function safeLtv(bytes32 assetId, uint8 closureType, uint256 maxLtv, uint256 dividend)
        external
        view
        returns (uint256);
    function bellStatus(
        bytes32 assetId,
        uint8 closureType,
        uint256 collateralValue,
        uint256 debtProjected,
        uint256 maxLtv,
        uint256 dividend,
        bool covered
    ) external view returns (uint8 status, uint256 cureRepay, uint256 cureCollateralValue);
    function quoteCover(
        bytes32 assetId,
        uint8 closureType,
        uint16 closureDays,
        uint256 collateralValue,
        uint256 debtProjected,
        uint256 utilAfter
    ) external view returns (uint256 premium, uint256 expectedLoss, uint256 expectedShortfall);
    // capacity (R-13)
    function coverLossVector(
        bytes32 assetId,
        uint8 closureType,
        uint256 collateralValue,
        uint256 debtProjected
    ) external view returns (uint256[] memory packed);
    function poolCapacity(
        uint256[] calldata packedCurrent,
        uint256[] calldata packedAdd,
        bytes32[] calldata uncAssets,
        uint8[] calldata uncClosureTypes,
        uint256[] calldata uncCollateralValue,
        uint256[] calldata uncSafeLtv,
        uint256 equity
    ) external view returns (bool ok, uint256 utilAfter, uint256 worstLoss);
    // liquidation
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
    ) external view returns (uint256 x);
    function precloseLot(
        uint256 debt,
        uint256 qty,
        uint256 valuation,
        uint256 reserve,
        uint256 targetLtv,
        uint256 lambdaPre,
        uint8 collDec,
        uint8 loanDec
    ) external view returns (uint256 x);
    function clear(
        uint256[] calldata qtys,
        uint256[] calldata prices,
        bytes32[] calldata tieKeys,
        uint256 lot,
        uint256 reserve
    ) external view returns (uint256 pStar, uint256[] memory fills, uint256 qPool);
    // writers
    function setScenarioSet(bytes32 assetId, uint8 closureType, uint256[] calldata packedSortedZ, uint32 n)
        external; // onlyTimelock
    function setJointColumn(bytes32 assetId, uint256[] calldata packedZ) external; // onlyTimelock (K entries)
    function setParams(RiskParams calldata p) external; // onlyTimelock
    function setSigmaFloor(bytes32 assetId, uint8 closureType, uint256 floor) external; // onlyTimelock
    function updateSigma(bytes32 assetId, uint8 closureType, uint256 sigma) external; // onlySigmaOracle
    // views
    function sigma(bytes32 assetId, uint8 closureType) external view returns (uint256);
    function params() external view returns (RiskParams memory);
    function scenarioHash(bytes32 assetId, uint8 closureType) external view returns (bytes32);
    /// @dev Added in v1 (additive, ADR-0106): keccak256 of the packed joint column last set by `setJointColumn`.
    function jointHash(bytes32 assetId) external view returns (bytes32);
    /// @dev Added in v1 (additive): when σ of (asset, type) was last written (unix seconds; 0 = never), for keeper J7.
    function sigmaAt(bytes32 assetId, uint8 closureType) external view returns (uint64);
    /// @dev Added after v0 (additive): the two writers the engine trusts.
    function timelock() external view returns (address);
    function sigmaOracle() external view returns (address);
}
