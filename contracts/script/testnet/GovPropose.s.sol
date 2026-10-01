// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {Session, MarketParams, MarketKind, RateParams} from "../../src/libraries/Types.sol";
import {CalendarStore} from "../../src/clock/CalendarStore.sol";
import {AssetClock} from "../../src/clock/AssetClock.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {CredenceMarket} from "../../src/core/CredenceMarket.sol";
import {SeniorVault} from "../../src/core/SeniorVault.sol";

/// @title The timelock calls of a governance change after the deploy (S5 item 5, ADR-0122). Read-only: it only
///        encodes. `gov.sh propose` wraps the calls into the timelock's scheduleBatch / executeBatch, the Gov Safe's
///        transaction and the Safe Transaction Builder JSON.
/// @notice Each function writes `{"calls": [{"to", "data", "what"}]}` to PROPOSAL_OUT. BOOK is the stack's address book.
///   listMarket(): TICKER, TOKEN (an existing collateral token; deploy a test token first), SUPPLY_CAP, BORROW_CAP,
///     VAULT_CAP (whole loan units). Oracle config on the stack's own feeds, `listAsset` on the clock, `createMarket`
///     with the deploy's §12.2 parameters, the vault cap, both vault queues (the vault's enabled markets + the new
///     one). The asset's risk bundle must be loaded first (`gov.sh propose risk-bundle`, executed before this one).
///   caps(): TICKER, SUPPLY_CAP, BORROW_CAP, optional VAULT_CAP (whole loan units).
///   calendar(): CALENDAR (a calibration calendar file): every session after the last one on chain, in parts of 60.
contract GovPropose is Script {
    bytes32 internal constant XNYS = bytes32("XNYS");
    bytes32 internal constant USBANK = bytes32("USBANK");
    uint256 internal constant PART = 60;

    string internal j;
    bool internal nav;
    string internal calls = "[]";
    uint256 internal n;

    function _load() internal {
        j = vm.readFile(vm.envString("BOOK"));
        nav = keccak256(bytes(vm.parseJsonString(j, ".stack"))) == keccak256("nav");
        require(vm.parseJsonUint(j, ".chainId") == block.chainid, "the book is for another chain");
    }

    function _a(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(j, key);
    }

    function _push(address to, bytes memory data, string memory what) internal {
        string memory k = string.concat("c", vm.toString(n++));
        vm.serializeAddress(k, "to", to);
        vm.serializeBytes(k, "data", data);
        string memory one = vm.serializeString(k, "what", what);
        calls = bytes(calls).length == 2
            ? string.concat("[", one, "]")
            : string.concat(_trimEnd(calls), ",", one, "]");
    }

    function _trimEnd(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory r = new bytes(b.length - 1);
        for (uint256 i; i < r.length; ++i) {
            r[i] = b[i];
        }
        return string(r);
    }

    function _write() internal {
        require(n != 0, "no calls");
        vm.writeFile(vm.envString("PROPOSAL_OUT"), string.concat("{\"calls\":", calls, "}"));
    }

    function _unit(address loan) internal view returns (uint256) {
        (, bytes memory r) = loan.staticcall(abi.encodeWithSignature("decimals()"));
        return 10 ** abi.decode(r, (uint8));
    }

    function _assetId(string memory ticker) internal view returns (bytes32) {
        return keccak256(bytes(string.concat(ticker, nav ? ":USBANK" : ":XNAS")));
    }

    function _marketId(string memory ticker) internal view returns (bytes32) {
        string memory sk = nav ? ".nav.markets." : ".equity.markets.";
        return vm.parseJsonBytes32(j, string.concat(sk, ticker));
    }

    // ───────────── list a market ─────────────

    function listMarket() external {
        _load();
        string memory ticker = vm.envString("TICKER");
        address token = vm.envAddress("TOKEN");
        address loan = _a(".tokens.loan");
        uint256 unit = _unit(loan);
        bytes32 a = _assetId(ticker);
        MarketKind kind = nav ? MarketKind.NAV : MarketKind.EQUITY;
        _push(
            _a(".shared.oracle"),
            abi.encodeCall(
                OracleAdapter.setAssetConfig,
                (
                    a,
                    nav ? _a(".shared.feedNav") : _a(".shared.feedA"),
                    nav ? address(0) : _a(".shared.feedB"),
                    address(0),
                    token,
                    kind,
                    nav ? 0 : 250_000e18
                )
            ),
            string.concat("oracle.setAssetConfig ", ticker)
        );
        _push(
            _a(".shared.clock"),
            abi.encodeCall(AssetClock.listAsset, (a, nav ? USBANK : XNYS, kind)),
            string.concat("clock.listAsset ", ticker)
        );
        MarketParams memory p = _params(
            loan,
            token,
            a,
            keccak256(bytes(ticker)) == keccak256("SPY"),
            vm.envUint("SUPPLY_CAP") * unit,
            vm.envUint("BORROW_CAP") * unit
        );
        string memory sk = nav ? ".nav." : ".equity.";
        address market = _a(string.concat(sk, "market"));
        address vault = _a(string.concat(sk, "vault"));
        _push(market, abi.encodeCall(CredenceMarket.createMarket, (p)), string.concat("market.createMarket ", ticker));
        bytes32 id = keccak256(abi.encode(p.loanToken, p.collateralToken, p.assetId));
        _push(
            vault,
            abi.encodeCall(SeniorVault.setCap, (id, vm.envUint("VAULT_CAP") * unit)),
            string.concat("vault.setCap ", ticker)
        );
        bytes32[] memory have = SeniorVault(vault).enabledMarkets();
        bytes32[] memory q = new bytes32[](have.length + 1);
        for (uint256 i; i < have.length; ++i) {
            q[i] = have[i];
        }
        q[have.length] = id;
        _push(vault, abi.encodeCall(SeniorVault.setSupplyQueue, (q)), "vault.setSupplyQueue");
        _push(vault, abi.encodeCall(SeniorVault.setWithdrawQueue, (q)), "vault.setWithdrawQueue");
        _write();
    }

    /// @dev The deploy's §12.2 parameters (DeployTestnet `_equityParams` / `_navParams`).
    function _params(address loan, address token, bytes32 a, bool spy, uint256 supplyCap, uint256 borrowCap)
        internal
        view
        returns (MarketParams memory)
    {
        if (nav) {
            return MarketParams({
                loanToken: loan,
                collateralToken: token,
                assetId: a,
                kind: MarketKind.NAV,
                maxLtv: 0.9e18,
                lt: 0.93e18,
                penalty: 0.01e18,
                precloseKappa: 0.01e18,
                precloseLambda: 0.01e18,
                supplyCap: uint128(supplyCap),
                borrowCap: uint128(borrowCap),
                rate: RateParams({r0: 0.01e18, s1: 0.04e18, s2: 0.6e18, uKink: 0.92e18})
            });
        }
        return MarketParams({
            loanToken: loan,
            collateralToken: token,
            assetId: a,
            kind: MarketKind.EQUITY,
            maxLtv: spy ? 0.8e18 : 0.75e18,
            lt: spy ? 0.85e18 : 0.8e18,
            penalty: 0.03e18,
            precloseKappa: 0.01e18,
            precloseLambda: 0.01e18,
            supplyCap: uint128(supplyCap),
            borrowCap: uint128(borrowCap),
            rate: RateParams({r0: 0.02e18, s1: 0.06e18, s2: 0.8e18, uKink: 0.9e18})
        });
    }

    // ───────────── caps ─────────────

    function caps() external {
        _load();
        string memory ticker = vm.envString("TICKER");
        uint256 unit = _unit(_a(".tokens.loan"));
        string memory sk = nav ? ".nav." : ".equity.";
        bytes32 id = _marketId(ticker);
        _push(
            _a(string.concat(sk, "market")),
            abi.encodeCall(
                CredenceMarket.setCaps,
                (id, uint128(vm.envUint("SUPPLY_CAP") * unit), uint128(vm.envUint("BORROW_CAP") * unit))
            ),
            string.concat("market.setCaps ", ticker)
        );
        uint256 vc = vm.envOr("VAULT_CAP", type(uint256).max);
        if (vc != type(uint256).max) {
            _push(
                _a(string.concat(sk, "vault")),
                abi.encodeCall(SeniorVault.setCap, (id, vc * unit)),
                string.concat("vault.setCap ", ticker)
            );
        }
        _write();
    }

    // ───────────── calendar coverage ─────────────

    function calendar() external {
        _load();
        CalendarStore cal = CalendarStore(_a(".shared.calendar"));
        bytes32 venue = nav ? USBANK : XNYS;
        uint256 have = cal.sessionCount(venue);
        uint40 last = have == 0 ? 0 : cal.session(venue, have - 1).extClose;
        Session[] memory s = abi.decode(
            vm.parseJsonBytes(vm.readFile(vm.envString("CALENDAR")), ".sessionsAbiEncoded"), (Session[])
        );
        uint256 from;
        while (from < s.length && s[from].extOpen < last) {
            ++from;
        }
        require(from < s.length, "the calendar file adds no session after the chain's last one");
        for (uint256 i = from; i < s.length; i += PART) {
            uint256 m = s.length - i < PART ? s.length - i : PART;
            Session[] memory part = new Session[](m);
            for (uint256 k; k < m; ++k) {
                part[k] = s[i + k];
            }
            _push(
                address(cal),
                abi.encodeCall(CalendarStore.appendSessions, (venue, part)),
                string.concat("calendar.appendSessions ", vm.toString(m), " from close ", vm.toString(part[0].close))
            );
        }
        _write();
    }
}
