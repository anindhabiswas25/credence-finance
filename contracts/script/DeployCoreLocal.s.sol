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
import {MockRiskEngine} from "../test/mocks/MockRiskEngine.sol";
import {MockUnderwriterPool} from "../test/mocks/MockUnderwriterPool.sol";
import {MockAuctionHouse} from "../test/mocks/MockAuctionHouse.sol";
import {DeployClockLocal, MockUSDC} from "./DeployClockLocal.s.sol";
import {LocalBook} from "./utils/LocalBook.sol";

/// @title Local (anvil / nitro-devnode) deployment of the whole S2 protocol: clock + price stack, test assets,
///        Risk Engine, SigmaOracle, guardian, and two lending stacks (equity: NVDA AAPL TSLA COIN MSFT SPY; NAV: TBILL)
///        with seeded Senior Vaults. Writes the one local address book (ADR-0105).
/// @notice LOCAL ONLY (refuses 421614 / 42161). The deployer acts as timelock, guardian Safe, allocator and issuer.
///         The UnderwriterPool and AuctionHouse are S3: each stack is wired to local stand-ins (the test mocks), which
///         quote cover at `COVER_PREMIUM` and let a script fix / clear lots.
/// @dev Env (in addition to DeployClockLocal's):
///      RISK_ENGINE     engine address (default: `.shared.riskEngine` of the existing book if it has code; otherwise a
///                      Solidity stand-in engine is deployed, e.g. on anvil)
///      SIGMA_SIGNERS   σ committee (default RELAYER_A_SIGNERS), SIGMA_THRESHOLD (default 2)
///      SEED_EQUITY / SEED_NAV   USDC deposited into each vault (default 1,000,000 / 1,000,000)
///      COVER_PREMIUM   premium the stand-in pools quote, loan units (default 0)
contract DeployCoreLocal is DeployClockLocal {
    struct Core {
        CredenceGuardian guardian;
        SigmaOracle sigmaOracle;
        address engine;
        bool localEngine;
    }

    struct StackOut {
        CredenceMarket market;
        SeniorVault vault;
        KeeperTips tips;
        Treasury treasury;
        ProtocolReserve reserve;
        MockUnderwriterPool pool;
        MockAuctionHouse auctionHouse;
        string[] tickers;
        bytes32[] marketIds;
    }

    function run() external override {
        _requireLocal();
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory path = vm.envOr("OUT", LocalBook.defaultPath());
        address engine = _existingEngine(path);

        vm.startBroadcast(pk);
        Core memory k;
        k.guardian = new CredenceGuardian(me, me);
        ClockStack memory c = _deployClockStack(me, address(k.guardian));
        (k.sigmaOracle, k.engine, k.localEngine) = _risk(me, engine);
        StackOut memory eq = _stack(me, k, c, MarketKind.EQUITY, "Credence Senior USDC (equity)", "csUSDC-EQ");
        StackOut memory nav = _stack(me, k, c, MarketKind.NAV, "Credence Senior USDC (funds)", "csUSDC-NAV");
        address[] memory markets = new address[](2);
        (markets[0], markets[1]) = (address(eq.market), address(nav.market));
        k.guardian.initializeWiring(markets, address(c.clock));
        vm.stopBroadcast();

        LocalBook.Book memory b = _book(c, me, address(k.guardian));
        if (!k.localEngine) LocalBook.carryEngine(b, path);
        b.shared.riskEngine = k.engine;
        b.shared.sigmaOracle = address(k.sigmaOracle);
        b.equity = _bookStack(eq);
        b.nav = _bookStack(nav);
        LocalBook.write(b, path);
        console2.log("address book:", path);
        console2.log("equity market:", address(eq.market));
        console2.log("nav market:", address(nav.market));
        if (k.localEngine) console2.log("risk engine: Solidity stand-in (no Stylus engine in the book)");
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

    function _risk(address me, address engine) internal returns (SigmaOracle so, address e, bool local) {
        address[] memory signers = _sorted(vm.envOr("SIGMA_SIGNERS", ",", vm.envAddress("RELAYER_A_SIGNERS", ",")));
        so = new SigmaOracle(me, signers, uint8(vm.envOr("SIGMA_THRESHOLD", uint256(2))));
        e = engine;
        if (e == address(0)) {
            e = address(new MockRiskEngine(me, address(so)));
            local = true;
        }
        so.initializeWiring(e);
        // §12.2 launch parameters; the deployer is the engine's timelock on local chains
        try IRiskEngine(e).setParams(RiskParams(0.001e18, 0.03e18, 1e18, 0.15e18, 4e18, 0.975e18, 0.5e18, 0.5e6, 256)) {}
        catch {
            console2.log("engine params not set (the deployer is not the engine's timelock)");
        }
        if (!local && IRiskEngine(e).sigmaOracle() != address(so)) {
            console2.log("note: the engine's sigmaOracle is not this SigmaOracle; redeploy the engine with it");
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
        address usdc = address(c.usdc);
        s.tips = new KeeperTips(me, usdc);
        s.treasury = new Treasury(me, usdc, address(s.tips));
        s.reserve = new ProtocolReserve(me, usdc, address(s.treasury));
        s.market = new CredenceMarket(me, address(k.guardian));
        s.vault = new SeniorVault(IERC20(usdc), name, symbol, me, address(s.market), me);
        s.pool = new MockUnderwriterPool(IERC20(usdc));
        s.auctionHouse = new MockAuctionHouse();
        bool nav = kind == MarketKind.NAV;
        s.market.initializeWiring(
            MarketWiring({
                clock: address(c.clock),
                oracle: address(c.oracle),
                engine: k.engine,
                vault: address(s.vault),
                pool: address(s.pool),
                auctionHouse: nav ? address(0) : address(s.auctionHouse),
                settlement: nav ? address(s.auctionHouse) : address(0),
                reserve: address(s.reserve),
                treasury: address(s.treasury),
                tips: address(s.tips)
            })
        );
        s.pool.setMarket(address(s.market));
        s.pool.setPremium(vm.envOr("COVER_PREMIUM", uint256(0)), 0);
        s.auctionHouse.setMarket(address(s.market));
        s.reserve.initializeWiring(address(s.market));
        address[] memory payers = new address[](1);
        payers[0] = address(s.market);
        s.tips.initializeWiring(payers);
        s.market.setReserveFeeShare(3000); // 30% of the protocol fee (§12.2)

        if (nav) {
            // tTBILL moves only between allowlisted holders (§8.12): the market and the settlement stand-in hold it
            c.registry.setAllowed(address(s.market), true);
            c.registry.setAllowed(address(s.auctionHouse), true);
            s.tickers = new string[](1);
            s.marketIds = new bytes32[](1);
            s.tickers[0] = "TBILL";
            s.marketIds[0] = s.market.createMarket(_navParams(usdc, address(c.fund), c.tbill));
        } else {
            s.tickers = c.tickers;
            s.marketIds = new bytes32[](c.tickers.length);
            for (uint256 i; i < c.tickers.length; ++i) {
                bool spy = keccak256(bytes(c.tickers[i])) == keccak256("SPY");
                s.marketIds[i] = s.market.createMarket(_equityParams(usdc, address(c.stocks[i]), c.assetIds[i], spy));
            }
        }
        for (uint256 i; i < s.marketIds.length; ++i) {
            s.vault.setCap(s.marketIds[i], nav ? 5_000_000e6 : 2_000_000e6);
        }
        s.vault.setSupplyQueue(s.marketIds);
        s.vault.setWithdrawQueue(s.marketIds);

        uint256 seed = vm.envOr(nav ? "SEED_NAV" : "SEED_EQUITY", uint256(1_000_000e6));
        MockUSDC(usdc).mint(me, seed);
        MockUSDC(usdc).approve(address(s.vault), seed);
        if (seed != 0) s.vault.deposit(seed, me);
        MockUSDC(usdc).mint(address(s.tips), 1_000e6); // keeper tip budget
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
    function _navParams(address usdc, address token, bytes32 assetId) internal pure returns (MarketParams memory) {
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
        bool nav = s.tickers.length == 1 && keccak256(bytes(s.tickers[0])) == keccak256("TBILL");
        if (nav) x.settlement = address(s.auctionHouse);
        else x.auctionHouse = address(s.auctionHouse);
        x.tickers = s.tickers;
        x.marketIds = s.marketIds;
    }
}
