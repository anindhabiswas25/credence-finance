// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    MarketParams,
    MarketKind,
    RateParams,
    MarketWiring,
    RiskParams,
    ClockState,
    ClosureType,
    Session,
    KeeperJob
} from "../../src/libraries/Types.sol";
import {UnderwriterPool} from "../../src/pool/UnderwriterPool.sol";
import {CalendarStore} from "../../src/clock/CalendarStore.sol";
import {CredenceMarket} from "../../src/core/CredenceMarket.sol";
import {SeniorVault} from "../../src/core/SeniorVault.sol";
import {KeeperTips} from "../../src/core/KeeperTips.sol";
import {Treasury} from "../../src/core/Treasury.sol";
import {ProtocolReserve} from "../../src/core/ProtocolReserve.sol";
import {CredenceGuardian} from "../../src/governance/CredenceGuardian.sol";
import {ComplianceRegistry} from "../../src/testnet/ComplianceRegistry.sol";
import {CredenceTreasuryFund} from "../../src/testnet/CredenceTreasuryFund.sol";
import {SettlementAdapter} from "../../src/settlement/SettlementAdapter.sol";
import {SolverAuction} from "../../src/settlement/SolverAuction.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRiskEngine} from "../mocks/MockRiskEngine.sol";
import {MockMarketClock} from "../mocks/MockMarketClock.sol";
import {MockMarketOracle} from "../mocks/MockMarketOracle.sol";

/// @dev The NAV lending stack (S4): the real market, vault, UnderwriterPool (USBANK), SettlementAdapter and
///      SolverAuction around mocked clock, oracle and engine, with the real testnet fund tTBILL (allowlisted ERC-20,
///      ERC-7540-style redemption) and its compliance registry. §12.2 NAV parameters: max LTV 90 %, LT 93 %, λ 1 %.
///      The USBANK calendar has weekday sessions (EDT: open 09:00, close 17:00) from the Monday before now.
abstract contract NavFixture is Test {
    address internal timelock = makeAddr("timelock");
    address internal safe = makeAddr("guardianSafe");
    address internal allocator = makeAddr("allocator");
    address internal keeper = makeAddr("keeper");
    address internal issuer = makeAddr("issuer");
    address internal issuerReserve = makeAddr("issuerReserve");
    address internal solverA = makeAddr("solverA");
    address internal solverB = makeAddr("solverB");

    bytes32 internal constant TBILL = keccak256("TBILL:USBANK");
    bytes32 internal constant VENUE = bytes32("USBANK");
    uint256 internal constant NAV0 = 100e18; // $100 per share
    uint256 internal constant TIP = 2e6;

    MockERC20 internal usdc;
    ComplianceRegistry internal registry;
    CredenceTreasuryFund internal fund;
    MockMarketClock internal clk;
    MockMarketOracle internal orc;
    MockRiskEngine internal engine;
    KeeperTips internal tips;
    Treasury internal treasury;
    ProtocolReserve internal reserve;
    CredenceGuardian internal guardianC;
    CredenceMarket internal market;
    SeniorVault internal vault;
    UnderwriterPool internal up;
    CalendarStore internal cal;
    SettlementAdapter internal adapter;
    SolverAuction internal solver;
    uint40 internal calMonday;
    bytes32 internal idTBILL;

    function setUpNav() internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        registry = new ComplianceRegistry(address(this));
        fund = new CredenceTreasuryFund(
            "Credence Test Treasury Fund",
            "tTBILL",
            issuer,
            address(registry),
            address(usdc),
            issuerReserve,
            NAV0
        );
        clk = new MockMarketClock();
        orc = new MockMarketOracle();
        engine = new MockRiskEngine(timelock, timelock);
        vm.prank(timelock);
        engine.setParams(RiskParams(0.001e18, 0.03e18, 1e18, 0.15e18, 4e18, 0.975e18, 0.5e18, 0.5e6, 256));
        _calendar();
        up = new UnderwriterPool(
            timelock, IERC20(address(usdc)), VENUE, "Credence Underwriter USDC (funds)", "cfUP-NAV"
        );
        tips = new KeeperTips(timelock, address(usdc));
        treasury = new Treasury(timelock, address(usdc), address(tips));
        reserve = new ProtocolReserve(timelock, address(usdc), address(treasury));
        guardianC = new CredenceGuardian(timelock, safe);
        market = new CredenceMarket(timelock, address(guardianC));
        vault = new SeniorVault(
            IERC20(address(usdc)),
            "Credence Senior USDC (funds)",
            "csUSDC-NAV",
            timelock,
            address(market),
            allocator
        );
        adapter = new SettlementAdapter(timelock);
        solver = new SolverAuction(timelock);

        market.initializeWiring(
            MarketWiring({
                clock: address(clk),
                oracle: address(orc),
                engine: address(engine),
                vault: address(vault),
                pool: address(up),
                auctionHouse: address(0),
                settlement: address(adapter),
                reserve: address(reserve),
                treasury: address(treasury),
                tips: address(tips)
            })
        );
        reserve.initializeWiring(address(market));
        address[] memory payers = new address[](3);
        (payers[0], payers[1], payers[2]) = (address(market), address(up), address(adapter));
        tips.initializeWiring(payers);
        address[] memory venues = new address[](1);
        venues[0] = address(solver);
        vm.startPrank(timelock);
        up.initializeWiring(address(market), address(0), address(adapter), address(clk), address(tips));
        adapter.initializeWiring(address(market), address(up), address(tips), venues);
        solver.initializeWiring(address(adapter), address(usdc));
        solver.setSolver(solverA, true);
        solver.setSolver(solverB, true);
        for (uint8 j; j <= KeeperJob.EPOCH; ++j) {
            tips.setTip(j, TIP);
        }
        vm.stopPrank();
        clk.setSettlement(address(adapter));
        clk.setKind(TBILL, MarketKind.NAV);
        address[] memory ms = new address[](1);
        ms[0] = address(market);
        guardianC.initializeWiring(ms, address(clk));

        // tTBILL moves only between allowlisted holders (§8.12)
        address[6] memory allowed =
            [address(market), address(adapter), address(solver), address(up), solverA, solverB];
        for (uint256 i; i < allowed.length; ++i) {
            registry.setAllowed(allowed[i], true);
        }

        vm.prank(timelock);
        idTBILL = market.createMarket(_navParams());
        bytes32[] memory q = new bytes32[](1);
        q[0] = idTBILL;
        vm.prank(timelock);
        vault.setCap(idTBILL, 5_000_000e6);
        vm.startPrank(allocator);
        vault.setSupplyQueue(q);
        vault.setWithdrawQueue(q);
        vm.stopPrank();

        clk.setState(TBILL, ClockState.REGULAR);
        clk.setNextClose(TBILL, uint40(block.timestamp + 1 days), ClosureType.OVERNIGHT, 1);
        orc.setPrice(TBILL, NAV0);
        usdc.mint(address(tips), 10_000e6);
        usdc.mint(issuerReserve, 10_000_000e6);
        vm.prank(issuerReserve);
        usdc.approve(address(fund), type(uint256).max);
    }

    function _navParams() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(usdc),
            collateralToken: address(fund),
            assetId: TBILL,
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

    /// @dev Weekday USBANK sessions from the Monday before now: extOpen 08:00, open 09:00, close 17:00, extClose 18:00
    ///      ET (UTC − 4 h); OVERNIGHT after Mon–Thu, WEEKEND after Friday. Session index = week × 5 + weekday.
    function _calendar() internal {
        uint256 dayIdx = block.timestamp / 1 days;
        calMonday = uint40((dayIdx - (dayIdx + 3) % 7) * 1 days);
        uint256 n = 8 * 5;
        Session[] memory ss = new Session[](n);
        for (uint256 i; i < n; ++i) {
            uint40 d0 = calMonday + uint40((i / 5) * 7 days + (i % 5) * 1 days);
            ss[i] = Session({
                extOpen: d0 + 12 hours,
                open: d0 + 13 hours,
                close: d0 + 21 hours,
                extClose: d0 + 22 hours,
                closureTypeAfter: i % 5 == 4 ? ClosureType.WEEKEND : ClosureType.OVERNIGHT
            });
        }
        cal = new CalendarStore(timelock);
        vm.prank(timelock);
        cal.appendSessions(VENUE, ss);
        clk.setCalendar(address(cal));
    }

    /// @dev 10:00 ET on weekday `d` of week `w` (inside the session, before any Bell window).
    function _morning(uint256 w, uint256 d) internal view returns (uint40) {
        return calMonday + uint40(w * 7 days + d * 1 days) + 14 hours;
    }

    // ───────────── actors ─────────────

    function _seed(uint256 senior, uint256 junior) internal {
        usdc.mint(allocator, senior);
        vm.startPrank(allocator);
        usdc.approve(address(vault), senior);
        vault.deposit(senior, allocator);
        vm.stopPrank();
        usdc.mint(address(this), junior);
        usdc.approve(address(up), junior);
        up.deposit(junior, address(this));
    }

    /// @dev An allowlisted borrower with `shares` tTBILL posted and `debt` borrowed.
    function _borrower(string memory name, uint256 shares, uint256 debt) internal returns (address b) {
        b = makeAddr(name);
        registry.setAllowed(b, true);
        vm.prank(issuer);
        fund.mint(b, shares);
        vm.startPrank(b);
        fund.approve(address(market), shares);
        market.addCollateral(idTBILL, b, shares);
        market.borrow(idTBILL, debt, b);
        vm.stopPrank();
    }

    function _fundSolver(address s, uint256 amt) internal {
        usdc.mint(s, amt);
        vm.prank(s);
        usdc.approve(address(solver), type(uint256).max);
    }

    function _one(address b) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = b;
    }
}
