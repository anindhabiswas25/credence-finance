// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev A collateral token whose adapter probes (sharesPerToken, frozen, redemptionsGated) are settable or revert.
contract MockProbeToken {
    uint256 public spt = 1e18;
    bool public isFrozen;
    bool public gated;
    bool public revertFrozen;
    bool public revertGated;

    function set(uint256 spt_, bool frozen_, bool gated_) external {
        spt = spt_;
        isFrozen = frozen_;
        gated = gated_;
    }

    function setReverts(bool frozen_, bool gated_) external {
        revertFrozen = frozen_;
        revertGated = gated_;
    }

    function sharesPerToken() external view returns (uint256) {
        return spt;
    }

    function frozen() external view returns (bool) {
        require(!revertFrozen, "frozen probe");
        return isFrozen;
    }

    function redemptionsGated() external view returns (bool) {
        require(!revertGated, "gated probe");
        return gated;
    }
}
