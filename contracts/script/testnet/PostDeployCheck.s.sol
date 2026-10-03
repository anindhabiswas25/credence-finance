// SPDX-License-Identifier: MIT
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

interface IWiredOnce {
    function clock() external view returns (address);
    function market() external view returns (address);
    function pool() external view returns (address);
    function engine() external view returns (address);
    function oracle() external view returns (address);
    function wired() external view returns (bool);
    function isPayer(address) external view returns (bool);
}

interface IErc20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
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
///         contract's timelock, the guardian's Safe, the Safes' singleton / fallback handler / factory address, every
///         deployer-only one-shot wiring done (so the deployer has no power left), the vault allocator, the faucet / registry owners and token issuers
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
        _safes(j, stack);
        _calendar(j);
        _committees(j);
        _markets(j, stack);
        _tokens(j);
        _wired(j);
        _roles(j, deployer);
        console2.log("post-deploy checks:", checks);
        for (uint256 i; i < fails.length; ++i) {
            console2.log("MISMATCH", fails[i]);
        }
        // forge drops console output when a script reverts, so the revert reason carries every mismatch
        string memory all = string.concat(vm.toString(fails.length), " post-deploy mismatch(es)");
        for (uint256 i; i < fails.length; ++i) {
            all = string.concat(all, " | MISMATCH ", fails[i]);
        }
        require(fails.length == 0, all);
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
            // a proxy with another singleton may answer nothing (an undecodable, uncatchable return): read owners only
            // behind the canonical singleton; `_safes` reports the singleton itself
            if (address(uint160(uint256(vm.load(s, 0)))) != SAFE_L2) continue;
            address[] memory want = vm.envAddress(ok, ",");
            _ok(_sameSet(want, ISafeSetup(s).getOwners()), string.concat(names[i], " Safe owners"));
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

    /// @dev Each Safe is a SafeProxy of the canonical factory: singleton (slot 0) = Safe L2 v1.4.1, the canonical
    ///      fallback handler, and (when the deploy created it) the CREATE2 address the factory gives its owners.
    function _safes(string memory j, string memory stack) internal {
        _ok(SAFE_FACTORY.code.length != 0, "canonical Safe factory has no code");
        string[3] memory names = ["GOV", "GUARDIAN", "OPS"];
        string[3] memory keys = [".safes.gov", ".safes.guardian", ".safes.ops"];
        bytes32 handlerSlot = keccak256("fallback_manager.handler.address");
        for (uint256 i; i < 3; ++i) {
            address s = vm.parseJsonAddress(j, keys[i]);
            _eqA(address(uint160(uint256(vm.load(s, 0)))), SAFE_L2, string.concat(names[i], " Safe singleton"));
            _eqA(
                address(uint160(uint256(vm.load(s, handlerSlot)))),
                SAFE_FALLBACK,
                string.concat(names[i], " Safe fallback handler")
            );
            if (vm.envOr(string.concat("SAFE_", names[i], "_ADDRESS"), address(0)) != address(0)) continue;
            (,, address predicted) = _safePlan(stack, names[i]);
            _eqA(s, predicted, string.concat(names[i], " Safe address (canonical factory, configured owners)"));
        }
    }

    /// @dev The loan token is the configured one (an address) or the stack's own test stablecoin (tUSDG on 46630),
    ///      and every configured existing collateral token (the official Robinhood test TSLA) is the one listed.
    function _tokens(string memory j) internal {
        address loan = vm.parseJsonAddress(j, ".tokens.loan");
        address want = vm.envOr("LOAN_TOKEN", address(0));
        if (want != address(0)) {
            _eqA(loan, want, "loan token (configured address)");
        } else {
            _ok(
                keccak256(bytes(IErc20Meta(loan).symbol())) == keccak256(bytes(vm.envString("LOAN_SYMBOL"))),
                string.concat("loan token symbol != ", vm.envString("LOAN_SYMBOL"))
            );
            _ok(IErc20Meta(loan).decimals() == vm.envUint("LOAN_DECIMALS"), "loan token decimals");
        }
        string[] memory tickers = vm.envString("ASSETS", ",");
        string[] memory tok = vm.envString("ASSET_TOKENS", ",");
        bool dry = vm.envOr("DRY_RUN", false);
        for (uint256 i; i < tickers.length; ++i) {
            if (keccak256(bytes(tok[i])) == keccak256("new")) continue;
            address got = vm.parseJsonAddress(j, string.concat(".tokens.t", tickers[i]));
            _ok(got.code.length != 0, string.concat(tickers[i], " token has no code"));
            // the dry run lists a behavioural copy of the official token (it does not exist on plain anvil)
            if (!dry) _eqA(got, vm.parseAddress(tok[i]), string.concat(tickers[i], " token (configured address)"));
        }
    }

    /// @dev Every deployer-only, one-shot initializer has run, so the deployer's `immutable deployer` gate is dead.
    function _wired(string memory j) internal {
        string memory sk = nav ? ".nav" : ".equity";
        address clock = vm.parseJsonAddress(j, ".shared.clock");
        address oracle = vm.parseJsonAddress(j, ".shared.oracle");
        address market = vm.parseJsonAddress(j, string.concat(sk, ".market"));
        address pool = vm.parseJsonAddress(j, string.concat(sk, ".pool"));
        address tips = vm.parseJsonAddress(j, string.concat(sk, ".tips"));
        _eqA(IWiredOnce(vm.parseJsonAddress(j, ".shared.sequencerHealth")).clock(), clock, "sequencer health clock");
        _ok(IWiredOnce(clock).wired(), "clock not wired");
        _eqA(IWiredOnce(clock).oracle(), oracle, "clock oracle");
        _eqA(IWiredOnce(oracle).clock(), clock, "oracle clock");
        _eqA(IWiredOnce(vm.parseJsonAddress(j, ".shared.guardian")).clock(), clock, "guardian clock");
        _eqA(
            IWiredOnce(vm.parseJsonAddress(j, ".shared.sigmaOracle")).engine(),
            vm.parseJsonAddress(j, ".shared.riskEngine"),
            "sigma oracle engine"
        );
        _eqA(IWiredOnce(vm.parseJsonAddress(j, string.concat(sk, ".reserve"))).market(), market, "reserve market");
        _eqA(IWiredOnce(pool).market(), market, "pool market");
        address third = vm.parseJsonAddress(j, string.concat(sk, nav ? ".settlement" : ".auctionHouse"));
        _eqA(IWiredOnce(third).market(), market, nav ? "settlement market" : "auction house market");
        _eqA(IWiredOnce(third).pool(), pool, nav ? "settlement pool" : "auction house pool");
        _ok(IWiredOnce(tips).isPayer(market), "tips: market is not a payer");
        _ok(IWiredOnce(tips).isPayer(pool), "tips: pool is not a payer");
        _ok(IWiredOnce(tips).isPayer(third), "tips: auction house / settlement is not a payer");
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
        if (nav) {
            // testnet: a dedicated issuer EOA publishes the daily NAV (nav-strike), not the Ops Safe (PM 2026-09-30)
            _ok(fundIssuer != ops, "fund issuer is the Ops Safe (testnet wants the dedicated issuer EOA)");
            _ok(fundIssuer.code.length == 0, "fund issuer is a contract (testnet wants the dedicated issuer EOA)");
            _ok(fundIssuer != deployer, "fund issuer is the deployer");
        }
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
