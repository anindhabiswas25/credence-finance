// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {INavFundEvents} from "../libraries/Events.sol";

/// @title A tokenized Treasury money fund (Build Guide §3.8, §8.12). BENJI / WTGXX / USTBL on mainnet,
///        CredenceTreasuryFund (tTBILL) on testnet. ERC-7540-style asynchronous redemption.
interface INavFund is IERC20Metadata, INavFundEvents, ICredenceErrors {
    function redemptionsGated() external view returns (bool);
    function frozen() external view returns (bool);
    function sharesPerToken() external view returns (uint256);
    function canHold(address a) external view returns (bool);
    /// @notice NAV per share (WAD USD) last published by the issuer, and when.
    function navPerShare() external view returns (uint256 nav, uint40 at);
    /// @notice The redemption asset (USDC).
    function asset() external view returns (address);

    // ERC-7540-style redemption
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        returns (uint256 requestId);
    function pendingRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares);
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares);
    /// @notice Claim a fulfilled request. `msg.sender` must be the controller.
    function redeem(uint256 requestId, address receiver, address controller) external returns (uint256 assets);

    // issuer operations (testnet)
    function publishNav(uint256 navPerShare_) external; // onlyIssuer
    function fulfillRedeem(uint256 requestId) external returns (uint256 assets); // onlyIssuer, at the published NAV
    function setRedemptionsGated(bool gated) external; // onlyIssuer
    function mint(address to, uint256 amount) external; // onlyIssuer or a capped minter
}
