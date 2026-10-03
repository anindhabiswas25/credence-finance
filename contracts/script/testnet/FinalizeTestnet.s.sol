// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CredenceTimelock} from "../../src/governance/CredenceTimelock.sol";
import {TestnetBase} from "./TestnetBase.sol";

/// @title Hand a testnet stack's timelock to its Gov Safe (ADR-0122, Build Guide §13.2 step 6, INV-GOV-01).
/// @notice One timelock self-batch, run by the deployer while it still holds the deploy-time roles: the Gov Safe becomes
///         proposer and canceller, execution opens to anyone (`address(0)`, §8.11), the delay becomes TIMELOCK_DELAY
///         (3,600 s on testnet), and the deployer's proposer, canceller and executor roles are revoked. After this no
///         EOA holds a protocol role. Marks the book `finalized`. Refuses a finalized book.
/// @dev Env: STACK, BOOK (the stack's address book), TIMELOCK_DELAY (default 3600), PRIVATE_KEY (the deployer).
contract FinalizeTestnet is TestnetBase {
    error AlreadyFinalized(string book);

    function run() external {
        string memory stack = vm.envString("STACK");
        _checkChain(stack);
        string memory book = vm.envString("BOOK");
        string memory j = vm.readFile(book);
        if (vm.parseJsonBool(j, ".finalized")) revert AlreadyFinalized(book);
        CredenceTimelock tl = CredenceTimelock(payable(vm.parseJsonAddress(j, ".shared.timelock")));
        address gov = vm.parseJsonAddress(j, ".safes.gov");
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(3600));
        (address me, uint256 pk) = _signer();

        address t = address(tl);
        _gov(t, abi.encodeCall(IAccessControl.grantRole, (tl.PROPOSER_ROLE(), gov)));
        _gov(t, abi.encodeCall(IAccessControl.grantRole, (tl.CANCELLER_ROLE(), gov)));
        _gov(t, abi.encodeCall(IAccessControl.grantRole, (tl.EXECUTOR_ROLE(), address(0))));
        _gov(t, abi.encodeCall(TimelockController.updateDelay, (delay)));
        _gov(t, abi.encodeCall(IAccessControl.revokeRole, (tl.CANCELLER_ROLE(), me)));
        _gov(t, abi.encodeCall(IAccessControl.revokeRole, (tl.EXECUTOR_ROLE(), me)));
        _gov(t, abi.encodeCall(IAccessControl.revokeRole, (tl.PROPOSER_ROLE(), me)));
        _broadcast(me, pk);
        _flush(tl, string.concat(stack, "-finalize"));
        vm.stopBroadcast();
        vm.writeJson("true", book, ".finalized");
        console2.log("timelock handed to the Gov Safe; delay", delay);
    }
}
