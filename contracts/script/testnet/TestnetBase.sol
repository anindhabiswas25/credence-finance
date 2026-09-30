// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {CredenceTimelock} from "../../src/governance/CredenceTimelock.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
    function proxyCreationCode() external pure returns (bytes memory);
}

interface ISafeSetup {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
}

/// @title Shared pieces of the testnet deploy scripts (ADR-0122): the chain / stack guard, Safes through the
///        canonical Safe v1.4.1 factory, and timelock batches.
abstract contract TestnetBase is Script {
    // Safe v1.4.1 canonical deployments (present on Robinhood Chain testnet 46630 and Arbitrum Sepolia 421614)
    address internal constant SAFE_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_L2 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_FALLBACK = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    uint256 internal constant EQUITY_CHAIN = 46630;
    uint256 internal constant NAV_CHAIN = 421614;
    uint256 internal constant ANVIL = 31337;
    uint256 internal constant BATCH = 20; // timelock calls per scheduleBatch / executeBatch

    error WrongChain(string stack, uint256 chainId);
    error UnknownStack(string stack);
    error MissingConfig(string key);
    error AlreadyDeployed(string book);

    /// @notice STACK = "equity" (46630) or "nav" (421614). Plain anvil (31337) only with DRY_RUN=1; never another chain.
    function _checkChain(string memory stack) internal view returns (bool nav) {
        bytes32 s = keccak256(bytes(stack));
        if (s == keccak256("equity")) nav = false;
        else if (s == keccak256("nav")) nav = true;
        else revert UnknownStack(stack);
        uint256 want = nav ? NAV_CHAIN : EQUITY_CHAIN;
        if (block.chainid == want) return nav;
        if (block.chainid == ANVIL && vm.envOr("DRY_RUN", false)) return nav;
        revert WrongChain(stack, block.chainid);
    }

    error KeyInEnv();

    /// @notice The deployer: PRIVATE_KEY only on plain anvil (the dry run); on a real chain the key stays in an encrypted
    ///         keystore (`forge script --account <name> --sender <DEPLOYER>`), and a PRIVATE_KEY in the env is refused.
    function _signer() internal view returns (address me, uint256 pk) {
        pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0 && block.chainid != ANVIL) revert KeyInEnv();
        me = pk != 0 ? vm.addr(pk) : vm.envAddress("DEPLOYER");
    }

    function _broadcast(address me, uint256 pk) internal {
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast(me);
    }

    function _requireEnv(string memory key) internal view returns (string memory v) {
        v = vm.envOr(key, string(""));
        if (bytes(v).length == 0) revert MissingConfig(key);
    }

    // ───────────── Safes ─────────────

    /// @notice The Safe named `name` (GOV, GUARDIAN, OPS): SAFE_<name>_ADDRESS if given, else created (or found, on a
    ///         re-run) from SAFE_<name>_OWNERS + SAFE_<name>_THRESHOLD with a salt fixed by the stack and the name.
    function _safe(string memory stack, string memory name) internal returns (address) {
        address given = vm.envOr(string.concat("SAFE_", name, "_ADDRESS"), address(0));
        if (given != address(0)) return given;
        (bytes memory init, uint256 nonce, address predicted) = _safePlan(stack, name);
        if (predicted.code.length != 0) return predicted;
        return ISafeProxyFactory(SAFE_FACTORY).createProxyWithNonce(SAFE_L2, init, nonce);
    }

    /// @notice The Safe `name` of `stack` from SAFE_<name>_OWNERS + SAFE_<name>_THRESHOLD: its setup call, salt nonce
    ///         and the address the canonical factory gives it (the post-deploy check compares the book with it).
    function _safePlan(string memory stack, string memory name)
        internal
        view
        returns (bytes memory init, uint256 nonce, address predicted)
    {
        string memory ownersKey = string.concat("SAFE_", name, "_OWNERS");
        _requireEnv(ownersKey);
        address[] memory owners = vm.envAddress(ownersKey, ",");
        uint256 threshold = vm.envUint(string.concat("SAFE_", name, "_THRESHOLD"));
        if (owners.length == 0 || threshold == 0 || threshold > owners.length) {
            revert MissingConfig(ownersKey);
        }
        init = abi.encodeCall(
            ISafeSetup.setup,
            (owners, threshold, address(0), "", SAFE_FALLBACK, address(0), 0, payable(address(0)))
        );
        nonce = uint256(keccak256(abi.encodePacked("credence", stack, name)));
        predicted = _predictSafe(init, nonce);
    }

    function _predictSafe(bytes memory init, uint256 nonce) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(keccak256(init), nonce));
        bytes memory code =
            abi.encodePacked(ISafeProxyFactory(SAFE_FACTORY).proxyCreationCode(), uint256(uint160(SAFE_L2)));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), SAFE_FACTORY, salt, keccak256(code)))))
        );
    }

    // ───────────── timelock batches ─────────────

    address[] internal _targets;
    bytes[] internal _payloads;
    uint256 internal _batchNo;

    /// @dev Queue a timelock call; `_flush` schedules and executes the queue (delay 0 during the deploy).
    function _gov(address target, bytes memory data) internal {
        _targets.push(target);
        _payloads.push(data);
    }

    function _flush(CredenceTimelock tl, string memory stack) internal {
        uint256 n = _targets.length;
        for (uint256 i; i < n; i += BATCH) {
            uint256 m = n - i < BATCH ? n - i : BATCH;
            address[] memory t = new address[](m);
            uint256[] memory v = new uint256[](m);
            bytes[] memory p = new bytes[](m);
            for (uint256 j; j < m; ++j) {
                t[j] = _targets[i + j];
                p[j] = _payloads[i + j];
            }
            bytes32 salt = keccak256(abi.encodePacked("credence-deploy", stack, _batchNo++));
            tl.scheduleBatch(t, v, p, bytes32(0), salt, 0);
            tl.executeBatch(t, v, p, bytes32(0), salt);
        }
        delete _targets;
        delete _payloads;
    }
}
