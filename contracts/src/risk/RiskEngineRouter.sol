// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskParams} from "../libraries/Types.sol";
import {IRiskEngine} from "../interfaces/IRiskEngine.sol";
import {IPricingEngine, IAuctionMath} from "./IStylusPrograms.sol";

/// @title RiskEngineRouter: the one `IRiskEngine` address in front of the split Stylus engine (R-24, ADR-0108).
/// @notice The full engine does not fit one Stylus code fragment on ArbOS 40, so it runs as two programs:
///         the PricingEngine (scenario sets, σ, params; safe LTV, Bell, premium) and AuctionMath (joint stress
///         columns and capacity; lots and clearing). This contract gates the writers (timelock, σ oracle), forwards
///         every call, supplies σ / κ / u_max / K from the PricingEngine to the capacity math, and re-emits the
///         engine events, so indexers watch one address. It holds no funds; like the engine it is replaceable through
///         the timelock (`CredenceMarket.setEngine`, R-21). Reverts of the programs bubble up unchanged.
/// @dev Both programs are constructed with this router as their only writer (PricingEngine: timelock = sigmaOracle =
///      router; AuctionMath: owner = router), then wired here once by the deployer.
contract RiskEngineRouter is IRiskEngine {
    address public immutable timelock;
    address internal immutable deployer;
    address public sigmaOracle;
    IPricingEngine public pricing;
    IAuctionMath public auction;

    event Wired(address pricing, address auction);
    event SigmaOracleSet(address sigmaOracle);

    constructor(address timelock_, address sigmaOracle_) {
        if (timelock_ == address(0) || sigmaOracle_ == address(0)) revert Unauthorized();
        timelock = timelock_;
        sigmaOracle = sigmaOracle_;
        deployer = msg.sender;
    }

    /// @notice Once, by the deployer: the two programs, each already constructed with this router as its writer.
    function initializeWiring(address pricing_, address auction_) external {
        if (msg.sender != deployer || address(pricing) != address(0)) revert Unauthorized();
        if (
            IPricingEngine(pricing_).timelock() != address(this)
                || IPricingEngine(pricing_).sigmaOracle() != address(this)
        ) {
            revert Unauthorized();
        }
        if (IAuctionMath(auction_).owner() != address(this)) revert Unauthorized();
        pricing = IPricingEngine(pricing_);
        auction = IAuctionMath(auction_);
        emit Wired(pricing_, auction_);
    }

    /// @notice onlyTimelock: the σ writer (the SigmaOracle contract, R-15).
    function setSigmaOracle(address sigmaOracle_) external {
        if (msg.sender != timelock || sigmaOracle_ == address(0)) revert Unauthorized();
        sigmaOracle = sigmaOracle_;
        emit SigmaOracleSet(sigmaOracle_);
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert Unauthorized();
        _;
    }

    // ───────────── closure risk (PricingEngine) ─────────────

    /// @inheritdoc IRiskEngine
    function safeLtv(bytes32 assetId, uint8 closureType, uint256 maxLtv, uint256 dividend)
        external
        view
        returns (uint256)
    {
        return pricing.safeLtv(assetId, closureType, maxLtv, dividend);
    }

    /// @inheritdoc IRiskEngine
    function bellStatus(
        bytes32 assetId,
        uint8 closureType,
        uint256 collateralValue,
        uint256 debtProjected,
        uint256 maxLtv,
        uint256 dividend,
        bool covered
    ) external view returns (uint8, uint256, uint256) {
        return pricing.bellStatus(
            assetId, closureType, collateralValue, debtProjected, maxLtv, dividend, covered
        );
    }

    /// @inheritdoc IRiskEngine
    function quoteCover(
        bytes32 assetId,
        uint8 closureType,
        uint16 closureDays,
        uint256 collateralValue,
        uint256 debtProjected,
        uint256 utilAfter
    ) external view returns (uint256, uint256, uint256) {
        return pricing.quoteCover(
            assetId, closureType, closureDays, collateralValue, debtProjected, utilAfter
        );
    }

    // ───────────── capacity (AuctionMath, with σ / κ / u_max / K from the PricingEngine) ─────────────

    /// @inheritdoc IRiskEngine
    function coverLossVector(
        bytes32 assetId,
        uint8 closureType,
        uint256 collateralValue,
        uint256 debtProjected
    ) external view returns (uint256[] memory) {
        RiskParams memory p = pricing.params();
        return auction.coverLossVector(
            assetId, pricing.sigma(assetId, closureType), p.kappa, p.kStress, collateralValue, debtProjected
        );
    }

    /// @dev The capacity call's arguments in memory (one stack slot each), for stack depth.
    struct Capacity {
        uint256[] current;
        uint256[] added;
        bytes32[] assets;
        uint256[] sigmas;
        uint256[] collateral;
        uint256[] safe;
        uint256 equity;
    }

    /// @inheritdoc IRiskEngine
    function poolCapacity(
        uint256[] calldata packedCurrent,
        uint256[] calldata packedAdd,
        bytes32[] calldata uncAssets,
        uint8[] calldata uncClosureTypes,
        uint256[] calldata uncCollateralValue,
        uint256[] calldata uncSafeLtv,
        uint256 equity
    ) external view returns (bool, uint256, uint256) {
        if (uncClosureTypes.length != uncAssets.length) revert MathError(3);
        uint256[] memory sigmas = new uint256[](uncAssets.length);
        for (uint256 i; i < uncAssets.length; ++i) {
            sigmas[i] = pricing.sigma(uncAssets[i], uncClosureTypes[i]);
        }
        return _capacity(
            Capacity(packedCurrent, packedAdd, uncAssets, sigmas, uncCollateralValue, uncSafeLtv, equity)
        );
    }

    function _capacity(Capacity memory c) internal view returns (bool, uint256, uint256) {
        RiskParams memory p = pricing.params();
        return auction.poolCapacity(
            c.current, c.added, c.assets, c.sigmas, c.collateral, c.safe, c.equity, p.kappa, p.uMax, p.kStress
        );
    }

    // ───────────── liquidation (AuctionMath) ─────────────

    /// @inheritdoc IRiskEngine
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
    ) external view returns (uint256) {
        return auction.liquidationLot(debt, qty, sizingPrice, hfPrice, lt, hStar, lambda, collDec, loanDec);
    }

    /// @inheritdoc IRiskEngine
    function precloseLot(
        uint256 debt,
        uint256 qty,
        uint256 valuation,
        uint256 reserve,
        uint256 targetLtv,
        uint256 lambdaPre,
        uint8 collDec,
        uint8 loanDec
    ) external view returns (uint256) {
        return auction.precloseLot(debt, qty, valuation, reserve, targetLtv, lambdaPre, collDec, loanDec);
    }

    /// @inheritdoc IRiskEngine
    function clear(
        uint256[] calldata qtys,
        uint256[] calldata prices,
        bytes32[] calldata tieKeys,
        uint256 lot,
        uint256 reserve
    ) external view returns (uint256, uint256[] memory, uint256) {
        return auction.clear(qtys, prices, tieKeys, lot, reserve);
    }

    // ───────────── writers ─────────────

    /// @inheritdoc IRiskEngine
    function setScenarioSet(bytes32 assetId, uint8 closureType, uint256[] calldata packedSortedZ, uint32 n)
        external
        onlyTimelock
    {
        pricing.setScenarioSet(assetId, closureType, packedSortedZ, n);
        emit ScenarioSetUpdated(assetId, closureType, pricing.scenarioHash(assetId, closureType), n);
    }

    /// @inheritdoc IRiskEngine
    function setJointColumn(bytes32 assetId, uint256[] calldata packedZ) external onlyTimelock {
        auction.setJointColumn(assetId, packedZ, pricing.params().kStress);
        emit JointColumnUpdated(assetId, auction.jointHash(assetId));
    }

    /// @inheritdoc IRiskEngine
    function setParams(RiskParams calldata p) external onlyTimelock {
        pricing.setParams(p);
        emit ParamsUpdated(p);
    }

    /// @inheritdoc IRiskEngine
    function setSigmaFloor(bytes32 assetId, uint8 closureType, uint256 floor) external onlyTimelock {
        pricing.setSigmaFloor(assetId, closureType, floor);
        emit SigmaFloorSet(assetId, closureType, floor);
    }

    /// @inheritdoc IRiskEngine
    function updateSigma(bytes32 assetId, uint8 closureType, uint256 s) external {
        if (msg.sender != sigmaOracle) revert Unauthorized();
        pricing.updateSigma(assetId, closureType, s);
        emit SigmaUpdated(assetId, closureType, s);
    }

    // ───────────── views ─────────────

    /// @inheritdoc IRiskEngine
    function sigma(bytes32 assetId, uint8 closureType) external view returns (uint256) {
        return pricing.sigma(assetId, closureType);
    }

    /// @inheritdoc IRiskEngine
    function params() external view returns (RiskParams memory) {
        return pricing.params();
    }

    /// @inheritdoc IRiskEngine
    function scenarioHash(bytes32 assetId, uint8 closureType) external view returns (bytes32) {
        return pricing.scenarioHash(assetId, closureType);
    }

    /// @inheritdoc IRiskEngine
    function jointHash(bytes32 assetId) external view returns (bytes32) {
        return auction.jointHash(assetId);
    }

    /// @inheritdoc IRiskEngine
    function sigmaAt(bytes32 assetId, uint8 closureType) external view returns (uint64) {
        return pricing.sigmaAt(assetId, closureType);
    }
}
