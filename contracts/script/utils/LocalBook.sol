// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

/// @title The ONE local address book: deployments/<chainId>.local.json (charter §2a, ADR-0105).
/// @notice Shape = Build Guide §13.2 (`shared`, `equity`, `nav`, `tokens`, `assetIds`), which `@credence/sdk`
///         parses as-is, plus:
///         - `stylus.riskEngine`: metadata of the Stylus engine deploy (written by stylus/risk-engine/scripts/deploy.sh);
///         - the S1 flat keys (`clock`, `feedA`, `assetId_NVDA`, …), kept for one sprint so existing scripts keep
///           working. They are deprecated and disappear in S3.
///         Every local deploy rewrites the whole file. `shared.riskEngine` and `stylus.riskEngine` are carried over
///         from the existing file when the engine still has code on this chain (a reset chain drops them).
library LocalBook {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Shared {
        address timelock;
        address guardian;
        address calendar;
        address clock;
        address oracle;
        address feedA;
        address feedB;
        address feedNav;
        address riskEngine;
        address sigmaOracle;
        address sequencerHealth;
        address registry;
        address faucet;
    }

    struct Stack {
        address market;
        address vault;
        address reserve;
        address treasury;
        address tips;
        address pool; // S2: a local stand-in until the S3 UnderwriterPool
        address auctionHouse; // equity (S2: local stand-in)
        address settlement; // NAV (S2: local stand-in)
        string[] tickers; // market name (ticker) → marketId
        bytes32[] marketIds;
    }

    struct EngineMeta {
        string deploymentTx;
        uint256 compressedSizeBytes;
        string toolchain;
        string wasmSha256;
    }

    struct Book {
        uint256 chainId;
        uint256 startBlock;
        Shared shared;
        Stack equity;
        Stack nav;
        string[] tokenNames; // "tNVDA", "usdc", …
        address[] tokenAddrs;
        string[] assetNames; // "NVDA", "TBILL", …
        bytes32[] assetIds;
        EngineMeta engine;
        bool hasEngineMeta;
    }

    function defaultPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".local.json");
    }

    /// @notice The Stylus engine recorded in an existing book, if it still has code on this chain.
    function carryEngine(Book memory b, string memory path) internal view {
        if (!vm.exists(path)) return;
        string memory j = vm.readFile(path);
        if (!vm.keyExistsJson(j, ".shared.riskEngine")) return;
        address e = vm.parseJsonAddress(j, ".shared.riskEngine");
        if (e.code.length == 0) return;
        b.shared.riskEngine = e;
        if (vm.keyExistsJson(j, ".stylus.riskEngine.deploymentTx")) {
            b.hasEngineMeta = true;
            b.engine.deploymentTx = vm.parseJsonString(j, ".stylus.riskEngine.deploymentTx");
            b.engine.compressedSizeBytes = vm.parseJsonUint(j, ".stylus.riskEngine.compressedSizeBytes");
            b.engine.toolchain = vm.parseJsonString(j, ".stylus.riskEngine.toolchain");
            if (vm.keyExistsJson(j, ".stylus.riskEngine.wasmSha256")) {
                b.engine.wasmSha256 = vm.parseJsonString(j, ".stylus.riskEngine.wasmSha256");
            }
        }
    }

    function write(Book memory b, string memory path) internal {
        string memory s = string.concat(
            "{\n",
            _kvu("chainId", b.chainId),
            ",\n",
            _kvu("startBlock", b.startBlock),
            ",\n",
            '  "release": "local",\n',
            '  "shared": ',
            _shared(b.shared),
            ",\n"
        );
        if (b.equity.market != address(0)) s = string.concat(s, '  "equity": ', _stack(b.equity), ",\n");
        if (b.nav.market != address(0)) s = string.concat(s, '  "nav": ', _stack(b.nav), ",\n");
        s = string.concat(s, '  "tokens": ', _addrMap(b.tokenNames, b.tokenAddrs), ",\n");
        s = string.concat(s, '  "assetIds": ', _b32Map(b.assetNames, b.assetIds), ",\n");
        if (b.shared.riskEngine != address(0) && b.hasEngineMeta) {
            s = string.concat(s, '  "stylus": ', _engine(b.shared.riskEngine, b.engine), ",\n");
        }
        s = string.concat(s, _legacy(b), "\n}\n");
        vm.writeFile(path, s);
    }

    // ───────────── rendering ─────────────

    function _q(string memory x) private pure returns (string memory) {
        return string.concat('"', x, '"');
    }

    function _kvu(string memory k, uint256 v) private pure returns (string memory) {
        return string.concat("  ", _q(k), ": ", vm.toString(v));
    }

    function _a(string memory k, address v) private pure returns (string memory) {
        return string.concat(_q(k), ": ", _q(vm.toString(v)));
    }

    /// @dev `, "k": "0x…"` when v is set, else "".
    function _opt(string memory k, address v) private pure returns (string memory) {
        return v == address(0) ? "" : string.concat(", ", _a(k, v));
    }

    function _shared(Shared memory x) private pure returns (string memory) {
        string memory s = string.concat(
            "{ ",
            _a("calendar", x.calendar),
            ", ",
            _a("clock", x.clock),
            ", ",
            _a("oracle", x.oracle),
            ", ",
            _a("feedA", x.feedA),
            ", ",
            _a("feedB", x.feedB)
        );
        s = string.concat(
            s,
            _opt("timelock", x.timelock),
            _opt("guardian", x.guardian),
            _opt("feedNav", x.feedNav),
            _opt("riskEngine", x.riskEngine),
            _opt("sigmaOracle", x.sigmaOracle),
            _opt("sequencerHealth", x.sequencerHealth)
        );
        return string.concat(s, _opt("registry", x.registry), _opt("faucet", x.faucet), " }");
    }

    function _stack(Stack memory x) private pure returns (string memory) {
        string memory s = string.concat(
            "{ ",
            _a("market", x.market),
            _opt("vault", x.vault),
            _opt("reserve", x.reserve),
            _opt("treasury", x.treasury),
            _opt("tips", x.tips),
            _opt("pool", x.pool),
            _opt("auctionHouse", x.auctionHouse),
            _opt("settlement", x.settlement)
        );
        return string.concat(s, ', "markets": ', _b32Map(x.tickers, x.marketIds), " }");
    }

    function _addrMap(string[] memory k, address[] memory v) private pure returns (string memory s) {
        s = "{";
        for (uint256 i; i < k.length; ++i) {
            s = string.concat(s, i == 0 ? " " : ", ", _a(k[i], v[i]));
        }
        s = string.concat(s, " }");
    }

    function _b32Map(string[] memory k, bytes32[] memory v) private pure returns (string memory s) {
        s = "{";
        for (uint256 i; i < k.length; ++i) {
            s = string.concat(s, i == 0 ? " " : ", ", _q(k[i]), ": ", _q(vm.toString(v[i])));
        }
        s = string.concat(s, " }");
    }

    function _engine(address e, EngineMeta memory m) private pure returns (string memory) {
        return string.concat(
            '{ "riskEngine": { ',
            _a("address", e),
            ', "deploymentTx": ',
            _q(m.deploymentTx),
            ', "compressedSizeBytes": ',
            vm.toString(m.compressedSizeBytes),
            ', "toolchain": ',
            _q(m.toolchain),
            ', "wasmSha256": ',
            _q(m.wasmSha256),
            " } }"
        );
    }

    /// @dev Deprecated S1 flat keys (removed in S3).
    function _legacy(Book memory b) private pure returns (string memory s) {
        Shared memory x = b.shared;
        s = string.concat(
            '  "_deprecated": "flat S1 keys below; use shared/tokens/assetIds",\n  ',
            _a("calendar", x.calendar),
            ",\n  ",
            _a("clock", x.clock),
            ",\n  ",
            _a("oracle", x.oracle),
            ",\n  ",
            _a("feedA", x.feedA),
            ",\n  ",
            _a("feedB", x.feedB),
            ",\n  ",
            _a("navFeed", x.feedNav),
            ",\n  ",
            _a("sequencerHealth", x.sequencerHealth)
        );
        s = string.concat(s, ",\n  ", _a("registry", x.registry), ",\n  ", _a("faucet", x.faucet));
        for (uint256 i; i < b.tokenNames.length; ++i) {
            s = string.concat(s, ",\n  ", _a(b.tokenNames[i], b.tokenAddrs[i]));
        }
        for (uint256 i; i < b.assetNames.length; ++i) {
            s = string.concat(
                s, ",\n  ", _q(string.concat("assetId_", b.assetNames[i])), ": ", _q(vm.toString(b.assetIds[i]))
            );
        }
    }
}
