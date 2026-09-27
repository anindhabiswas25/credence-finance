// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ITwapSource} from "../../src/interfaces/ITwapSource.sol";

/// @dev Settable ITwapSource for OracleAdapter tests.
contract MockTwapSource is ITwapSource {
    uint256 public price;
    bool public ok = true;
    uint256 public depthUsd;
    bool public revertTwap;
    bool public revertDepth;

    function set(uint256 p, bool ok_, uint256 depth_) external {
        price = p;
        ok = ok_;
        depthUsd = depth_;
    }

    function setReverts(bool twap_, bool depth_) external {
        revertTwap = twap_;
        revertDepth = depth_;
    }

    function twap(uint32) external view returns (uint256, bool) {
        require(!revertTwap, "twap");
        return (price, ok);
    }

    function depth() external view returns (uint256) {
        require(!revertDepth, "depth");
        return depthUsd;
    }

    function pool() external pure returns (address) {
        return address(0);
    }

    function baseToken() external pure returns (address) {
        return address(0);
    }

    function quoteToken() external pure returns (address) {
        return address(0);
    }
}
