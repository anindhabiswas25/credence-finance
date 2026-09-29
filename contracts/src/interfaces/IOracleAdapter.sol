// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {FeedHealth, OracleConfig, MarketKind} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {IOracleAdapterEvents} from "../libraries/Events.sol";

/// @title Oracle Adapter: one valuation price per asset, by clock state (Build Guide §8.3.2, F-3.2).
/// @notice All prices returned are WAD USD per whole collateral TOKEN (share price × sharesPerToken).
interface IOracleAdapter is IOracleAdapterEvents, ICredenceErrors {
    /// @notice V by the stored clock state (F-3.2). Reverts `NoPrice` / `NoReferencePrice` instead of returning 0.
    /// @custom:state any
    function valuationPrice(bytes32 assetId) external view returns (uint256 v);
    /// @notice Primary live price, or min(primary, secondary) when they disagree by > 1.5%.
    function livePrice(bytes32 assetId) external view returns (uint256 p);
    /// @notice Most recent regular-session close: the official CLOSE, or the last REGULAR live print if newer.
    ///         NAV kind: the latest NAV.
    function lastRegularClose(bytes32 assetId) external view returns (uint256 p, uint40 t);
    /// @notice Open-print rule (§8.3.2). For a HALT / CORP_ACTION closure: the first fresh cross-checked live price.
    /// @param reopenAt Scheduled regular open that ends the closure.
    /// @param ext Phase extension (R-20) added to the 15-minute wait.
    function openPrint(bytes32 assetId, uint40 reopenAt, uint40 ext)
        external
        view
        returns (bool ok, uint256 p, bool fallbackUsed);
    /// @notice The feed-health flags the clock reads (staleness, disagreement, halts, issuer freeze, NAV
    ///        validity).
    function feedHealth(bytes32 assetId) external view returns (FeedHealth memory);
    /// @notice dexTwap(1h) < 90% × refPrice while CLOSED or HALTED.
    function stressFlag(bytes32 assetId) external view returns (bool);
    /// @notice WAD shares per token, cached; changes only through a confirmed corporate action.
    function sharesPerToken(bytes32 assetId) external view returns (uint256);
    /// @notice Conservative reference for a HALT closure: min(last regular close, last primary / secondary print).
    function haltReferencePrice(bytes32 assetId) external view returns (uint256 p, uint40 t);
    /// @notice The 1-hour DEX TWAP in token terms, and whether it is usable (configured, ok, deep enough).
    function dexTwap(bytes32 assetId) external view returns (uint256 p, bool usable);
    /// @notice An asset's price wiring.
    function config(bytes32 assetId) external view returns (OracleConfig memory);

    /// @notice onlyTimelock. Lists or re-points an asset's sources. Reads `sharesPerToken` from the token on first
    ///         listing only; afterwards it changes only via `setSharesPerToken`.
    function setAssetConfig(
        bytes32 assetId,
        address primary,
        address secondary,
        address dex,
        address token,
        MarketKind kind,
        uint128 minDepth
    ) external;
    /// @notice onlyClock (from `confirmCorporateAction`). Capped at ×10 / ÷10 per action.
    function setSharesPerToken(bytes32 assetId, uint256 newSharesPerToken) external;
    /// @notice One-time wiring of the AssetClock (deployer only).
    function setClock(address clock_) external;
    /// @notice The AssetClock.
    function clock() external view returns (address);
    /// @notice The governance timelock.
    function timelock() external view returns (address);
}
