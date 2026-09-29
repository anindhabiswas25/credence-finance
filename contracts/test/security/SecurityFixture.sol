// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {HookToken} from "./mocks/HookToken.sol";
import {Reenterer} from "./mocks/Reenterer.sol";

/// @dev The S3 stack (real market, vault, pool, auction house; mocked clock, oracle and engine) with the fixture's
///      USDC and tNVDA replaced in place by HookToken code (`vm.etch`, balances kept): every transfer to or from an
///      attacker account hands it control flow. QA-sec owns this file (charter §2).
abstract contract SecurityFixture is RiskFixture {
    bytes4 internal constant REENTRANT = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    function setUpSecurity() internal {
        setUpRisk();
        _hookify(address(usdc), 6);
        _hookify(address(tNVDA), 18);
    }

    function _hookify(address token, uint8 dec) internal {
        HookToken impl = new HookToken("hook", "HOOK", dec);
        vm.etch(token, address(impl).code);
    }

    /// @dev A fresh attacker contract with its hook registered on both tokens and every protocol contract approved.
    function _attacker() internal returns (Reenterer r) {
        r = new Reenterer();
        address[2] memory toks = [address(usdc), address(tNVDA)];
        address[4] memory spenders = [address(market), address(vault), address(up), address(house)];
        for (uint256 t; t < 2; ++t) {
            r.exec(toks[t], abi.encodeCall(HookToken.setHook, (address(r))));
            for (uint256 s; s < 4; ++s) {
                r.exec(
                    toks[t],
                    abi.encodeWithSignature("approve(address,uint256)", spenders[s], type(uint256).max)
                );
            }
        }
    }

    /// @dev Armed call `i` ran inside the hook and the target's guard reverted it.
    function _assertGuarded(Reenterer r, uint256 i) internal view {
        (bool fired, bool ok, bytes memory ret) = r.outcome(i);
        assertTrue(fired, "the hook fired");
        assertFalse(ok, "the re-entry must revert");
        assertEq(bytes4(ret), REENTRANT, "reverted by the reentrancy guard");
    }

    /// @dev Armed call `i` ran inside the hook and succeeded (a cross-contract call the design allows).
    function _assertRan(Reenterer r, uint256 i) internal view returns (bytes memory ret) {
        bool fired;
        bool ok;
        (fired, ok, ret) = r.outcome(i);
        assertTrue(fired, "the hook fired");
        assertTrue(ok, "the cross-contract call ran");
    }
}
