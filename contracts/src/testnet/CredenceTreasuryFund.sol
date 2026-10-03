// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {INavFund} from "../interfaces/INavFund.sol";
import {ICompliance} from "../interfaces/ICompliance.sol";
import {IssuerRoles} from "./IssuerRoles.sol";

/// @title CredenceTreasuryFund (tTBILL): testnet stand-in for a tokenized Treasury money fund (Build Guide §8.12).
/// @notice Permissioned ERC-20 (both parties allowlisted), an issuer-published NAV, `redemptionsGated()`, and
///         ERC-7540-style asynchronous redemption: requestRedeem → (issuer) fulfillRedeem at the published NAV,
///         paid in USDC from the issuer's reserve wallet → (controller) redeem. The issuer operator fulfils on the next
///         US business day; the fund accrues about 4% a year through the NAV it publishes.
contract CredenceTreasuryFund is INavFund, IssuerRoles, ERC20, ERC20Permit {
    using SafeTransferLib for address;

    enum RequestStatus {
        NONE,
        PENDING,
        CLAIMABLE,
        CLAIMED
    }

    struct Request {
        address controller;
        RequestStatus status;
        uint128 shares;
        uint128 assets;
    }

    /// @inheritdoc INavFund
    address public immutable asset;
    address public immutable registry;
    uint8 internal immutable _assetDec;

    address public reserveWallet;
    bool public redemptionsGated;
    bool public frozen;
    uint128 internal _nav;
    uint40 internal _navAt;
    uint256 public nextRequestId = 1;
    mapping(uint256 requestId => Request) public requests;

    event ReserveWalletSet(address wallet);

    constructor(
        string memory name_,
        string memory symbol_,
        address issuer_,
        address registry_,
        address asset_,
        address reserveWallet_,
        uint256 initialNav
    ) ERC20(name_, symbol_) ERC20Permit(name_) IssuerRoles(issuer_) {
        if (registry_ == address(0) || asset_ == address(0) || reserveWallet_ == address(0)) revert ZeroAddress();
        registry = registry_;
        asset = asset_;
        _assetDec = IERC20Metadata(asset_).decimals();
        reserveWallet = reserveWallet_;
        _publish(initialNav);
    }

    // ───────────────────────────── issuer ─────────────────────────────

    /// @inheritdoc INavFund
    function publishNav(uint256 navPerShare_) external onlyIssuer {
        _publish(navPerShare_);
    }

    function _publish(uint256 nav) internal {
        if (nav == 0 || nav > type(uint128).max) revert InvalidParam();
        _nav = uint128(nav);
        _navAt = uint40(block.timestamp);
        emit NavPublished(nav, uint40(block.timestamp));
    }

    /// @inheritdoc INavFund
    function setRedemptionsGated(bool gated) external onlyIssuer {
        redemptionsGated = gated;
        emit RedemptionsGatedSet(gated);
    }

    /// @notice onlyIssuer: freeze or unfreeze every transfer.
    function setFrozen(bool f) external onlyIssuer {
        frozen = f;
        emit FrozenSet(f);
    }

    /// @notice onlyIssuer: the wallet redemptions are paid from.
    function setReserveWallet(address wallet) external onlyIssuer {
        if (wallet == address(0)) revert ZeroAddress();
        reserveWallet = wallet;
        emit ReserveWalletSet(wallet);
    }

    /// @inheritdoc INavFund
    function mint(address to, uint256 amount) external {
        _authorizeMint(amount);
        _mint(to, amount);
    }

    /// @inheritdoc INavFund
    /// @dev assets = shares × NAV, in asset units, rounded DOWN (§7.2 "assets paid out on redeem").
    function fulfillRedeem(uint256 requestId) external onlyIssuer returns (uint256 assets) {
        if (redemptionsGated) revert RedemptionsGated();
        Request storage r = requests[requestId];
        if (r.status != RequestStatus.PENDING) revert RequestNotFound(requestId);
        assets = FPM.fullMulDiv(r.shares, uint256(_nav) * 10 ** _assetDec, 10 ** decimals() * 1e18);
        r.status = RequestStatus.CLAIMABLE;
        r.assets = uint128(assets);
        _burn(address(this), r.shares);
        asset.safeTransferFrom(reserveWallet, address(this), assets);
        emit RedeemFulfilled(requestId, r.shares, assets);
    }

    // ───────────────────────────── ERC-7540-style redemption ─────────────────────────────

    /// @inheritdoc INavFund
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        returns (uint256 requestId)
    {
        if (redemptionsGated) revert RedemptionsGated();
        if (shares == 0 || shares > type(uint128).max) revert ZeroAmount();
        if (controller == address(0)) revert ZeroAddress();
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _transfer(owner, address(this), shares); // escrow
        requestId = nextRequestId++;
        requests[requestId] = Request({
            controller: controller, status: RequestStatus.PENDING, shares: uint128(shares), assets: 0
        });
        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);
    }

    /// @inheritdoc INavFund
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        Request storage r = requests[requestId];
        return r.controller == controller && r.status == RequestStatus.PENDING ? r.shares : 0;
    }

    /// @inheritdoc INavFund
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        Request storage r = requests[requestId];
        return r.controller == controller && r.status == RequestStatus.CLAIMABLE ? r.shares : 0;
    }

    /// @inheritdoc INavFund
    function redeem(uint256 requestId, address receiver, address controller)
        external
        returns (uint256 assets)
    {
        Request storage r = requests[requestId];
        if (msg.sender != controller || r.controller != controller) revert NotRequestOwner(requestId);
        if (r.status != RequestStatus.CLAIMABLE) revert RequestNotClaimable(requestId);
        r.status = RequestStatus.CLAIMED;
        assets = r.assets;
        asset.safeTransfer(receiver, assets);
        emit Redeemed(requestId, receiver, assets);
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @inheritdoc INavFund
    function navPerShare() external view returns (uint256, uint40) {
        return (_nav, _navAt);
    }

    /// @inheritdoc INavFund
    function sharesPerToken() external pure returns (uint256) {
        return 1e18;
    }

    /// @inheritdoc INavFund
    function canHold(address a) public view returns (bool) {
        return ICompliance(registry).canHold(a);
    }

    /// @notice The issuer.
    function issuer() external view returns (address) {
        return _issuer;
    }

    /// @notice 18.
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return super.decimals();
    }

    /// @dev Frozen blocks everything. Otherwise every non-zero party other than this contract (the redemption
    ///      escrow) must be allowlisted.
    function _update(address from, address to, uint256 value) internal override {
        if (frozen) revert TokenFrozen();
        if (!_partyOk(from) || !_partyOk(to)) revert TransferNotAllowed(from, to);
        super._update(from, to, value);
    }

    function _partyOk(address a) internal view returns (bool) {
        return a == address(0) || a == address(this) || canHold(a);
    }
}
