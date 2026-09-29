// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    Session,
    ReportKind,
    FeedMarketStatus,
    MarketKind,
    MarketParams,
    MarketWiring,
    RateParams,
    RiskParams,
    ClockState,
    AuctionKind,
    MarketAction,
    Settlement,
    SettlementStatus,
    KeeperJob
} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {ClockFixture} from "../utils/ClockFixture.sol";
import {CalendarStore} from "../../src/clock/CalendarStore.sol";
import {AssetClock} from "../../src/clock/AssetClock.sol";
import {SequencerHealth} from "../../src/oracle/SequencerHealth.sol";
import {CredencePriceFeed} from "../../src/oracle/CredencePriceFeed.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {UnderwriterPool} from "../../src/pool/UnderwriterPool.sol";
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

/// @notice NAV settlement end to end (S4 brief D): the real USBANK calendar (fixture 2026-10-01 → 11-25), AssetClock,
///         OracleAdapter and signed NAV feed, the real tTBILL fund (allowlist, ERC-7540-style redemption), market, vault,
///         UnderwriterPool, SettlementAdapter and SolverAuction. The fund's NAV drifts down 0.45 % per USBANK strike
///         (under the 0.5 % one-step HALT) until two 89.9 %-LTV positions are under water. Ava is sold at the next
///         REOPEN to a solver (T+0); nobody bids for Bo, so the pool advances qty × floor, requests the redemption, and
///         claims it at T+1 with the κ_nav discount. The issuer gate halts the market and leaves repay open.
contract NavSettlementScenarioTest is ClockFixture {
    bytes32 constant FUND = keccak256("TBILL:USBANK");
    uint256 constant DROP_BPS = 45; // per strike

    CredencePriceFeed navFeed;
    MockERC20 usdc;
    ComplianceRegistry registry;
    CredenceTreasuryFund fund;
    MockRiskEngine engine;
    KeeperTips tips;
    Treasury treasury;
    ProtocolReserve reserve;
    CredenceGuardian guardianC;
    CredenceMarket market;
    SeniorVault vault;
    UnderwriterPool up;
    SettlementAdapter adapter;
    SolverAuction venue;
    bytes32 id;

    address allocator = makeAddr("allocator");
    address issuerReserve = makeAddr("issuerReserve");
    address keeper = makeAddr("keeper");
    address solver = makeAddr("solver");
    address ava = makeAddr("ava");
    address bo = makeAddr("bo");
    uint256 nav = 100e18;
    uint256 day; // index of the current session

    function setUp() public {
        _loadCalendarFixture("test/fixtures/USBANK-20261001-fixture.json");
        vm.warp(sessions[0].open + 1 hours); // Thu 2026-10-01 10:00 ET
        calendar = new CalendarStore(timelock);
        vm.prank(timelock);
        calendar.appendSessions(USBANK, sessions);
        seqHealth = new SequencerHealth();
        clock = new AssetClock(timelock, guardian, address(calendar), address(seqHealth));
        seqHealth.setClock(address(clock));
        _makeCommittee();
        navFeed = new CredencePriceFeed(timelock, signers, 2);
        oracle = new OracleAdapter(timelock);
        oracle.setClock(address(clock));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        registry = new ComplianceRegistry(address(this));
        fund = new CredenceTreasuryFund(
            "Credence Test Treasury Fund",
            "tTBILL",
            issuer,
            address(registry),
            address(usdc),
            issuerReserve,
            nav
        );
        engine = new MockRiskEngine(timelock, timelock);
        vm.prank(timelock);
        engine.setParams(RiskParams(0.001e18, 0.03e18, 1e18, 0.15e18, 4e18, 0.975e18, 0.5e18, 0.5e6, 256));
        _deployLending();
        vm.startPrank(timelock);
        oracle.setAssetConfig(
            FUND, address(navFeed), address(0), address(0), address(fund), MarketKind.NAV, 0
        );
        clock.listAsset(FUND, USBANK, MarketKind.NAV);
        id = market.createMarket(_navParams());
        vault.setCap(id, 5_000_000e6);
        vm.stopPrank();
        bytes32[] memory q = new bytes32[](1);
        q[0] = id;
        vm.startPrank(allocator);
        vault.setSupplyQueue(q);
        vault.setWithdrawQueue(q);
        vm.stopPrank();

        _publish(nav, uint40(block.timestamp)); // Wednesday's NAV, published this morning
        assertEq(uint8(clock.poke(FUND)), uint8(ClockState.REGULAR));
        _seed();
        _position(ava, 1_000e18, 89_900e6);
        _position(bo, 1_000e18, 89_900e6);
    }

    function _deployLending() internal {
        tips = new KeeperTips(timelock, address(usdc));
        treasury = new Treasury(timelock, address(usdc), address(tips));
        reserve = new ProtocolReserve(timelock, address(usdc), address(treasury));
        guardianC = new CredenceGuardian(timelock, guardian);
        market = new CredenceMarket(timelock, address(guardianC));
        vault = new SeniorVault(
            IERC20(address(usdc)), "csUSDC-NAV", "csUSDC-NAV", timelock, address(market), allocator
        );
        up = new UnderwriterPool(timelock, IERC20(address(usdc)), USBANK, "cfUP-NAV", "cfUP-NAV");
        adapter = new SettlementAdapter(timelock);
        venue = new SolverAuction(timelock);
        market.initializeWiring(
            MarketWiring({
                clock: address(clock),
                oracle: address(oracle),
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
        clock.initializeWiring(address(oracle), auctionHouse, address(adapter));
        reserve.initializeWiring(address(market));
        address[] memory payers = new address[](3);
        (payers[0], payers[1], payers[2]) = (address(market), address(up), address(adapter));
        tips.initializeWiring(payers);
        address[] memory ms = new address[](1);
        ms[0] = address(market);
        guardianC.initializeWiring(ms, address(clock));
        address[] memory venues = new address[](1);
        venues[0] = address(venue);
        vm.startPrank(timelock);
        up.initializeWiring(address(market), address(0), address(adapter), address(clock), address(tips));
        adapter.initializeWiring(address(market), address(up), address(tips), venues);
        venue.initializeWiring(address(adapter), address(usdc));
        venue.setSolver(solver, true);
        for (uint8 j; j <= KeeperJob.EPOCH; ++j) {
            tips.setTip(j, 1e6);
        }
        vm.stopPrank();
        address[7] memory allowed =
            [address(market), address(adapter), address(venue), address(up), solver, ava, bo];
        for (uint256 i; i < allowed.length; ++i) {
            registry.setAllowed(allowed[i], true);
        }
        usdc.mint(address(tips), 10_000e6);
        usdc.mint(issuerReserve, 10_000_000e6);
        vm.prank(issuerReserve);
        usdc.approve(address(fund), type(uint256).max);
    }

    function _navParams() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(usdc),
            collateralToken: address(fund),
            assetId: FUND,
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

    function _seed() internal {
        usdc.mint(allocator, 1_000_000e6);
        vm.startPrank(allocator);
        usdc.approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6, allocator);
        vm.stopPrank();
        usdc.mint(address(this), 250_000e6);
        usdc.approve(address(up), 250_000e6);
        up.deposit(250_000e6, address(this));
    }

    function _position(address b, uint256 shares, uint256 debt) internal {
        vm.prank(issuer);
        fund.mint(b, shares);
        vm.startPrank(b);
        fund.approve(address(market), shares);
        market.addCollateral(id, b, shares);
        market.borrow(id, debt, b);
        vm.stopPrank();
    }

    /// @dev The issuer strikes the NAV: the signed feed (what the oracle reads) and the fund (what redemptions pay).
    function _publish(uint256 p, uint40 at) internal {
        vm.warp(at);
        uint40 sessionDate = uint40(sessions[day].open / 1 days);
        _submit(navFeed, _report(navFeed, FUND, ReportKind.NAV, p, at, sessionDate, FeedMarketStatus.CLOSED));
        vm.prank(issuer);
        fund.publishNav(p);
    }

    /// @dev Today's strike (−0.45 % at 17:15 ET), then the next session's 10:00 ET: the fresh NAV is the open print
    ///      (REOPEN). Returns the open-print time.
    function _nextDay(uint256 dropBps) internal returns (uint40 printAt) {
        nav = nav * (10_000 - dropBps) / 10_000;
        _publish(nav, sessions[day].close + 15 minutes);
        ++day;
        printAt = sessions[day].open + 1 hours;
        vm.warp(printAt);
        assertEq(uint8(clock.poke(FUND)), uint8(ClockState.REOPEN), "the fresh NAV reopens the fund");
    }

    function _completeReopen() internal {
        vm.warp(block.timestamp + 121);
        adapter.completeReopen(FUND);
        assertEq(uint8(clock.poke(FUND)), uint8(ClockState.REGULAR));
    }

    function _one(address b) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = b;
    }

    function test_navScenario_solverFill_thenPoolAdvanceAndT1Claim() public {
        // the NAV drifts down, strike after strike, while every morning's REOPEN completes; both loans stay healthy
        // until the 8th strike
        for (uint256 k; k < 7; ++k) {
            _nextDay(DROP_BPS);
            _completeReopen();
            assertGe(market.healthFactor(id, ava), 1e18, "healthy before the 8th strike");
        }
        uint40 printAt = _nextDay(DROP_BPS);
        assertLt(market.healthFactor(id, ava), 1e18, "Ava under water at the open print");
        assertLt(market.healthFactor(id, bo), 1e18);

        // ── Ava: a REOPEN settlement inside the 120 s queue, sold to the solver at T+0 ──
        vm.prank(keeper);
        uint64 s1 = adapter.openSettlement(id, _one(ava));
        Settlement memory s = adapter.settlement(s1);
        assertEq(uint8(s.kind), uint8(AuctionKind.REOPEN));
        assertEq(s.floorPrice, oracle.valuationPrice(FUND) * 995 / 1000, "floor = NAV x 99.5 %");
        assertEq(s.endsAt, printAt + 15 minutes);
        vm.warp(printAt + 121);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.ReopenNotOver.selector, FUND));
        adapter.completeReopen(FUND); // the REOPEN waits for its settlement
        uint256 bid = uint256(s.floorPrice) * 10_010 / 10_000; // a solver pays 0.1 % over the floor
        uint256 escrow = (uint256(s.qty) * bid * 1e6 + 1e36 - 1) / 1e36;
        usdc.mint(solver, escrow);
        vm.startPrank(solver);
        usdc.approve(address(venue), escrow);
        venue.bid(s1, bid);
        vm.stopPrank();
        vm.warp(s.endsAt);
        uint256 debtBefore = market.debtOf(id, ava);
        vm.prank(keeper);
        adapter.finalize(s1);
        s = adapter.settlement(s1);
        assertEq(uint8(s.status), uint8(SettlementStatus.FILLED));
        assertEq(s.proceeds, escrow, "cash in (solver) = cash out (market)");
        assertEq(fund.balanceOf(solver), s.qty, "tokens to the solver");
        assertApproxEqAbs(
            market.debtOf(id, ava), debtBefore - (escrow - escrow / 100), 2, "D - (1 - lambda) P"
        );
        assertGe(market.healthFactor(id, ava), 1.1e18, "HF above H* (sold over the floor)");
        adapter.completeReopen(FUND);
        assertEq(uint8(clock.poke(FUND)), uint8(ClockState.REGULAR));

        // ── Bo: an INTRADAY settlement with no bid → the pool advances qty × floor ──
        vm.prank(keeper);
        uint64 s2 = adapter.openSettlement(id, _one(bo));
        s = adapter.settlement(s2);
        assertEq(uint8(s.kind), uint8(AuctionKind.INTRADAY));
        vm.warp(s.endsAt);
        uint256 navBefore = up.nav();
        vm.prank(keeper);
        adapter.finalize(s2);
        s = adapter.settlement(s2);
        assertEq(uint8(s.status), uint8(SettlementStatus.ADVANCED));
        uint256 cost = uint256(s.qty) * s.floorPrice / 1e30;
        assertEq(s.proceeds, cost, "the pool paid qty x floor");
        assertEq(up.redemptionClaimsOutstanding(), cost, "the claim is in NAV at cost (8.6.1)");
        assertEq(
            up.nav(), navBefore + cost / 100 / 3, "NAV: cash -> claim at cost, plus the pool's penalty third"
        );
        assertEq(fund.pendingRedeemRequest(s.requestId, address(up)), s.qty);
        assertGe(market.healthFactor(id, bo), 1.09e18, "Bo back near H* at the floor");

        // ── T+1: today's strike (flat), the issuer fulfils on the next USBANK session, the pool claims ──
        _nextDay(0);
        vm.prank(issuer);
        uint256 assets = fund.fulfillRedeem(s.requestId);
        assertEq(assets, uint256(s.qty) * nav / 1e30);
        _completeReopen();
        vm.prank(keeper);
        assertEq(up.claimRedemption(s.requestId), assets);
        assertEq(up.redemptionClaimsOutstanding(), 0);
        assertApproxEqRel(assets - cost, cost * 5 / 995, 1e12, "the pool earns the 0.5 % discount");

        // ── the issuer gates redemptions: HALTED, no settlement, repay stays open ──
        vm.prank(issuer);
        fund.setRedemptionsGated(true);
        assertEq(uint8(clock.poke(FUND)), uint8(ClockState.HALTED));
        vm.expectRevert(
            abi.encodeWithSelector(
                ICredenceErrors.ActionNotAllowedInState.selector,
                MarketAction.FLAG_FOR_AUCTION,
                ClockState.HALTED
            )
        );
        adapter.openSettlement(id, _one(ava));
        usdc.mint(ava, 1_000e6);
        vm.startPrank(ava);
        usdc.approve(address(market), 1_000e6);
        market.repay(id, ava, 1_000e6, 0);
        vm.stopPrank();
    }
}
