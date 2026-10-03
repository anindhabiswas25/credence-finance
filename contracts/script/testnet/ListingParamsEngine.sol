// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RiskParams} from "../../src/libraries/Types.sol";

/// @title ListingParamsEngine: the engine a market is listed against during the deploy (ADR-0122).
/// @notice `CredenceMarket.createMarket` checks the listing precondition against `engine.params().kappa`. forge simulates
///         every deploy transaction in its own EVM, which cannot run the Stylus programs behind the real router, so
///         markets are created against this contract (the bundle's RiskParams, nothing else), and then
///         `setEngine(router)` points them at the real engine in the same timelock batch. The post-deploy check
///         requires every market's engine to be the router.
contract ListingParamsEngine {
    RiskParams internal _p;

    constructor(RiskParams memory p) {
        _p = p;
    }

    function params() external view returns (RiskParams memory) {
        return _p;
    }
}
