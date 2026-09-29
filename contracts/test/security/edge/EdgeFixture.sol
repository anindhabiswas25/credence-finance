// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {RiskFixture} from "../../utils/RiskFixture.sol";

/// @title Edge-case matrix fixture (QA-sec S4 item H, `docs/qa/edge-cases.md`).
/// @notice Every test in `test/security/edge/` is named after its matrix row (`test_E_<row>_…`).
abstract contract EdgeFixture is RiskFixture {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carl = makeAddr("carl");

    /// @dev A test that proves an open defect runs only with QA_FINDINGS=1, so an open finding never turns the
    ///      team's `forge test` red; the owner runs it to see it fail, and it goes green with the fix.
    modifier finding() {
        if (!vm.envOr("QA_FINDINGS", false)) vm.skip(true);
        _;
    }

    function setUpEdge() internal {
        setUpRisk();
        _underwrite(uw1, 500_000e6);
    }

    function _one(address b) internal pure returns (address[] memory bs) {
        bs = new address[](1);
        bs[0] = b;
    }

    function _two(address a, address b) internal pure returns (address[] memory bs) {
        bs = new address[](2);
        (bs[0], bs[1]) = (a, b);
    }

    /// @dev How many logs with topic0 `sig` were recorded.
    function _count(Vm.Log[] memory logs, bytes32 sig) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == sig) ++n;
        }
    }
}
