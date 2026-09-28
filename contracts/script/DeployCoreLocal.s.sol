// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarketParams, MarketKind, RateParams, MarketWiring, RiskParams} from "../src/libraries/Types.sol";
import {IRiskEngine} from "../src/interfaces/IRiskEngine.sol";
import {CredenceMarket} from "../src/core/CredenceMarket.sol";
import {SeniorVault} from "../src/core/SeniorVault.sol";
import {KeeperTips} from "../src/core/KeeperTips.sol";
import {Treasury} from "../src/core/Treasury.sol";
import {ProtocolReserve} from "../src/core/ProtocolReserve.sol";
import {SigmaOracle} from "../src/oracle/SigmaOracle.sol";
import {CredenceGuardian} from "../src/governance/CredenceGuardian.sol";
import {RiskEngineRouter} from "../src/risk/RiskEngineRouter.sol";
import {MockRiskEngine} from "../test/mocks/MockRiskEngine.sol";
import {MockAuctionHouse} from "../test/mocks/MockAuctionHouse.sol";
import {UnderwriterPool} from "../src/pool/UnderwriterPool.sol";
import {AuctionHouse} from "../src/auction/AuctionHouse.sol";
import {DeployClockLocal, MockUSDC} from "./DeployClockLocal.s.sol";
import {LocalBook} from "./utils/LocalBook.sol";

/// @title Local (anvil / nitro-devnode) deployment of the whole S2 protocol: clock + price stack, test assets,
///        Risk Engine, SigmaOracle, guardian, and two lending stacks (equity: NVDA AAPL TSLA COIN MSFT SPY; NAV: TBILL)
///        with seeded Senior Vaults. Writes the one local address book (ADR-0105).
/// @notice LOCAL ONLY (refuses 421614 / 42161). The deployer acts as timelock, guardian Safe, allocator and issuer.
///         S3: each stack has the real UnderwriterPool (equity on XNYS, NAV on USBANK) and the equity stack the real
///         AuctionHouse; the NAV stack's settlement adapter is still a local stand-in (the test mock) until S4.
/// @dev Env (in addition to DeployClockLocal's):
///      RISK_ENGINE     engine address (default: `.shared.riskEngine` of the existing book if it has code; otherwise a
///                      Solidity stand-in engine is deployed, e.g. on anvil)
///      SIGMA_SIGNERS   σ committee (default RELAYER_A_SIGNERS), SIGMA_THRESHOLD (default 2)
///      SEED_EQUITY / SEED_NAV   USDC deposited into each vault (default 1,000,000 / 1,000,000)
///      SEED_POOL       USDC deposited into each UnderwriterPool (default 250,000)
///      MIN_BID         the auction house's minimum bid notional, loan units (default 100 USDC, testnet §8.7.1)
contract DeployCoreLocal is DeployClockLocal {
    struct Core {
        CredenceGuardian guardian;
        SigmaOracle sigmaOracle;
        address engine;
        bool localEngine;
        address listingEngine; // what markets are listed against (a Solidity stand-in when the engine is Stylus)
    }

    struct StackOut {
        CredenceMarket market;
        SeniorVault vault;
        KeeperTips tips;
        Treasury treasury;
        ProtocolReserve reserve;
        UnderwriterPool pool;
        AuctionHouse auctionHouse; // equity stack
        MockAuctionHouse settlement; // NAV stack stand-in (S4)
        string[] tickers;
        bytes32[] marketIds;
    }

    /// @dev Everything one run deploys, behind one pointer (keeps run() within the stack limit).
    struct Deployed {
        Core k;
        ClockStack c;
        StackOut eq;
        StackOut nav;
    }

    function run() external override {
        _requireLocal();
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory path = vm.envOr("OUT", LocalBook.defaultPath());
        Deployed memory d;
        address engine = _existingEngine(path);
        vm.startBroadcast(pk);
        _deployAll(vm.addr(pk), engine, d);
        vm.stopBroadcast();
        _writeBook(path, vm.addr(pk), d.k, d.c, d.eq, d.nav);
        console2.log("address book:", path);
        console2.log("equity market:", address(d.eq.market));
        console2.log("nav market:", address(d.nav.market));
        if (d.k.localEngine) console2.log("risk engine: Solidity stand-in (no Stylus engine in the book)");
    }

    function _deployAll(address me, address engine, Deployed memory d) internal {
        d.k.guardian = new CredenceGuardian(me, me);
        d.c = _deployClockStack(me, address(d.k.guardian));
        (d.k.sigmaOracle, d.k.engine, d.k.localEngine, d.k.listingEngine) = _risk(me, engine);
        d.eq = _stack(me, d.k, d.c, MarketKind.EQUITY, "Credence Senior USDC (equity)", "csUSDC-EQ");
        d.nav = _stack(me, d.k, d.c, MarketKind.NAV, "Credence Senior USDC (funds)", "csUSDC-NAV");
        _finish(
            d.k.guardian,
            d.c,
            address(d.eq.market),
            address(d.nav.market),
            address(d.eq.auctionHouse),
            address(d.nav.settlement)
        );
    }

    function _writeBook(
        string memory path,
        address me,
        Core memory k,
        ClockStack memory c,
        StackOut memory eq,
        StackOut memory nav
    ) internal {
        LocalBook.Book memory b = _book(c, me, address(k.guardian));
        if (!k.localEngine) LocalBook.carryEngine(b, path);
        b.shared.riskEngine = k.engine;
        b.shared.sigmaOracle = address(k.sigmaOracle);
        b.equity = _bookStack(eq);
        b.nav = _bookStack(nav);
        LocalBook.write(b, path);
    }

    function _defaultTickers() internal pure override returns (string[] memory t) {
        t = new string[](6);
        (t[0], t[1], t[2], t[3], t[4], t[5]) = ("NVDA", "AAPL", "TSLA", "COIN", "MSFT", "SPY");
    }

    // ───────────── risk engine + σ oracle ─────────────

    function _existingEngine(string memory path) internal view returns (address e) {
        e = vm.envOr("RISK_ENGINE", address(0));
        if (e != address(0) || !vm.exists(path)) return e;
        string memory j = vm.readFile(path);
        if (vm.keyExistsJson(j, ".shared.riskEngine")) e = vm.parseJsonAddress(j, ".shared.riskEngine");
        if (e.code.length == 0) e = address(0);
    }

    /// @dev forge cannot execute Stylus WASM, so nothing here may call into a Stylus engine: markets are listed
    ///      against a Solidity stand-in with the §12.2 params (createMarket reads κ) and then pointed at the real
    ///      engine with `setEngine` (a plain setter). The Stylus engine's own params come from `make risk-load-set`.
    function _risk(address me, address engine)
        internal
        returns (SigmaOracle so, address e, bool local, address listing)
    {
        address[] memory signers =
            _sorted(vm.envOr("SIGMA_SIGNERS", ",", vm.envAddress("RELAYER_A_SIGNERS", ",")));
        so = new SigmaOracle(me, signers, uint8(vm.envOr("SIGMA_THRESHOLD", uint256(2))));
        e = engine;
        if (e == address(0)) {
            e = address(new MockRiskEngine(me, address(so)));
            local = true;
            listing = e;
        } else {
            listing = address(new MockRiskEngine(me, me));
        }
        so.initializeWiring(e);
        MockRiskEngine(listing)
            .setParams(RiskParams(0.001e18, 0.03e18, 1e18, 0.15e18, 4e18, 0.975e18, 0.5e18, 0.5e6, 256));
        // the Stylus engine's router takes its σ writer from the timelock (the deployer on local chains)
        if (!local && IRiskEngine(e).sigmaOracle() != address(so)) {
            try RiskEngineRouter(e).setSigmaOracle(address(so)) {}
            catch {
                console2.log("note: could not point the engine's sigmaOracle at this SigmaOracle");
            }
        }
    }

    // ───────────── lending stacks ─────────────

    function _stack(
        address me,
        Core memory k,
        ClockStack memory c,
        MarketKind kind,
        string memory name,
        string memory symbol
    ) internal returns (StackOut memory s) {
        bool nav = kind == MarketKind.NAV;
        _stackContracts(me, k, c, nav, name, symbol, s);
        _stackMarkets(k, c, nav, s);
        _seedVault(me, address(c.usdc), nav, s);
        _seedPool(me, address(c.usdc), s.pool);
    }

    function _stackContracts(
        address me,
        Core memory k,
        ClockStack memory c,
        bool nav,
        string memory name,
        string memory symbol,
        StackOut memory s
    ) internal {
        address usdc = address(c.usdc);
        s.tips = new KeeperTips(me, usdc);
        s.treasury = new Treasury(me, usdc, address(s.tips));
        s.reserve = new ProtocolReserve(me, usdc, address(s.treasury));
        s.market = new CredenceMarket(me, address(k.guardian));
        s.vault = new SeniorVault(IERC20(usdc), name, symbol, me, address(s.market), me);
        _riskContracts(me, usdc, nav, s);
        s.market
            .initializeWiring(
                MarketWiring({
                    clock: address(c.clock),
                    oracle: address(c.oracle),
                    engine: k.listingEngine,
                    vault: address(s.vault),
                    pool: address(s.pool),
                    auctionHouse: address(s.auctionHouse),
                    settlement: address(s.settlement),
                    reserve: address(s.reserve),
                    treasury: address(s.treasury),
                    tips: address(s.tips)
                })
            );
        _wireRisk(c, s, nav);
        s.reserve.initializeWiring(address(s.market));
        address[] memory payers = new address[](nav ? 2 : 3);
        (payers[0], payers[1]) = (address(s.market), address(s.pool));
        if (!nav) payers[2] = address(s.auctionHouse);
        s.tips.initializeWiring(payers);
        s.market.setReserveFeeShare(3000); // 30% of the protocol fee (§12.2)
    }

    function _stackMarkets(Core memory k, ClockStack memory c, bool nav, StackOut memory s) internal {
        address usdc = address(c.usdc);
        if (nav) {
            // tTBILL moves only between allowlisted holders (§8.12): the market and the settlement stand-in hold it
            c.registry.setAllowed(address(s.market), true);
            c.registry.setAllowed(address(s.settlement), true);
            c.registry.setAllowed(address(s.pool), true); // backstop inventory (S4 fallback)
            s.tickers = new string[](1);
            s.marketIds = new bytes32[](1);
            s.tickers[0] = "TBILL";
            s.marketIds[0] = s.market.createMarket(_navParams(usdc, address(c.fund), c.tbill));
        } else {
            s.tickers = c.tickers;
            s.marketIds = new bytes32[](c.tickers.length);
            for (uint256 i; i < c.tickers.length; ++i) {
                bool spy = keccak256(bytes(c.tickers[i])) == keccak256("SPY");
                s.marketIds[i] =
                    s.market.createMarket(_equityParams(usdc, address(c.stocks[i]), c.assetIds[i], spy));
            }
        }
        if (k.listingEngine != k.engine) s.market.setEngine(k.engine);
        for (uint256 i; i < s.marketIds.length; ++i) {
            s.vault.setCap(s.marketIds[i], nav ? 5_000_000e6 : 2_000_000e6);
        }
        s.vault.setWithdrawQueue(s.marketIds);
    }

    /// @dev The seed is deposited with an empty supply queue (it stays idle) and then allocated evenly, so every
    ///      market has liquidity (a queue deposit would fill the first market's cap and leave the others empty).
    function _seedVault(address me, address usdc, bool nav, StackOut memory s) internal {
        uint256 seed = vm.envOr(nav ? "SEED_NAV" : "SEED_EQUITY", uint256(1_000_000e6));
        MockUSDC(usdc).mint(me, seed);
        MockUSDC(usdc).approve(address(s.vault), seed);
        if (seed != 0) {
            s.vault.deposit(seed, me);
            uint256 each = s.vault.idle() / s.marketIds.length;
            for (uint256 i; i < s.marketIds.length && each != 0; ++i) {
                s.vault.allocate(s.marketIds[i], each);
            }
        }
        s.vault.setSupplyQueue(s.marketIds);
        MockUSDC(usdc).mint(address(s.tips), 1_000e6); // keeper tip budget
    }

    function _riskContracts(address me, address usdc, bool nav, StackOut memory s) internal {
        if (nav) {
            s.pool = new UnderwriterPool(
                me, IERC20(usdc), USBANK, "Credence Underwriter USDC (funds)", "cfUP-NAV"
            );
            s.settlement = new MockAuctionHouse();
        } else {
            s.pool =
                new UnderwriterPool(me, IERC20(usdc), XNYS, "Credence Underwriter USDC (equity)", "cfUP-EQ");
            s.auctionHouse = new AuctionHouse(me);
        }
    }

    function _wireRisk(ClockStack memory c, StackOut memory s, bool nav) internal {
        address clock = address(c.clock);
        address market = address(s.market);
        address tips = address(s.tips);
        s.pool.initializeWiring(market, address(s.auctionHouse), address(s.settlement), clock, tips);
        if (nav) {
            s.settlement.setMarket(market);
            return;
        }
        uint128 minBid = uint128(vm.envOr("MIN_BID", uint256(100e6)));
        s.auctionHouse.initializeWiring(market, address(s.pool), clock, tips, XNYS, minBid);
    }

    function _finish(
        CredenceGuardian guardian,
        ClockStack memory c,
        address eqMarket,
        address navMarket,
        address eqHouse,
        address navSettlement
    ) internal {
        address[] memory markets = new address[](2);
        (markets[0], markets[1]) = (eqMarket, navMarket);
        guardian.initializeWiring(markets, address(c.clock));
        // markReopenComplete comes from the equity auction house and the NAV settlement adapter
        c.clock.initializeWiring(address(c.oracle), eqHouse, navSettlement);
    }

    /// @dev First-loss capital for each pool (minted at once outside a Bell window, queued inside one).
    function _seedPool(address me, address usdc, UnderwriterPool pool) internal {
        uint256 seed = vm.envOr("SEED_POOL", uint256(250_000e6));
        if (seed == 0) return;
        MockUSDC(usdc).mint(me, seed);
        MockUSDC(usdc).approve(address(pool), seed);
        pool.deposit(seed, me);
    }

    /// @dev §12.2 equity parameters: max LTV 75% / LT 80% (SPY 80% / 85%), λ 3%, κ_pre = λ_pre = 1%,
    ///      IRM 2% / 6% / 80% / 90%, caps $2M / $1.4M.
    function _equityParams(address usdc, address token, bytes32 assetId, bool spy)
        internal
        pure
        returns (MarketParams memory)
    {
        return MarketParams({
            loanToken: usdc,
            collateralToken: token,
            assetId: assetId,
            kind: MarketKind.EQUITY,
            maxLtv: spy ? 0.8e18 : 0.75e18,
            lt: spy ? 0.85e18 : 0.8e18,
            penalty: 0.03e18,
            precloseKappa: 0.01e18,
            precloseLambda: 0.01e18,
            supplyCap: 2_000_000e6,
            borrowCap: 1_400_000e6,
            rate: RateParams({r0: 0.02e18, s1: 0.06e18, s2: 0.8e18, uKink: 0.9e18})
        });
    }

    /// @dev §12.2 NAV parameters: 90% / 93%, λ 1%, IRM 1% / 4% / 60% / 92%, caps $5M / $4.5M.
    function _navParams(address usdc, address token, bytes32 assetId)
        internal
        pure
        returns (MarketParams memory)
    {
        return MarketParams({
            loanToken: usdc,
            collateralToken: token,
            assetId: assetId,
            kind: MarketKind.NAV,
            maxLtv: 0.9e18,
            lt: 0.93e18,
            penalty: 0.01e18,
            precloseKappa: 0.01e18,
            precloseLambda: 0.01e18,
            supplyCap: 5_000_000e6,
            borrowCap: 4_500_000e6,
            rate: RateParams({r0: 0.01e18, s1: 0.04e18, s2: 0.6e18, uKink: 0.92e18})
        });
    }

    function _bookStack(StackOut memory s) internal pure returns (LocalBook.Stack memory x) {
        x.market = address(s.market);
        x.vault = address(s.vault);
        x.reserve = address(s.reserve);
        x.treasury = address(s.treasury);
        x.tips = address(s.tips);
        x.pool = address(s.pool);
        x.settlement = address(s.settlement);
        x.auctionHouse = address(s.auctionHouse);
        x.tickers = s.tickers;
        x.marketIds = s.marketIds;
    }
}
