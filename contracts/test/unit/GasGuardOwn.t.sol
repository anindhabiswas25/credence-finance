// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {GasGuard} from "../../src/libraries/GasGuard.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";

/// @dev A call chain `depth` frames deep whose innermost frame burns all its gas (out-of-gas), or reverts with a
///      selector like Credence's own code.
contract DeepCallee {
    error Genuine();

    function deep(uint256 depth, bool oog) external view returns (uint256) {
        if (depth == 0) {
            if (!oog) revert Genuine();
            uint256 x;
            while (true) {
                x = uint256(keccak256(abi.encode(x)));
            }
            return x;
        }
        return this.deep(depth - 1, oog); // bubbles the callee's revert data unchanged
    }
}

contract GuardHarness {
    DeepCallee public callee = new DeepCallee();

    /// @return caught true if the catch branch was taken (the fail-closed path)
    function viaCheck(uint256 depth, bool oog) external view returns (bool caught) {
        uint256 g = gasleft();
        try callee.deep(depth, oog) {}
        catch {
            GasGuard.check(g);
            caught = true;
        }
    }

    function viaCheckOwn(uint256 depth, bool oog) external view returns (bool caught) {
        uint256 g = gasleft();
        try callee.deep(depth, oog) {}
        catch (bytes memory reason) {
            GasGuard.checkOwn(g, reason);
            caught = true;
        }
    }
}

/// @notice S4 QA-09 (ADR-0113): ADR-0109's `check` only detects an out-of-gas in the immediate callee; a deep one
///         returns every frame's retained 1/64 and passes it, so a caller-chosen gas limit could still select the
///         catch branch. `checkOwn` (callees that are Credence's own code) treats empty revert data as out-of-gas.
contract GasGuardOwnTest is Test {
    GuardHarness h;

    function setUp() public {
        h = new GuardHarness();
    }

    function test_deepOutOfGasPassesCheckButNotCheckOwn() public {
        // five frames deep: the old guard takes the catch branch (the griefing path)
        assertTrue(h.viaCheck{gas: 3_000_000}(5, true), "check misses a deep out-of-gas");
        vm.expectRevert(ICredenceErrors.InsufficientGas.selector);
        h.viaCheckOwn{gas: 3_000_000}(5, true);
    }

    function test_immediateOutOfGasIsCaughtByBoth() public {
        vm.expectRevert(ICredenceErrors.InsufficientGas.selector);
        h.viaCheck{gas: 3_000_000}(0, true);
        vm.expectRevert(ICredenceErrors.InsufficientGas.selector);
        h.viaCheckOwn{gas: 3_000_000}(0, true);
    }

    function test_genuineRevertKeepsTheCatchBranch() public view {
        assertTrue(h.viaCheck{gas: 3_000_000}(5, false));
        assertTrue(h.viaCheckOwn{gas: 3_000_000}(5, false));
    }
}
