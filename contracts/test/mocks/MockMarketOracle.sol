// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {FeedHealth} from "../../src/libraries/Types.sol";

/// @notice The OracleAdapter views the market uses: a settable valuation price per asset, the stress flag and the
///         disagreement flag, with a revert switch (INV-REPAY-01/02).
contract MockMarketOracle {
    mapping(bytes32 => uint256) public price;
    mapping(bytes32 => bool) public stress;
    mapping(bytes32 => bool) public disagree;
    bool public reverting;

    function setPrice(bytes32 a, uint256 p) external {
        price[a] = p;
    }

    function setStress(bytes32 a, bool s) external {
        stress[a] = s;
    }

    function setDisagreement(bytes32 a, bool s) external {
        disagree[a] = s;
    }

    function setReverting(bool r) external {
        reverting = r;
    }

    function valuationPrice(bytes32 a) external view returns (uint256) {
        require(!reverting && price[a] != 0, "oracle");
        return price[a];
    }

    function stressFlag(bytes32 a) external view returns (bool) {
        require(!reverting, "oracle");
        return stress[a];
    }

    function feedHealth(bytes32 a) external view returns (FeedHealth memory h) {
        require(!reverting, "oracle");
        h.disagreement = disagree[a];
    }
}
