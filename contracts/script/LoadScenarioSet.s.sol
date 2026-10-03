// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IRiskEngine} from "../src/interfaces/IRiskEngine.sol";
import {RiskParams} from "../src/libraries/Types.sol";

/// @title Load a risk bundle (ADR-0106) into the Risk Engine: RiskParams, σ floors, scenario sets, joint columns,
///        initial σ; then read every hash back from the engine and compare it with the file.
/// @notice Validate first: `risk-cli validate-set <bundle>` checks sorting, canonical packing and every hash
///         (`make risk-load-set` does both). For a Stylus engine use `plan()` + `script/load_risk_bundle.sh`
///         (forge cannot execute WASM, so it cannot simulate calls into the engine). This script re-checks keccak256(packed) per set before it sends
///         anything, so a hand-edited file cannot reach the engine.
/// @dev Env: `RISK_BUNDLE` (path), `RISK_BUNDLE_DIR` (where the referenced files live; default = the bundle's
///      directory as computed by make), `RISK_ENGINE` (default: `.shared.riskEngine` of the local address book),
///      `PRIVATE_KEY` (the timelock on local chains). Initial σ is written only when the sender is the engine's
///      `sigmaOracle` (true on local; on a live chain σ goes through SigmaOracle / keeper J7).
///      On Arbitrum Sepolia the same calls are scheduled through the timelock (S5 `Wire` flow); this script sends
///      them directly, so it refuses chain ids 421614 and 42161.
contract LoadScenarioSet is Script {
    error Mismatch(string what, bytes32 fileValue, bytes32 engineValue);
    error LiveChain(uint256 chainId);

    uint8 internal constant MAX_TYPE = 3;

    function run() external {
        if (block.chainid == 421614 || block.chainid == 42161) revert LiveChain(block.chainid);
        string memory bundle = vm.envString("RISK_BUNDLE");
        string memory dir = vm.envString("RISK_BUNDLE_DIR");
        address engine = vm.envOr("RISK_ENGINE", address(0));
        if (engine == address(0)) {
            string memory book = vm.readFile(
                string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".local.json")
            );
            engine = vm.parseJsonAddress(book, ".shared.riskEngine");
        }
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        load(IRiskEngine(engine), bundle, dir, vm.addr(pk));
        vm.stopBroadcast();
        verify(IRiskEngine(engine), bundle, dir);
        console2.log("risk bundle loaded and verified on engine", engine);
    }

    /// @notice For a Stylus engine (forge's EVM cannot execute WASM, so it cannot simulate the writes): write every
    ///      call of the bundle as `{to, data, what}` to `PLAN_OUT` (default ../deployments/<chainId>.risk-load.local.json)
    ///      together with the hashes to verify, for `script/load_risk_bundle.sh` to send with cast. The same keccak
    ///      pre-checks as `load` run here. Env as `run`, plus SENDER (the address that will send; decides σ).
    function plan() external {
        string memory bundle = vm.envString("RISK_BUNDLE");
        string memory dir = vm.envString("RISK_BUNDLE_DIR");
        address engine = vm.envAddress("RISK_ENGINE");
        address sender = vm.envAddress("SENDER");
        string memory b = vm.readFile(bundle);
        string memory calls = "[";
        string memory checks = "[";
        calls = _add(calls, engine, abi.encodeCall(IRiskEngine.setParams, (_params(b))), "setParams", true);
        (bytes32[] memory fIds, uint8[] memory fTypes, uint256[] memory floors) =
            _triples(b, ".sigmaFloors", ".floors");
        for (uint256 i; i < fIds.length; ++i) {
            calls = _add(
                calls,
                engine,
                abi.encodeCall(IRiskEngine.setSigmaFloor, (fIds[i], fTypes[i], floors[i])),
                "setSigmaFloor",
                false
            );
        }
        string[] memory sets = _strings(b, ".scenarioSets");
        for (uint256 i; i < sets.length; ++i) {
            string memory s = vm.readFile(string.concat(dir, "/", sets[i]));
            uint256[] memory words = _words(s, ".packed");
            bytes32 h = vm.parseJsonBytes32(s, ".scenarioHash");
            bytes32 got = keccak256(abi.encodePacked(words));
            if (got != h) revert Mismatch(string.concat("scenarioHash of ", sets[i]), h, got);
            bytes32 id = vm.parseJsonBytes32(s, ".assetId");
            uint8 t = _type(s, ".closureType");
            calls = _add(
                calls,
                engine,
                abi.encodeCall(IRiskEngine.setScenarioSet, (id, t, words, uint32(vm.parseJsonUint(s, ".n")))),
                sets[i],
                false
            );
            checks = _check(checks, abi.encodeCall(IRiskEngine.scenarioHash, (id, t)), h, sets[i], i == 0);
        }
        if (vm.keyExistsJson(b, ".jointSet")) {
            string memory j = vm.readFile(string.concat(dir, "/", vm.parseJsonString(b, ".jointSet")));
            bytes32[] memory ids = vm.parseJsonBytes32Array(j, ".assetIds");
            bytes32[] memory hashes = vm.parseJsonBytes32Array(j, ".columnHashes");
            for (uint256 i; i < ids.length; ++i) {
                uint256[] memory words = _words(j, string.concat(".columns[", vm.toString(i), "]"));
                bytes32 got = keccak256(abi.encodePacked(words));
                if (got != hashes[i]) revert Mismatch("joint columnHash", hashes[i], got);
                calls = _add(
                    calls,
                    engine,
                    abi.encodeCall(IRiskEngine.setJointColumn, (ids[i], words)),
                    "jointColumn",
                    false
                );
                checks = _check(
                    checks,
                    abi.encodeCall(IRiskEngine.jointHash, (ids[i])),
                    hashes[i],
                    "jointColumn",
                    sets.length == 0 && i == 0
                );
            }
        }
        if (sender == IRiskEngine(engine).sigmaOracle()) {
            (bytes32[] memory ids, uint8[] memory types, uint256[] memory values) =
                _triples(b, ".sigmas", ".values");
            for (uint256 i; i < ids.length; ++i) {
                calls = _add(
                    calls,
                    engine,
                    abi.encodeCall(IRiskEngine.updateSigma, (ids[i], types[i], values[i])),
                    "updateSigma",
                    false
                );
            }
        }
        string memory out = vm.envOr(
            "PLAN_OUT",
            string.concat(
                vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".risk-load.local.json"
            )
        );
        vm.writeFile(out, string.concat('{ "calls": ', calls, "], \"checks\": ", checks, "] }\n"));
        console2.log("load plan:", out);
    }

    function _add(string memory acc, address to, bytes memory data, string memory what, bool first)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            acc,
            first ? "" : ",",
            '\n  { "to": "',
            vm.toString(to),
            '", "what": "',
            what,
            '", "data": "',
            vm.toString(data),
            '" }'
        );
    }

    function _check(string memory acc, bytes memory data, bytes32 want, string memory what, bool first)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            acc,
            first ? "" : ",",
            '\n  { "what": "',
            what,
            '", "data": "',
            vm.toString(data),
            '", "want": "',
            vm.toString(want),
            '" }'
        );
    }

    /// @notice Send every write of the bundle to `engine`. `sender` decides whether initial σ is written.
    function load(IRiskEngine engine, string memory bundlePath, string memory dir, address sender) public {
        string memory b = vm.readFile(bundlePath);
        engine.setParams(_params(b));

        (bytes32[] memory fIds, uint8[] memory fTypes, uint256[] memory floors) =
            _triples(b, ".sigmaFloors", ".floors");
        for (uint256 i; i < fIds.length; ++i) {
            engine.setSigmaFloor(fIds[i], fTypes[i], floors[i]);
        }

        string[] memory sets = _strings(b, ".scenarioSets");
        for (uint256 i; i < sets.length; ++i) {
            string memory s = vm.readFile(string.concat(dir, "/", sets[i]));
            uint256[] memory words = _words(s, ".packed");
            bytes32 h = vm.parseJsonBytes32(s, ".scenarioHash");
            bytes32 got = keccak256(abi.encodePacked(words));
            if (got != h) revert Mismatch(string.concat("scenarioHash of ", sets[i]), h, got);
            engine.setScenarioSet(
                vm.parseJsonBytes32(s, ".assetId"),
                _type(s, ".closureType"),
                words,
                uint32(vm.parseJsonUint(s, ".n"))
            );
        }

        if (vm.keyExistsJson(b, ".jointSet")) {
            string memory j = vm.readFile(string.concat(dir, "/", vm.parseJsonString(b, ".jointSet")));
            bytes32[] memory ids = vm.parseJsonBytes32Array(j, ".assetIds");
            bytes32[] memory hashes = vm.parseJsonBytes32Array(j, ".columnHashes");
            for (uint256 i; i < ids.length; ++i) {
                uint256[] memory words = _words(j, string.concat(".columns[", vm.toString(i), "]"));
                bytes32 got = keccak256(abi.encodePacked(words));
                if (got != hashes[i]) revert Mismatch("joint columnHash", hashes[i], got);
                engine.setJointColumn(ids[i], words);
            }
        }

        if (sender == engine.sigmaOracle()) {
            (bytes32[] memory ids, uint8[] memory types, uint256[] memory values) =
                _triples(b, ".sigmas", ".values");
            for (uint256 i; i < ids.length; ++i) {
                engine.updateSigma(ids[i], types[i], values[i]);
            }
        } else if (vm.keyExistsJson(b, ".sigmas")) {
            console2.log("initial sigmas skipped: sender is not the engine's sigmaOracle");
        }
    }

    /// @notice Read every hash and the params back from the engine; revert on the first difference.
    function verify(IRiskEngine engine, string memory bundlePath, string memory dir) public view {
        string memory b = vm.readFile(bundlePath);
        if (keccak256(abi.encode(engine.params())) != keccak256(abi.encode(_params(b)))) {
            revert Mismatch("params", bytes32(0), bytes32(0));
        }
        string[] memory sets = _strings(b, ".scenarioSets");
        for (uint256 i; i < sets.length; ++i) {
            string memory s = vm.readFile(string.concat(dir, "/", sets[i]));
            bytes32 want = vm.parseJsonBytes32(s, ".scenarioHash");
            bytes32 got = engine.scenarioHash(vm.parseJsonBytes32(s, ".assetId"), _type(s, ".closureType"));
            if (got != want) revert Mismatch(string.concat("engine.scenarioHash for ", sets[i]), want, got);
        }
        if (vm.keyExistsJson(b, ".jointSet")) {
            string memory j = vm.readFile(string.concat(dir, "/", vm.parseJsonString(b, ".jointSet")));
            bytes32[] memory ids = vm.parseJsonBytes32Array(j, ".assetIds");
            bytes32[] memory hashes = vm.parseJsonBytes32Array(j, ".columnHashes");
            for (uint256 i; i < ids.length; ++i) {
                bytes32 got = engine.jointHash(ids[i]);
                if (got != hashes[i]) revert Mismatch("engine.jointHash", hashes[i], got);
            }
        }
    }

    // ───────────── JSON helpers ─────────────

    function _params(string memory b) internal pure returns (RiskParams memory p) {
        p.alpha = uint64(vm.parseJsonUint(b, ".params.alpha"));
        p.kappa = uint64(vm.parseJsonUint(b, ".params.kappa"));
        p.theta = uint64(vm.parseJsonUint(b, ".params.theta"));
        p.costOfCap = uint64(vm.parseJsonUint(b, ".params.costOfCap"));
        p.eta = uint64(vm.parseJsonUint(b, ".params.eta"));
        p.beta = uint64(vm.parseJsonUint(b, ".params.beta"));
        p.uMax = uint64(vm.parseJsonUint(b, ".params.uMax"));
        p.minPremium = uint64(vm.parseJsonUint(b, ".params.minPremium"));
        p.kStress = uint32(vm.parseJsonUint(b, ".params.kStress"));
    }

    function _type(string memory j, string memory key) internal pure returns (uint8 t) {
        uint256 v = vm.parseJsonUint(j, key);
        require(v >= 1 && v <= MAX_TYPE, "closureType");
        t = uint8(v);
    }

    function _words(string memory j, string memory key) internal pure returns (uint256[] memory w) {
        bytes32[] memory raw = vm.parseJsonBytes32Array(j, key);
        w = new uint256[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            w[i] = uint256(raw[i]);
        }
    }

    function _strings(string memory j, string memory key) internal view returns (string[] memory out) {
        if (vm.keyExistsJson(j, key)) out = vm.parseJsonStringArray(j, key);
    }

    function _triples(string memory b, string memory key, string memory valueKey)
        internal
        view
        returns (bytes32[] memory ids, uint8[] memory types, uint256[] memory values)
    {
        if (!vm.keyExistsJson(b, key)) return (ids, types, values);
        ids = vm.parseJsonBytes32Array(b, string.concat(key, ".assetIds"));
        uint256[] memory t = vm.parseJsonUintArray(b, string.concat(key, ".closureTypes"));
        values = vm.parseJsonUintArray(b, string.concat(key, valueKey));
        require(t.length == ids.length && values.length == ids.length, "parallel arrays");
        types = new uint8[](t.length);
        for (uint256 i; i < t.length; ++i) {
            require(t[i] >= 1 && t[i] <= MAX_TYPE, "closureType");
            types[i] = uint8(t[i]);
        }
    }
}
