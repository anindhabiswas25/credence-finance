// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Session, MarketParams, MarketWiring, OracleConfig} from "../../src/libraries/Types.sol";
import {CredenceTimelock} from "../../src/governance/CredenceTimelock.sol";
import {ICalendarStore} from "../../src/interfaces/ICalendarStore.sol";
import {ICredenceMarket} from "../../src/interfaces/ICredenceMarket.sol";
import {IOracleAdapter} from "../../src/interfaces/IOracleAdapter.sol";
import {TestnetBase, ISafeSetup} from "./TestnetBase.sol";

interface ITimelocked {
    function timelock() external view returns (address);
}

interface ICommittee {
    function committee() external view returns (address[] memory, uint8);
}

interface IOwned {
    function owner() external view returns (address);
}

interface IIssued {
    function issuer() external view returns (address);
}

interface IGuardianSafe {
    function safe() external view returns (address);
}

interface IAllocated {
    function allocator() external view returns (address);
    function cap(bytes32 id) external view returns (uint256);
    function enabledMarkets() external view returns (bytes32[] memory);
}

interface IFaucetView {
    function dripAmount(address token) external view returns (uint256);
}

interface IRouterView {
    function pricing() external view returns (address);
    function auction() external view returns (address);
    function sigmaOracle() external view returns (address);
}

/// @title `make testnet-postdeploy-check`, the Solidity half (ADR-0122; Build Guide §13.3). Read-only.
/// @notice Checks a finalized stack against its config: timelock roles and delay, the Safes (owners, threshold), every
///         contract's timelock, the guardian's Safe, the vault allocator, the faucet / registry owners and token issuers
///         (no deployer anywhere), the calendar and its coverage, the feed and σ committees, the markets (params, caps,
///         vault caps, engine = the router, not the listing stand-in), the oracle wiring (the stack's own feeds: no
///         Chainlink source, no mock), and the faucet limits. Prints every mismatch, then reverts if there was any.
///         The engine half (risk-set and joint hashes, params, the ADR-0116 fixture, Stylus programs) is in
///         `postdeploy_check.sh`: forge cannot execute the Stylus programs.
/// @dev Env: as DeployTestnet, plus BOOK, DEPLOYER, TIMELOCK_DELAY (default 3600), MIN_COVERAGE_DAYS (default 300).
contract PostDeployCheck is TestnetBase {
    string[] internal fails;
    uint256 internal checks;
    bool internal nav;

    function run() external {
        string memory stack = vm.envString("STACK");
        nav = _checkChain(stack);
        string memory j = vm.readFile(vm.envString("BOOK"));
        address deployer = vm.envAddress("DEPLOYER");
        _governance(j, deployer);
        _calendar(j);
        _committees(j);
        _markets(j, stack);
        _roles(j, deployer);
        console2.log("post-deploy checks:", checks);
        for (uint256 i; i < fails.length; ++i) {
            console2.log("MISMATCH", fails[i]);
        }
        require(fails.length == 0, string.concat(vm.toString(fails.length), " post-deploy mismatch(es)"));
        console2.log("OK: every check passed");
    }

    function _ok(bool c, string memory what) internal {
        ++checks;
        if (!c) fails.push(what);
    }

    function _eqA(address a, address b, string memory what) internal {
        _ok(a == b, string.concat(what, ": ", vm.toString(a), " != ", vm.toString(b)));
    }

    function _governance(string memory j, address deployer) internal {
        CredenceTimelock tl = CredenceTimelock(payable(vm.parseJsonAddress(j, ".shared.timelock")));
        address gov = vm.parseJsonAddress(j, ".safes.gov");
        _ok(vm.parseJsonBool(j, ".finalized"), "book not finalized (FinalizeTestnet not run)");
        _ok(tl.getMinDelay() == vm.envOr("TIMELOCK_DELAY", uint256(3600)), "timelock delay");
        _ok(tl.hasRole(tl.PROPOSER_ROLE(), gov), "Gov Safe is not proposer");
        _ok(tl.hasRole(tl.CANCELLER_ROLE(), gov), "Gov Safe is not canceller");
        _ok(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "execution is not open (executor address(0))");
        _ok(!tl.hasRole(tl.PROPOSER_ROLE(), deployer), "deployer still proposer");
        _ok(!tl.hasRole(tl.CANCELLER_ROLE(), deployer), "deployer still canceller");
        _ok(!tl.hasRole(tl.EXECUTOR_ROLE(), deployer), "deployer still executor");
        _ok(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), deployer), "deployer is timelock admin");
        _ok(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(tl)), "timelock is not its own admin");
        string[3] memory names = ["GOV", "GUARDIAN", "OPS"];
        string[3] memory keys = [".safes.gov", ".safes.guardian", ".safes.ops"];
        for (uint256 i; i < 3; ++i) {
            address s = vm.parseJsonAddress(j, keys[i]);
            _ok(s.code.length != 0, string.concat(names[i], " Safe has no code"));
            string memory ok = string.concat("SAFE_", names[i], "_OWNERS");
            if (s.code.length == 0 || bytes(vm.envOr(ok, string(""))).length == 0) continue;
            address[] memory want = vm.envAddress(ok, ",");
            address[] memory got = ISafeSetup(s).getOwners();
            _ok(_sameSet(want, got), string.concat(names[i], " Safe owners"));
            _ok(
                ISafeSetup(s).getThreshold() == vm.envUint(string.concat("SAFE_", names[i], "_THRESHOLD")),
                string.concat(names[i], " Safe threshold")
            );
        }
        string[6] memory shared = [
            ".shared.guardian",
            ".shared.calendar",
            ".shared.clock",
            ".shared.oracle",
            ".shared.sigmaOracle",
            ".shared.riskEngine"
        ];
        for (uint256 i; i < shared.length; ++i) {
            _eqA(ITimelocked(vm.parseJsonAddress(j, shared[i])).timelock(), address(tl), shared[i]);
        }
        string[6] memory own = [".market", ".vault", ".pool", ".reserve", ".treasury", ".tips"];
        for (uint256 i; i < own.length; ++i) {
            string memory key = string.concat(nav ? ".nav" : ".equity", own[i]);
            _eqA(ITimelocked(vm.parseJsonAddress(j, key)).timelock(), address(tl), key);
        }
        _eqA(
            IGuardianSafe(vm.parseJsonAddress(j, ".shared.guardian")).safe(),
            vm.parseJsonAddress(j, ".safes.guardian"),
            "guardian Safe"
        );
    }

    function _calendar(string memory j) internal {
        ICalendarStore cal = ICalendarStore(vm.parseJsonAddress(j, ".shared.calendar"));
        bytes32 venue = nav ? bytes32("USBANK") : bytes32("XNYS");
        Session[] memory s = abi.decode(
            vm.parseJsonBytes(vm.readFile(vm.envString("CALENDAR")), ".sessionsAbiEncoded"), (Session[])
        );
        _ok(cal.sessionCount(venue) == s.length, "calendar session count != the calendar file");
        uint256 minDays = vm.envOr("MIN_COVERAGE_DAYS", uint256(300));
        _ok(cal.coverageEnd(venue) >= block.timestamp + minDays * 1 days, "calendar coverage ends too soon");
    }

    function _committees(string memory j) internal {
        uint8 thr = uint8(vm.envOr("RELAYER_THRESHOLD", uint256(2)));
        if (nav) {
            _committee(vm.parseJsonAddress(j, ".shared.feedNav"), "NAV_SIGNERS", thr, "NAV feed");
        } else {
            _committee(vm.parseJsonAddress(j, ".shared.feedA"), "RELAYER_A_SIGNERS", thr, "feed A");
            _committee(vm.parseJsonAddress(j, ".shared.feedB"), "RELAYER_B_SIGNERS", thr, "feed B");
        }
        _committee(
            vm.parseJsonAddress(j, ".shared.sigmaOracle"),
            "SIGMA_SIGNERS",
            uint8(vm.envOr("SIGMA_THRESHOLD", uint256(2))),
            "sigma oracle"
        );
        IRouterView r = IRouterView(vm.parseJsonAddress(j, ".shared.riskEngine"));
        _eqA(r.sigmaOracle(), vm.parseJsonAddress(j, ".shared.sigmaOracle"), "engine sigma writer");
        _ok(r.pricing() != address(0) && r.auction() != address(0), "engine router not wired to its programs");
    }

    function _committee(address c, string memory key, uint8 thr, string memory what) internal {
        (address[] memory got, uint8 t) = ICommittee(c).committee();
        _ok(_sameSet(vm.envAddress(key, ","), got), string.concat(what, " signers"));
        _ok(t == thr, string.concat(what, " threshold"));
    }

    function _markets(string memory j, string memory stack) internal {
        string memory sk = nav ? ".nav" : ".equity";
        ICredenceMarket m = ICredenceMarket(vm.parseJsonAddress(j, string.concat(sk, ".market")));
        IAllocated v = IAllocated(vm.parseJsonAddress(j, string.concat(sk, ".vault")));
        IOracleAdapter orc = IOracleAdapter(vm.parseJsonAddress(j, ".shared.oracle"));
        MarketWiring memory w = m.wiring();
        address router = vm.parseJsonAddress(j, ".shared.riskEngine");
        _eqA(w.engine, router, "market engine (the router, not the listing stand-in)");
        _eqA(w.clock, vm.parseJsonAddress(j, ".shared.clock"), "market clock");
        _eqA(w.oracle, address(orc), "market oracle");
        string[] memory tickers = vm.envString("ASSETS", ",");
        uint256[] memory sup = vm.envUint("ASSET_SUPPLY_CAPS", ",");
        uint256[] memory bor = vm.envUint("ASSET_BORROW_CAPS", ",");
        uint256[] memory vc = vm.envUint("ASSET_VAULT_CAPS", ",");
        uint256[] memory drips = vm.envUint("ASSET_FAUCET", ",");
        address loan = vm.parseJsonAddress(j, ".tokens.loan");
        uint256 unit = 10 ** _dec(loan);
        address faucet = vm.parseJsonAddress(j, ".shared.faucet");
        _ok(m.marketIds().length == tickers.length, "market count != ASSETS");
        _ok(v.enabledMarkets().length == tickers.length, "vault market count != ASSETS");
        address feedP = vm.parseJsonAddress(j, nav ? ".shared.feedNav" : ".shared.feedA");
        address feedS = nav ? address(0) : vm.parseJsonAddress(j, ".shared.feedB");
        for (uint256 i; i < tickers.length; ++i) {
            string memory t = tickers[i];
            bytes32 id = vm.parseJsonBytes32(j, string.concat(sk, ".markets.", t));
            bytes32 a = vm.parseJsonBytes32(j, string.concat(".assetIds.", t));
            address token = vm.parseJsonAddress(j, string.concat(".tokens.t", t));
            MarketParams memory p = m.marketParams(id);
            _eqA(p.loanToken, loan, string.concat(t, " loan token"));
            _eqA(p.collateralToken, token, string.concat(t, " collateral"));
            _ok(p.assetId == a, string.concat(t, " asset id"));
            _ok(p.supplyCap == sup[i] * unit, string.concat(t, " supply cap"));
            _ok(p.borrowCap == bor[i] * unit, string.concat(t, " borrow cap"));
            _ok(v.cap(id) == vc[i] * unit, string.concat(t, " vault cap"));
            OracleConfig memory oc = orc.config(a);
            _eqA(oc.primary, feedP, string.concat(t, " oracle primary (the stack's own feed)"));
            _eqA(oc.secondary, feedS, string.concat(t, " oracle secondary"));
            _eqA(oc.dex, address(0), string.concat(t, " no DEX source wired"));
            _eqA(oc.token, token, string.concat(t, " oracle token"));
            uint256 want = drips[i] * 1e18;
            _ok(IFaucetView(faucet).dripAmount(token) == want, string.concat(t, " faucet drip"));
        }
        stack; // the stack name only selects keys
    }

    function _roles(string memory j, address deployer) internal {
        address ops = vm.parseJsonAddress(j, ".safes.ops");
        string memory sk = nav ? ".nav" : ".equity";
        _eqA(
            IAllocated(vm.parseJsonAddress(j, string.concat(sk, ".vault"))).allocator(),
            ops,
            "vault allocator"
        );
        _eqA(IOwned(vm.parseJsonAddress(j, ".shared.faucet")).owner(), ops, "faucet owner");
        if (nav) _eqA(IOwned(vm.parseJsonAddress(j, ".shared.registry")).owner(), ops, "registry owner");
        string[] memory tickers = vm.envString("ASSETS", ",");
        address fundIssuer = vm.envOr("FUND_ISSUER", ops);
        for (uint256 i; i < tickers.length; ++i) {
            address token = vm.parseJsonAddress(j, string.concat(".tokens.t", tickers[i]));
            (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSignature("issuer()"));
            if (!ok || r.length < 32) continue; // not ours (e.g. the official Robinhood token)
            address iss = abi.decode(r, (address));
            _ok(iss != deployer, string.concat(tickers[i], " issuer is the deployer"));
            _eqA(iss, nav ? fundIssuer : ops, string.concat(tickers[i], " issuer"));
        }
        address loan = vm.parseJsonAddress(j, ".tokens.loan");
        (bool lok, bytes memory lr) = loan.staticcall(abi.encodeWithSignature("issuer()"));
        if (lok && lr.length >= 32) _eqA(abi.decode(lr, (address)), ops, "loan token issuer");
    }

    function _sameSet(address[] memory a, address[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i; i < a.length; ++i) {
            bool found;
            for (uint256 k; k < b.length; ++k) {
                if (a[i] == b[k]) found = true;
            }
            if (!found) return false;
        }
        return true;
    }

    function _dec(address token) internal view returns (uint256) {
        (, bytes memory r) = token.staticcall(abi.encodeWithSignature("decimals()"));
        return abi.decode(r, (uint8));
    }
}
