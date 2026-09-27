// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {ICollateralTokenEvents} from "../libraries/Events.sol";

/// @title A stock-token collateral (Build Guide §3.3, §8.12). Robinhood Stock Token on mainnet,
///        CredenceStockToken on testnet.
interface ICollateralToken is IERC20Metadata, ICollateralTokenEvents, ICredenceErrors {
    function issuer() external view returns (address);
    /// @notice WAD underlying shares per token (1e18 at launch).
    function sharesPerToken() external view returns (uint256);
    function frozen() external view returns (bool);
    /// @notice address(0) = open token.
    function compliance() external view returns (address);
    /// @notice Compliance hook used by the AuctionHouse; `true` for an open token.
    function canHold(address a) external view returns (bool);

    // issuer operations (testnet)
    function mint(address to, uint256 amount) external; // onlyIssuer or a capped minter
    function setSharesPerToken(uint256 r) external; // onlyIssuer; emits RatioChanged
    function setFrozen(bool f) external; // onlyIssuer
}
