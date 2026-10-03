// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    Session,
    MarketParams,
    MarketKind,
    RateParams,
    MarketWiring,
    RiskParams
} from "../../src/libraries/Types.sol";
import {CredenceTimelock} from "../../src/governance/CredenceTimelock.sol";
import {CredenceGuardian} from "../../src/governance/CredenceGuardian.sol";
import {CalendarStore} from "../../src/clock/CalendarStore.sol";
import {AssetClock} from "../../src/clock/AssetClock.sol";
import {SequencerHealth} from "../../src/oracle/SequencerHealth.sol";
import {CredencePriceFeed} from "../../src/oracle/CredencePriceFeed.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {SigmaOracle} from "../../src/oracle/SigmaOracle.sol";
import {RiskEngineRouter} from "../../src/risk/RiskEngineRouter.sol";
import {CredenceMarket} from "../../src/core/CredenceMarket.sol";
import {SeniorVault} from "../../src/core/SeniorVault.sol";
import {KeeperTips} from "../../src/core/KeeperTips.sol";
import {Treasury} from "../../src/core/Treasury.sol";
import {ProtocolReserve} from "../../src/core/ProtocolReserve.sol";
import {UnderwriterPool} from "../../src/pool/UnderwriterPool.sol";
import {AuctionHouse} from "../../src/auction/AuctionHouse.sol";
import {SettlementAdapter} from "../../src/settlement/SettlementAdapter.sol";
import {SolverAuction} from "../../src/settlement/SolverAuction.sol";
import {CredenceStockToken} from "../../src/testnet/CredenceStockToken.sol";
import {CredenceTreasuryFund} from "../../src/testnet/CredenceTreasuryFund.sol";
import {ComplianceRegistry} from "../../src/testnet/ComplianceRegistry.sol";
import {Faucet} from "../../src/testnet/Faucet.sol";
import {TestStablecoin} from "../../src/testnet/TestStablecoin.sol";
import {ListingParamsEngine} from "./ListingParamsEngine.sol";
import {TestnetBase} from "./TestnetBase.sol";

/// @title One testnet stack, first phase (ADR-0122): `STACK=equity` on Robinhood Chain testnet (46630), `STACK=nav` on
///        Arbitrum Sepolia (421614). Each chain gets its own Safes, timelock, guardian, calendar, clock, feeds, oracle,
///        σ oracle, engine router, market, vault, pool, reserve, treasury, tips and faucet (R-01: no bridge).
/// @notice The deployer holds the timelock's proposer and executor roles at delay 0 during the deploy, so every timelock
///         call runs at once in batches; `FinalizeTestnet` then hands the timelock to the Gov Safe at 1 h and revokes
///         every deployer role. Between the two, `deploy.sh` deploys the Stylus programs, wires the router and loads
///         the risk bundles through the timelock. Refuses a re-run (the book exists), a missing Safe or signer list,
///         and any chain but the stack's own (plain anvil only with DRY_RUN=1).
/// @dev Env (deploy.sh sets it from `script/testnet/config/<chainId>.json`): STACK, BOOK_OUT, RELEASE, CALENDAR,
///      SAFE_{GOV,GUARDIAN,OPS}_{OWNERS,THRESHOLD|ADDRESS}, RELAYER_A_SIGNERS, RELAYER_B_SIGNERS (equity) or NAV_SIGNERS
///      (nav), RELAYER_THRESHOLD, SIGMA_SIGNERS, SIGMA_THRESHOLD, RISK_BUNDLE (its params list the markets),
///      LOAN_TOKEN or LOAN_NAME/LOAN_SYMBOL/LOAN_DECIMALS/LOAN_FAUCET, ASSETS, ASSET_TOKENS ("new" or an address),
///      ASSET_SUPPLY_CAPS / ASSET_BORROW_CAPS / ASSET_VAULT_CAPS (whole loan units), ASSET_FAUCET (whole tokens, 0 =
///      none), MIN_BID; nav: FUND_ISSUER, FUND_RESERVE, NAV_SOLVERS, REGISTRY_OPERATORS, SETTLEMENT_WINDOW.
contract DeployTestnet is TestnetBase {
    struct Out {
        address gov;
        address guardianSafe;
        address ops;
        CredenceTimelock timelock;
        CredenceGuardian guardian;
        CalendarStore calendar;
        SequencerHealth seq;
        AssetClock clock;
        CredencePriceFeed feedA;
        CredencePriceFeed feedB;
        CredencePriceFeed feedNav;
        OracleAdapter oracle;
        SigmaOracle sigmaOracle;
        RiskEngineRouter router;
        ListingParamsEngine listing;
        address loan;
        Faucet faucet;
        ComplianceRegistry registry;
        CredenceMarket market;
        SeniorVault vault;
        KeeperTips tips;
        Treasury treasury;
        ProtocolReserve reserve;
        UnderwriterPool pool;
        AuctionHouse house;
        SettlementAdapter settlement;
        SolverAuction solver;
        string[] tickers;
        address[] tokens;
        bytes32[] assetIds;
        bytes32[] marketIds;
    }

    bytes32 internal constant XNYS = bytes32("XNYS");
    bytes32 internal constant USBANK = bytes32("USBANK");

    Out internal o;
    string internal stack;
    bool internal nav;
    address internal me;

    function run() external {
        stack = vm.envString("STACK");
        nav = _checkChain(stack);
        string memory book = vm.envString("BOOK_OUT");
        if (vm.exists(book)) revert AlreadyDeployed(book);
        // fail loudly on a missing input before anything is sent
        _requireEnv("CALENDAR");
        _requireEnv("RISK_BUNDLE");
        _requireEnv(nav ? "NAV_SIGNERS" : "RELAYER_A_SIGNERS");
        if (!nav) _requireEnv("RELAYER_B_SIGNERS");
        _requireEnv("SIGMA_SIGNERS");
        _requireEnv("ASSETS");
        if (nav) (_requireEnv("FUND_ISSUER"), _requireEnv("FUND_RESERVE"));

        uint256 pk;
        (me, pk) = _signer();
        uint256 startBlock = block.number;
        _broadcast(me, pk);
        _governance();
        _clockAndPrices();
        _risk();
        _loanAndTokens();
        _stack();
        _listMarkets();
        _handOver();
        vm.stopBroadcast();
        _writeBook(book, startBlock);
        console2.log("stack deployed; book:", book);
    }

    // ───────────── 1. Safes, timelock (delay 0, deployer roles until FinalizeTestnet), guardian ─────────────

    function _governance() internal {
        o.gov = _safe(stack, "GOV");
        o.guardianSafe = _safe(stack, "GUARDIAN");
        o.ops = _safe(stack, "OPS");
        address[] memory mine = new address[](1);
        mine[0] = me;
        o.timelock = new CredenceTimelock(0, mine, mine);
        o.guardian = new CredenceGuardian(address(o.timelock), o.guardianSafe);
    }

    // ───────────── 2. calendar, clock, feeds, oracle ─────────────

    function _clockAndPrices() internal {
        address tl = address(o.timelock);
        o.calendar = new CalendarStore(tl);
        o.seq = new SequencerHealth();
        o.clock = new AssetClock(tl, address(o.guardian), address(o.calendar), address(o.seq));
        o.seq.setClock(address(o.clock));
        uint8 thr = uint8(vm.envOr("RELAYER_THRESHOLD", uint256(2)));
        if (nav) {
            o.feedNav = new CredencePriceFeed(tl, _sorted(vm.envAddress("NAV_SIGNERS", ",")), thr);
        } else {
            o.feedA = new CredencePriceFeed(tl, _sorted(vm.envAddress("RELAYER_A_SIGNERS", ",")), thr);
            o.feedB = new CredencePriceFeed(tl, _sorted(vm.envAddress("RELAYER_B_SIGNERS", ",")), thr);
        }
        o.oracle = new OracleAdapter(tl);
        o.oracle.setClock(address(o.clock));
        Session[] memory s = abi.decode(
            vm.parseJsonBytes(vm.readFile(vm.envString("CALENDAR")), ".sessionsAbiEncoded"), (Session[])
        );
        bytes32 venue = nav ? USBANK : XNYS;
        for (uint256 i; i < s.length; i += 60) {
            uint256 n = s.length - i < 60 ? s.length - i : 60;
            Session[] memory part = new Session[](n);
            for (uint256 j; j < n; ++j) {
                part[j] = s[i + j];
            }
            _gov(address(o.calendar), abi.encodeCall(CalendarStore.appendSessions, (venue, part)));
        }
        _flush(o.timelock, stack);
    }

    // ───────────── 3. σ oracle, engine router (programs come from deploy.sh), listing stand-in ─────────────

    function _risk() internal {
        address tl = address(o.timelock);
        o.sigmaOracle = new SigmaOracle(
            tl, _sorted(vm.envAddress("SIGMA_SIGNERS", ",")), uint8(vm.envOr("SIGMA_THRESHOLD", uint256(2)))
        );
        o.router = new RiskEngineRouter(tl, address(o.sigmaOracle));
        o.sigmaOracle.initializeWiring(address(o.router));
        o.listing = new ListingParamsEngine(_bundleParams());
    }

    function _bundleParams() internal view returns (RiskParams memory p) {
        string memory j = vm.readFile(vm.envString("RISK_BUNDLE"));
        p.alpha = uint64(vm.parseUint(vm.parseJsonString(j, ".params.alpha")));
        p.kappa = uint64(vm.parseUint(vm.parseJsonString(j, ".params.kappa")));
        p.theta = uint64(vm.parseUint(vm.parseJsonString(j, ".params.theta")));
        p.costOfCap = uint64(vm.parseUint(vm.parseJsonString(j, ".params.costOfCap")));
        p.eta = uint64(vm.parseUint(vm.parseJsonString(j, ".params.eta")));
        p.beta = uint64(vm.parseUint(vm.parseJsonString(j, ".params.beta")));
        p.uMax = uint64(vm.parseUint(vm.parseJsonString(j, ".params.uMax")));
        p.minPremium = uint64(vm.parseUint(vm.parseJsonString(j, ".params.minPremium")));
        p.kStress = uint32(vm.parseJsonUint(j, ".params.kStress"));
    }

    // ───────────── 4. loan token, collateral tokens, faucet (issuer = deployer until _handOver) ─────────────

    function _loanAndTokens() internal {
        o.faucet = new Faucet(me);
        o.loan = vm.envOr("LOAN_TOKEN", address(0));
        if (o.loan == address(0)) {
            TestStablecoin t = new TestStablecoin(
                vm.envString("LOAN_NAME"), vm.envString("LOAN_SYMBOL"), uint8(vm.envUint("LOAN_DECIMALS")), me
            );
            uint256 drip = vm.envOr("LOAN_FAUCET", uint256(0)) * 10 ** t.decimals();
            if (drip != 0) {
                t.setMinter(address(o.faucet), type(uint128).max);
                o.faucet.configure(address(t), drip, false);
            }
            o.loan = address(t);
        }
        o.tickers = vm.envString("ASSETS", ",");
        string[] memory tok = vm.envString("ASSET_TOKENS", ",");
        uint256[] memory drips = vm.envUint("ASSET_FAUCET", ",");
        uint256 n = o.tickers.length;
        if (tok.length != n || drips.length != n) revert MissingConfig("ASSET_TOKENS / ASSET_FAUCET length");
        o.tokens = new address[](n);
        o.assetIds = new bytes32[](n);
        if (nav) {
            o.registry = new ComplianceRegistry(me);
            o.registry.setAllowed(me, true);
        }
        for (uint256 i; i < n; ++i) {
            o.assetIds[i] = keccak256(bytes(string.concat(o.tickers[i], nav ? ":USBANK" : ":XNAS")));
            if (keccak256(bytes(tok[i])) != keccak256("new")) {
                o.tokens[i] = vm.parseAddress(tok[i]); // an existing token (e.g. the official Robinhood test TSLA)
                continue;
            }
            if (nav) {
                CredenceTreasuryFund f = new CredenceTreasuryFund(
                    "Credence Test T-Bill Fund",
                    string.concat("t", o.tickers[i]),
                    me,
                    address(o.registry),
                    o.loan,
                    vm.envAddress("FUND_RESERVE"),
                    1e18
                );
                if (drips[i] != 0) {
                    f.setMinter(address(o.faucet), type(uint128).max);
                    o.faucet.configure(address(f), drips[i] * 1e18, true);
                }
                o.tokens[i] = address(f);
            } else {
                CredenceStockToken t = new CredenceStockToken(
                    string.concat("Credence Test ", o.tickers[i]),
                    string.concat("t", o.tickers[i]),
                    me,
                    address(0)
                );
                if (drips[i] != 0) {
                    t.setMinter(address(o.faucet), type(uint128).max);
                    o.faucet.configure(address(t), drips[i] * 1e18, false);
                }
                o.tokens[i] = address(t);
            }
        }
    }

    // ───────────── 5. the lending stack ─────────────

    function _stack() internal {
        address tl = address(o.timelock);
        o.tips = new KeeperTips(tl, o.loan);
        o.treasury = new Treasury(tl, o.loan, address(o.tips));
        o.reserve = new ProtocolReserve(tl, o.loan, address(o.treasury));
        o.market = new CredenceMarket(tl, address(o.guardian));
        o.vault = new SeniorVault(
            IERC20(o.loan),
            nav ? "Credence Senior USDC (funds)" : "Credence Senior tUSDG (equity)",
            nav ? "csUSDC-NAV" : "csUSDG-EQ",
            tl,
            address(o.market),
            o.ops
        );
        if (nav) {
            o.pool = new UnderwriterPool(
                tl, IERC20(o.loan), USBANK, "Credence Underwriter USDC (funds)", "cfUP-NAV"
            );
            o.settlement = new SettlementAdapter(tl);
            o.solver = new SolverAuction(tl);
        } else {
            o.pool = new UnderwriterPool(
                tl, IERC20(o.loan), XNYS, "Credence Underwriter tUSDG (equity)", "cfUP-EQ"
            );
            o.house = new AuctionHouse(tl);
        }
        o.market
            .initializeWiring(
                MarketWiring({
                    clock: address(o.clock),
                    oracle: address(o.oracle),
                    engine: address(o.listing),
                    vault: address(o.vault),
                    pool: address(o.pool),
                    auctionHouse: address(o.house),
                    settlement: address(o.settlement),
                    reserve: address(o.reserve),
                    treasury: address(o.treasury),
                    tips: address(o.tips)
                })
            );
        // the pool, the auction house, the adapter and the venue are wired by their timelock
        _gov(
            address(o.pool),
            abi.encodeCall(
                UnderwriterPool.initializeWiring,
                (
                    address(o.market),
                    address(o.house),
                    address(o.settlement),
                    address(o.clock),
                    address(o.tips)
                )
            )
        );
        if (nav) {
            address[] memory venues = new address[](1);
            venues[0] = address(o.solver);
            _gov(
                address(o.settlement),
                abi.encodeCall(
                    SettlementAdapter.initializeWiring,
                    (address(o.market), address(o.pool), address(o.tips), venues)
                )
            );
            _gov(
                address(o.solver),
                abi.encodeCall(SolverAuction.initializeWiring, (address(o.settlement), o.loan))
            );
        } else {
            uint128 minBid = uint128(vm.envOr("MIN_BID", uint256(100)) * 10 ** _dec(o.loan));
            _gov(
                address(o.house),
                abi.encodeCall(
                    AuctionHouse.initializeWiring,
                    (address(o.market), address(o.pool), address(o.clock), address(o.tips), XNYS, minBid)
                )
            );
        }
        _flush(o.timelock, stack);
        o.reserve.initializeWiring(address(o.market));
        address[] memory payers = new address[](3);
        (payers[0], payers[1]) = (address(o.market), address(o.pool));
        payers[2] = nav ? address(o.settlement) : address(o.house);
        o.tips.initializeWiring(payers);
        address[] memory markets = new address[](1);
        markets[0] = address(o.market);
        o.guardian.initializeWiring(markets, address(o.clock));
        o.clock.initializeWiring(address(o.oracle), address(o.house), address(o.settlement));
    }

    // ───────────── 6. listing, through the timelock ─────────────

    function _listMarkets() internal {
        uint256 n = o.tickers.length;
        uint256[] memory sup = vm.envUint("ASSET_SUPPLY_CAPS", ",");
        uint256[] memory bor = vm.envUint("ASSET_BORROW_CAPS", ",");
        uint256[] memory vc = vm.envUint("ASSET_VAULT_CAPS", ",");
        if (sup.length != n || bor.length != n || vc.length != n) {
            revert MissingConfig("ASSET_*_CAPS length");
        }
        uint256 unit = 10 ** _dec(o.loan);
        o.marketIds = new bytes32[](n);
        bytes32 venue = nav ? USBANK : XNYS;
        MarketKind kind = nav ? MarketKind.NAV : MarketKind.EQUITY;
        for (uint256 i; i < n; ++i) {
            bytes32 a = o.assetIds[i];
            _gov(
                address(o.oracle),
                abi.encodeCall(
                    OracleAdapter.setAssetConfig,
                    (
                        a,
                        nav ? address(o.feedNav) : address(o.feedA),
                        nav ? address(0) : address(o.feedB),
                        address(0),
                        o.tokens[i],
                        kind,
                        nav ? 0 : 250_000e18
                    )
                )
            );
            _gov(address(o.clock), abi.encodeCall(AssetClock.listAsset, (a, venue, kind)));
            MarketParams memory p = nav
                ? _navParams(o.tokens[i], a, sup[i] * unit, bor[i] * unit)
                : _equityParams(
                    o.tokens[i],
                    a,
                    keccak256(bytes(o.tickers[i])) == keccak256("SPY"),
                    sup[i] * unit,
                    bor[i] * unit
                );
            _gov(address(o.market), abi.encodeCall(CredenceMarket.createMarket, (p)));
            o.marketIds[i] = keccak256(abi.encode(p.loanToken, p.collateralToken, p.assetId));
        }
        _gov(address(o.market), abi.encodeCall(CredenceMarket.setEngine, (address(o.router))));
        _gov(address(o.market), abi.encodeCall(CredenceMarket.setReserveFeeShare, (3000))); // §12.2
        for (uint256 i; i < n; ++i) {
            _gov(address(o.vault), abi.encodeCall(SeniorVault.setCap, (o.marketIds[i], vc[i] * unit)));
        }
        _gov(address(o.vault), abi.encodeCall(SeniorVault.setSupplyQueue, (o.marketIds)));
        _gov(address(o.vault), abi.encodeCall(SeniorVault.setWithdrawQueue, (o.marketIds)));
        if (nav) {
            _gov(
                address(o.settlement),
                abi.encodeCall(
                    SettlementAdapter.setWindow, (uint40(vm.envOr("SETTLEMENT_WINDOW", uint256(900))))
                )
            );
            address[] memory solvers = vm.envOr("NAV_SOLVERS", ",", new address[](0));
            for (uint256 i; i < solvers.length; ++i) {
                _gov(address(o.solver), abi.encodeCall(SolverAuction.setSolver, (solvers[i], true)));
            }
        }
        _flush(o.timelock, stack);
    }

    // ───────────── 7. hand the non-timelock roles to their owners ─────────────

    function _handOver() internal {
        if (nav) {
            // tTBILL moves only between allowlisted holders: the market, the adapter, the venue, the pool, the solvers
            address[] memory allow = new address[](4);
            (allow[0], allow[1], allow[2], allow[3]) =
            (address(o.market), address(o.settlement), address(o.solver), address(o.pool));
            o.registry.setAllowedBatch(allow, true);
            address[] memory solvers = vm.envOr("NAV_SOLVERS", ",", new address[](0));
            if (solvers.length != 0) o.registry.setAllowedBatch(solvers, true);
            o.registry.setAllowed(me, false);
            address[] memory ops = vm.envOr("REGISTRY_OPERATORS", ",", new address[](0));
            for (uint256 i; i < ops.length; ++i) {
                o.registry.setOperator(ops[i], true);
            }
            o.registry.transferOwnership(o.ops);
        }
        address fundIssuer = vm.envOr("FUND_ISSUER", o.ops);
        for (uint256 i; i < o.tokens.length; ++i) {
            if (!_mine(o.tokens[i])) continue;
            if (nav) CredenceTreasuryFund(o.tokens[i]).transferIssuer(fundIssuer);
            else CredenceStockToken(o.tokens[i]).transferIssuer(o.ops);
        }
        if (_mine(o.loan)) TestStablecoin(o.loan).transferIssuer(o.ops);
        o.faucet.transferOwnership(o.ops);
    }

    function _mine(address token) internal view returns (bool) {
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSignature("issuer()"));
        return ok && r.length >= 32 && abi.decode(r, (address)) == me;
    }

    // ───────────── market parameters (§12.2) ─────────────

    function _equityParams(address token, bytes32 assetId, bool spy, uint256 supplyCap, uint256 borrowCap)
        internal
        view
        returns (MarketParams memory)
    {
        return MarketParams({
            loanToken: o.loan,
            collateralToken: token,
            assetId: assetId,
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

    function _navParams(address token, bytes32 assetId, uint256 supplyCap, uint256 borrowCap)
        internal
        view
        returns (MarketParams memory)
    {
        return MarketParams({
            loanToken: o.loan,
            collateralToken: token,
            assetId: assetId,
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

    // ───────────── helpers, book ─────────────

    function _dec(address token) internal view returns (uint256) {
        (, bytes memory r) = token.staticcall(abi.encodeWithSignature("decimals()"));
        return abi.decode(r, (uint8));
    }

    function _sorted(address[] memory a) internal pure returns (address[] memory) {
        for (uint256 i; i < a.length; ++i) {
            for (uint256 j = i + 1; j < a.length; ++j) {
                if (a[j] < a[i]) (a[i], a[j]) = (a[j], a[i]);
            }
        }
        return a;
    }

    function _writeBook(string memory path, uint256 startBlock) internal {
        string memory s = "shared";
        vm.serializeAddress(s, "timelock", address(o.timelock));
        vm.serializeAddress(s, "guardian", address(o.guardian));
        vm.serializeAddress(s, "calendar", address(o.calendar));
        vm.serializeAddress(s, "clock", address(o.clock));
        vm.serializeAddress(s, "oracle", address(o.oracle));
        vm.serializeAddress(s, "sequencerHealth", address(o.seq));
        vm.serializeAddress(s, "sigmaOracle", address(o.sigmaOracle));
        vm.serializeAddress(s, "faucet", address(o.faucet));
        vm.serializeAddress(s, "listingEngine", address(o.listing));
        if (nav) {
            vm.serializeAddress(s, "feedNav", address(o.feedNav));
            vm.serializeAddress(s, "registry", address(o.registry));
        } else {
            vm.serializeAddress(s, "feedA", address(o.feedA));
            vm.serializeAddress(s, "feedB", address(o.feedB));
        }
        string memory sharedJson = vm.serializeAddress(s, "riskEngine", address(o.router));

        string memory k = "stack";
        vm.serializeAddress(k, "market", address(o.market));
        vm.serializeAddress(k, "vault", address(o.vault));
        vm.serializeAddress(k, "pool", address(o.pool));
        vm.serializeAddress(k, "reserve", address(o.reserve));
        vm.serializeAddress(k, "treasury", address(o.treasury));
        vm.serializeAddress(k, "tips", address(o.tips));
        if (nav) {
            vm.serializeAddress(k, "settlement", address(o.settlement));
            vm.serializeAddress(k, "solverAuction", address(o.solver));
        } else {
            vm.serializeAddress(k, "auctionHouse", address(o.house));
        }
        string memory mk = "markets";
        string memory marketsJson;
        string memory ak = "assetIds";
        string memory assetsJson;
        string memory tk = "tokens";
        for (uint256 i; i < o.tickers.length; ++i) {
            marketsJson = vm.serializeBytes32(mk, o.tickers[i], o.marketIds[i]);
            assetsJson = vm.serializeBytes32(ak, o.tickers[i], o.assetIds[i]);
            vm.serializeAddress(tk, string.concat("t", o.tickers[i]), o.tokens[i]);
        }
        string memory stackJson = vm.serializeString(k, "markets", marketsJson);
        string memory tokensJson = vm.serializeAddress(tk, "loan", o.loan);

        string memory sk = "safes";
        vm.serializeAddress(sk, "gov", o.gov);
        vm.serializeAddress(sk, "guardian", o.guardianSafe);
        string memory safesJson = vm.serializeAddress(sk, "ops", o.ops);

        string memory r = "book";
        vm.serializeUint(r, "chainId", block.chainid);
        vm.serializeUint(r, "startBlock", startBlock);
        vm.serializeString(r, "release", vm.envOr("RELEASE", string("v0.1.0-testnet")));
        vm.serializeString(r, "stack", stack);
        vm.serializeBool(r, "finalized", false);
        vm.serializeAddress(r, "deployer", me);
        vm.serializeString(r, "safes", safesJson);
        vm.serializeString(r, "shared", sharedJson);
        vm.serializeString(r, "assetIds", assetsJson);
        vm.serializeString(r, "tokens", tokensJson);
        string memory json = vm.serializeString(r, nav ? "nav" : "equity", stackJson);
        vm.writeJson(json, path);
    }
}
