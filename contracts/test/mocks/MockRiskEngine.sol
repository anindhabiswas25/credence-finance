// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskParams} from "../../src/libraries/Types.sol";

/// @notice Stand-in for the Stylus Risk Engine in Solidity tests (Foundry cannot run WASM, §14.1).
///         - Writers and hash views behave like the real engine (auth, payload length, keccak256 of the packed words).
///         - `safeLtv` returns a value the test injects per (asset, closure type) (e.g. the doc's 71.26% for NVDA),
///           capped at `maxLtv`; `quoteCover` returns an injected quote.
///         - `bellStatus`, `liquidationLot` and `precloseLot` are line-by-line ports of risk-core (same rounding), so
///           market tests get the engine's numbers for the injected safe LTV; `test/unit/MockRiskEngine.t.sol`
///           checks the ports against `risk-cli` through FFI.
///         - `setReverting(true)` makes every math view revert (INV-REPAY-01/02).
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
    mapping(bytes32 => uint256) internal _safe; // injected safe LTV per key (0 = maxLtv)
    uint256[3] internal _quote;
    bool public reverting;
    uint256 public safeLtvCalls;

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

    // ───────────── injected math ─────────────

    function setSafeLtv(bytes32 assetId, uint8 closureType, uint256 v) external {
        _safe[_key(assetId, closureType)] = v;
    }

    function setQuote(uint256 premium, uint256 el, uint256 es) external {
        _quote = [premium, el, es];
    }

    function setReverting(bool r) external {
        reverting = r;
    }

    function _live() internal view {
        if (reverting) revert MathError(99);
    }

    function safeLtv(bytes32 assetId, uint8 closureType, uint256 maxLtv, uint256) public view returns (uint256) {
        _live();
        uint256 v = _safe[_key(assetId, closureType)];
        return v == 0 || v > maxLtv ? maxLtv : v;
    }

    function quoteCover(bytes32, uint8, uint16, uint256, uint256, uint256)
        external
        view
        returns (uint256, uint256, uint256)
    {
        _live();
        return (_quote[0], _quote[1], _quote[2]);
    }

    /// @dev risk-core `bell_status` at the injected safe LTV.
    function bellStatus(
        bytes32 assetId,
        uint8 closureType,
        uint256 collateralValue,
        uint256 debtProjected,
        uint256 maxLtv,
        uint256 dividend,
        bool covered
    ) external view returns (uint8, uint256, uint256) {
        uint256 s = safeLtv(assetId, closureType, maxLtv, dividend);
        if (covered) return (2, 0, 0);
        uint256 ltv = debtProjected == 0 ? 0 : (collateralValue == 0 ? type(uint256).max : _divUp(debtProjected * 1e18, collateralValue));
        if (ltv <= s) return (0, 0, 0);
        uint256 allowed = s * collateralValue / 1e18;
        uint256 repay = debtProjected > allowed ? debtProjected - allowed : 0;
        if (s == 0) return (1, repay, type(uint256).max);
        uint256 need = _divUp(debtProjected * 1e18, s);
        return (1, repay, need > collateralValue ? need - collateralValue : 0);
    }

    /// @dev risk-core `liquidation_lot` (F-4.5a).
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
        _live();
        if (lambda > 1e18 || lt > 10e18) revert MathError(3);
        if (qty == 0) return 0;
        uint256 scale = 10 ** collDec;
        uint256 lhs = hStar * (debt * 10 ** (18 - loanDec));
        uint256 rhs = qty * (hfPrice * lt) / scale;
        if (lhs <= rhs) return 0;
        uint256 hr = hStar * sizingPrice * (1e18 - lambda) / 1e18;
        uint256 pl = hfPrice * lt;
        if (hr <= pl) return qty;
        uint256 x = _divUp((lhs - rhs) * scale, hr - pl);
        return x >= qty ? qty : x;
    }

    /// @dev risk-core `preclose_lot` (F-4.5b).
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
        _live();
        if (lambdaPre > 1e18 || targetLtv > 1e18) revert MathError(3);
        if (qty == 0) return 0;
        uint256 scale = 10 ** collDec;
        uint256 lhs = debt * 10 ** (18 - loanDec) * 1e18;
        uint256 rhs = qty * (targetLtv * valuation) / scale;
        if (lhs <= rhs) return 0;
        uint256 sell = (1e18 - lambdaPre) * reserve;
        uint256 keep = targetLtv * valuation;
        if (sell <= keep) return qty;
        uint256 x = _divUp((lhs - rhs) * scale, sell - keep);
        return x >= qty ? qty : x;
    }

    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
