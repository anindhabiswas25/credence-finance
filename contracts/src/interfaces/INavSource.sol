// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title A NAV source (fund markets). Implemented by CredencePriceFeed for NAV reports.
interface INavSource {
    /// @return nav Latest NAV per share (WAD), 0 if none.
    /// @return at Timestamp the NAV was published.
    /// @return prevNav The NAV before it (0 if none), for the one-step-drop rule.
    /// @return prevAt Timestamp of `prevNav`.
    function latestNav(bytes32 assetId)
        external
        view
        returns (uint256 nav, uint40 at, uint256 prevNav, uint40 prevAt);
}
