// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    MarketParams, MarketKind, RateParams, MarketWiring, RiskParams, ClockState, ClosureType
} from "../../src/libraries/Types.sol";
import {CredenceMarket} from "../../src/core/CredenceMarket.sol";
import {SeniorVault} from "../../src/core/SeniorVault.sol";
import {KeeperTips} from "../../src/core/KeeperTips.sol";
import {Treasury} from "../../src/core/Treasury.sol";
import {ProtocolReserve} from "../../src/core/ProtocolReserve.sol";
import {CredenceGuardian} from "../../src/governance/CredenceGuardian.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRiskEngine} from "../mocks/MockRiskEngine.sol";
import {MockUnderwriterPool} from "../mocks/MockUnderwriterPool.sol";
import {MockAuctionHouse} from "../mocks/MockAuctionHouse.sol";
import {MockMarketClock} from "../mocks/MockMarketClock.sol";
import {MockMarketOracle} from "../mocks/MockMarketOracle.sol";

/// @dev The lending core (market, vault, tips, treasury, reserve, guardian) around mocked clock, oracle, engine,
///      pool and auction house. One NVDA / AAPL / TSLA market each, §12.2 equity parameters.
abstract contract CoreFixture is Test {
    address internal timelock = makeAddr("timelock");
    address internal safe = makeAddr("guardianSafe");
    address internal allocator = makeAddr("allocator");
    address internal keeper = makeAddr("keeper");

    bytes32 internal constant NVDA = keccak256("NVDA:XNAS");
    bytes32 internal constant AAPL = keccak256("AAPL:XNAS");
    bytes32 internal constant TSLA = keccak256("TSLA:XNAS");

    MockERC20 internal usdc;
    MockERC20 internal tNVDA;
    MockERC20 internal tAAPL;
    MockERC20 internal tTSLA;
    MockMarketClock internal clk;
    MockMarketOracle internal orc;
    MockRiskEngine internal engine;
    MockUnderwriterPool internal pool;
    MockAuctionHouse internal ah;
    KeeperTips internal tips;
    Treasury internal treasury;
    ProtocolReserve internal reserve;
    CredenceGuardian internal guardianC;
    CredenceMarket internal market;
    SeniorVault internal vault;

    bytes32 internal idNVDA;
    bytes32 internal idAAPL;
    bytes32 internal idTSLA;

    function setUpCore() internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        tNVDA = new MockERC20("Credence Test NVIDIA", "tNVDA", 18);
        tAAPL = new MockERC20("Credence Test Apple", "tAAPL", 18);
        tTSLA = new MockERC20("Credence Test Tesla", "tTSLA", 18);
        clk = new MockMarketClock();
        orc = new MockMarketOracle();
        engine = new MockRiskEngine(timelock, timelock);
        vm.prank(timelock);
        engine.setParams(RiskParams(0.001e18, 0.03e18, 1e18, 0.15e18, 4e18, 0.975e18, 0.5e18, 0.5e6, 256));
        pool = new MockUnderwriterPool(IERC20(address(usdc)));
        ah = new MockAuctionHouse();
        tips = new KeeperTips(timelock, address(usdc));
        treasury = new Treasury(timelock, address(usdc), address(tips));
        reserve = new ProtocolReserve(timelock, address(usdc), address(treasury));
        guardianC = new CredenceGuardian(timelock, safe);
        market = new CredenceMarket(timelock, address(guardianC));
        vault = new SeniorVault(IERC20(address(usdc)), "Credence Senior USDC", "csUSDC", timelock, address(market), allocator);

        market.initializeWiring(
            MarketWiring({
                clock: address(clk),
                oracle: address(orc),
                engine: address(engine),
                vault: address(vault),
                pool: address(pool),
                auctionHouse: address(ah),
                settlement: address(0),
                reserve: address(reserve),
                treasury: address(treasury),
                tips: address(tips)
            })
        );
        pool.setMarket(address(market));
        ah.setMarket(address(market));
        reserve.initializeWiring(address(market));
        address[] memory payers = new address[](1);
        payers[0] = address(market);
        tips.initializeWiring(payers);
        address[] memory ms = new address[](1);
        ms[0] = address(market);
        guardianC.initializeWiring(ms, address(clk));

        idNVDA = _list(address(tNVDA), NVDA);
        idAAPL = _list(address(tAAPL), AAPL);
        idTSLA = _list(address(tTSLA), TSLA);
        bytes32[] memory q = new bytes32[](3);
        (q[0], q[1], q[2]) = (idAAPL, idTSLA, idNVDA);
        vm.startPrank(timelock);
        for (uint256 i; i < 3; ++i) {
            vault.setCap(q[i], 2_000_000e6);
        }
        vm.stopPrank();
        vm.startPrank(allocator);
        vault.setSupplyQueue(q);
        vault.setWithdrawQueue(q);
        vm.stopPrank();

        for (uint256 i; i < 3; ++i) {
            bytes32 a = [NVDA, AAPL, TSLA][i];
            clk.setState(a, ClockState.REGULAR);
            clk.setNextClose(a, uint40(block.timestamp + 1 days), ClosureType.OVERNIGHT, 1);
        }
        orc.setPrice(NVDA, 180e18);
        orc.setPrice(AAPL, 200e18);
        orc.setPrice(TSLA, 250e18);
        usdc.mint(address(tips), 1_000e6);
    }

    function _rate() internal pure virtual returns (RateParams memory) {
        return RateParams({r0: 0.02e18, s1: 0.06e18, s2: 0.8e18, uKink: 0.9e18});
    }

    function _list(address token, bytes32 asset) internal returns (bytes32 id) {
        MarketParams memory p = MarketParams({
            loanToken: address(usdc),
            collateralToken: token,
            assetId: asset,
            kind: MarketKind.EQUITY,
            maxLtv: 0.75e18,
            lt: 0.8e18,
            penalty: 0.03e18,
            precloseKappa: 0.01e18,
            precloseLambda: 0.01e18,
            supplyCap: 2_000_000e6,
            borrowCap: 1_400_000e6,
            rate: _rate()
        });
        vm.prank(timelock);
        id = market.createMarket(p);
    }

    // ───────────── actors ─────────────

    function _deposit(address lender, uint256 assets) internal returns (uint256 shares) {
        usdc.mint(lender, assets);
        vm.startPrank(lender);
        usdc.approve(address(vault), assets);
        shares = vault.deposit(assets, lender);
        vm.stopPrank();
    }

    function _collateral(address b, bytes32 id, MockERC20 token, uint256 q) internal {
        token.mint(b, q);
        vm.startPrank(b);
        token.approve(address(market), q);
        market.addCollateral(id, b, q);
        vm.stopPrank();
    }

    function _borrow(address b, bytes32 id, uint256 assets) internal {
        vm.prank(b);
        market.borrow(id, assets, b);
    }
}
