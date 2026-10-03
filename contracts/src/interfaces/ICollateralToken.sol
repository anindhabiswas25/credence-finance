// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {ICollateralTokenEvents} from "../libraries/Events.sol";

/// @title A stock-token collateral (Build Guide §3.3, §8.12). Robinhood Stock Token on mainnet,
///        CredenceStockToken on testnet.
interface ICollateralToken is IERC20Metadata, ICollateralTokenEvents, ICredenceErrors {
    /// @notice The issuer (testnet: the Credence ops multisig).
    function issuer() external view returns (address);
    /// @notice WAD underlying shares per token (1e18 at launch): the ERC-8056 `uiMultiplier` (ADR-0119).
    function sharesPerToken() external view returns (uint256);
    /// @notice True while the issuer has frozen the token (the oracle reports issuerFrozen).
    function frozen() external view returns (bool);
    /// @notice address(0) = open token.
    function compliance() external view returns (address);
    /// @notice Compliance hook used by the AuctionHouse; `true` for an open token.
    function canHold(address a) external view returns (bool);

    // issuer operations (testnet)
    /// @notice onlyIssuer or a capped minter: mint tokens.
    function mint(address to, uint256 amount) external;
    /// @notice onlyIssuer: set the multiplier, effective at once (ERC-8056 `scheduleUIMultiplier(r, now)`).
    function setSharesPerToken(uint256 r) external;
    /// @notice onlyIssuer: freeze or unfreeze every transfer.
    function setFrozen(bool f) external;
}
