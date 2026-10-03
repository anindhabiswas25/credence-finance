// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {INavFundEvents} from "../libraries/Events.sol";

/// @title A tokenized Treasury money fund (Build Guide §3.8, §8.12). BENJI / WTGXX / USTBL on mainnet,
///        CredenceTreasuryFund (tTBILL) on testnet. ERC-7540-style asynchronous redemption.
interface INavFund is IERC20Metadata, INavFundEvents, ICredenceErrors {
    /// @notice True while the issuer gates redemptions (the oracle reports issuerFrozen → HALTED).
    function redemptionsGated() external view returns (bool);
    /// @notice True while the issuer has frozen the fund token.
    function frozen() external view returns (bool);
    /// @notice Fund shares per token (WAD).
    function sharesPerToken() external view returns (uint256);
    /// @notice Whether `a` is allowlisted to hold the fund.
    function canHold(address a) external view returns (bool);
    /// @notice NAV per share (WAD USD) last published by the issuer, and when.
    function navPerShare() external view returns (uint256 nav, uint40 at);
    /// @notice The redemption asset (USDC).
    function asset() external view returns (address);

    // ERC-7540-style redemption
    /// @notice ERC-7540-style: escrow `shares` for redemption at the next fulfilment; returns the request id.
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        returns (uint256 requestId);
    /// @notice Shares of a request still waiting for the issuer (0 unless `controller` owns it).
    function pendingRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares);
    /// @notice Shares of a request the issuer has fulfilled and `controller` may redeem.
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares);
    /// @notice Claim a fulfilled request. `msg.sender` must be the controller.
    function redeem(uint256 requestId, address receiver, address controller) external returns (uint256 assets);

    // issuer operations (testnet)
    /// @notice onlyIssuer: publish the NAV per share (WAD USD).
    function publishNav(uint256 navPerShare_) external;
    /// @notice onlyIssuer: pay a pending request at the published NAV from the reserve wallet.
    function fulfillRedeem(uint256 requestId) external returns (uint256 assets);
    /// @notice onlyIssuer: gate or reopen redemptions.
    function setRedemptionsGated(bool gated) external;
    /// @notice onlyIssuer or a capped minter: mint fund tokens.
    function mint(address to, uint256 amount) external;
}
