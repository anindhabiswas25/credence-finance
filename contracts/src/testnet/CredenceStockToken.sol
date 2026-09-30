// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ICollateralToken} from "../interfaces/ICollateralToken.sol";
import {IScaledUIAmount} from "../interfaces/IScaledUIAmount.sol";
import {ICompliance} from "../interfaces/ICompliance.sol";
import {IssuerRoles} from "./IssuerRoles.sol";

/// @title CredenceStockToken: testnet stand-in for a Robinhood Stock Token (tNVDA, tAAPL, …) (Build Guide §8.12, R-02).
/// @notice Implements what the real token needs from Credence's side: the ERC-8056 multiplier of a Robinhood Stock Token
///         (`uiMultiplier`, with a scheduled `newUIMultiplier` / `effectiveAt`; ADR-0119), an issuer freeze, and a
///         compliance hook. Prices are real; the token is labelled "Testnet asset" in the app.
contract CredenceStockToken is ICollateralToken, IScaledUIAmount, IssuerRoles, ERC20, ERC20Permit {
    uint256 internal _multiplier = 1e18;
    uint256 internal _next;
    uint256 internal _at;
    bool public frozen;
    /// @inheritdoc ICollateralToken
    address public compliance;

    constructor(string memory name_, string memory symbol_, address issuer_, address compliance_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        IssuerRoles(issuer_)
    {
        compliance = compliance_;
        emit ComplianceSet(compliance_);
    }

    /// @inheritdoc ICollateralToken
    function mint(address to, uint256 amount) external {
        _authorizeMint(amount);
        _mint(to, amount);
    }

    /// @inheritdoc IScaledUIAmount
    function uiMultiplier() public view returns (uint256) {
        return _at != 0 && block.timestamp >= _at ? _next : _multiplier;
    }

    /// @inheritdoc IScaledUIAmount
    function newUIMultiplier() external view returns (uint256) {
        return _next;
    }

    /// @inheritdoc IScaledUIAmount
    function effectiveAt() external view returns (uint256) {
        return _at;
    }

    /// @inheritdoc ICollateralToken
    /// @dev The ERC-8056 multiplier under its v0 name.
    function sharesPerToken() external view returns (uint256) {
        return uiMultiplier();
    }

    /// @notice onlyIssuer: schedule the multiplier `m` from `at` (`at == block.timestamp` applies it at once). Replaces
    ///         a pending update; an update that already took effect becomes the base first.
    function scheduleUIMultiplier(uint256 m, uint256 at) public onlyIssuer {
        if (m == 0 || at < block.timestamp) revert InvalidParam();
        uint256 cur = uiMultiplier();
        _multiplier = cur;
        (_next, _at) = (m, at);
        emit UIMultiplierUpdated(cur, m, at);
        emit RatioChanged(cur, m);
    }

    /// @notice onlyIssuer: cancel an update that has not taken effect yet.
    function cancelUIMultiplierUpdate() external onlyIssuer {
        if (_at == 0 || block.timestamp >= _at) revert InvalidParam();
        emit UIMultiplierUpdateCancelled(_next, _at);
        (_next, _at) = (0, 0);
    }

    /// @inheritdoc ICollateralToken
    /// @dev The v0 setter: the new multiplier takes effect at once.
    function setSharesPerToken(uint256 r) external onlyIssuer {
        scheduleUIMultiplier(r, block.timestamp);
    }

    /// @inheritdoc ICollateralToken
    function setFrozen(bool f) external onlyIssuer {
        frozen = f;
        emit FrozenSet(f);
    }

    /// @notice address(0) opens the token.
    function setCompliance(address compliance_) external onlyIssuer {
        compliance = compliance_;
        emit ComplianceSet(compliance_);
    }

    /// @inheritdoc ICollateralToken
    function canHold(address a) external view returns (bool) {
        address c = compliance;
        return c == address(0) || ICompliance(c).canHold(a);
    }

    /// @inheritdoc ICollateralToken
    function issuer() external view returns (address) {
        return _issuer;
    }

    /// @notice 18.
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return super.decimals();
    }

    function _update(address from, address to, uint256 value) internal override {
        if (frozen) revert TokenFrozen();
        address c = compliance;
        if (c != address(0) && !ICompliance(c).canTransfer(from, to)) revert TransferNotAllowed(from, to);
        super._update(from, to, value);
    }
}
