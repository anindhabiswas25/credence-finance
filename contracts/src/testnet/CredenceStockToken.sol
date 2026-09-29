// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ICollateralToken} from "../interfaces/ICollateralToken.sol";
import {ICompliance} from "../interfaces/ICompliance.sol";
import {IssuerRoles} from "./IssuerRoles.sol";

/// @title CredenceStockToken: testnet stand-in for a Robinhood Stock Token (tNVDA, tAAPL, …) (Build Guide §8.12, R-02).
/// @notice Implements what the real token needs from Credence's side: an issuer ratio (`sharesPerToken`), an issuer
///         freeze, and a compliance hook. Prices are real; the token is labelled "Testnet asset" in the app.
contract CredenceStockToken is ICollateralToken, IssuerRoles, ERC20, ERC20Permit {
    uint256 public sharesPerToken = 1e18;
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

    /// @inheritdoc ICollateralToken
    /// @dev Emits RatioChanged, which triggers the CORP_ACTION runbook; Credence reads the new ratio only through
    ///      `AssetClock.confirmCorporateAction` (capped ×10 / ÷10).
    function setSharesPerToken(uint256 r) external onlyIssuer {
        if (r == 0) revert InvalidParam();
        emit RatioChanged(sharesPerToken, r);
        sharesPerToken = r;
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
