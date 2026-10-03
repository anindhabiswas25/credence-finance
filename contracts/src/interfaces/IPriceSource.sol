// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title A price source for one or more assets (Build Guide §8.3.1).
/// @notice Prices are WAD USD per SHARE; the OracleAdapter applies `sharesPerToken`.
/// @dev `lastRegular` is a v0 addition to the guide's interface: the AssetClock needs the last
///      regular-session print to freeze the reference price before the official CLOSE report lands.
interface IPriceSource {
    /// @return price Latest live price (WAD per share), 0 if none.
    /// @return observedAt Exchange timestamp of that print.
    /// @return marketStatus FeedMarketStatus of the most recent LIVE or STATUS report.
    function latest(bytes32 assetId)
        external
        view
        returns (uint256 price, uint40 observedAt, uint8 marketStatus);
    /// @notice Official regular-session opening print for the session whose regular open is `sessionOpen`.
    function officialOpen(bytes32 assetId, uint40 sessionOpen)
        external
        view
        returns (uint256 price, uint40 at, bool ok);
    /// @notice Most recent official closing print.
    function officialClose(bytes32 assetId)
        external
        view
        returns (uint256 price, uint40 at, uint40 sessionDate);
    /// @notice Time-weighted mean of LIVE prints over the trailing `window` seconds.
    /// @return price The TWAP (WAD per share).
    /// @return ok false if the stored history does not cover the whole window.
    function twap(bytes32 assetId, uint32 window) external view returns (uint256 price, bool ok);
    /// @notice Most recent LIVE print with marketStatus REGULAR.
    function lastRegular(bytes32 assetId) external view returns (uint256 price, uint40 at);
}
