// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {
    ClockState,
    ClockData,
    ClosureType,
    GuardianOverlay,
    MarketParams,
    RiskParams,
    AuctionKind
} from "../../src/libraries/Types.sol";
import {CredenceMarket} from "../../src/core/CredenceMarket.sol";
import {SeniorVault} from "../../src/core/SeniorVault.sol";
import {ProtocolReserve} from "../../src/core/ProtocolReserve.sol";
import {CredenceGuardian} from "../../src/governance/CredenceGuardian.sol";
import {ICredenceMarketEvents} from "../../src/libraries/Events.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRiskEngine} from "../mocks/MockRiskEngine.sol";
import {MockUnderwriterPool} from "../mocks/MockUnderwriterPool.sol";
import {MockAuctionHouse} from "../mocks/MockAuctionHouse.sol";
import {MockMarketClock} from "../mocks/MockMarketClock.sol";
import {MockMarketOracle} from "../mocks/MockMarketOracle.sol";

/// @dev Everything the handler drives, set once by the invariant suite.
struct Sys {
    CredenceMarket market;
    SeniorVault vault;
    ProtocolReserve reserve;
    CredenceGuardian guardian;
    MockERC20 usdc;
    MockERC20[3] tokens;
    bytes32[3] ids;
    bytes32[3] assets;
    MockMarketClock clk;
    MockMarketOracle orc;
    MockRiskEngine engine;
    MockUnderwriterPool pool;
    MockAuctionHouse ah;
    address timelock;
    address safe;
    address allocator;
}

/// @notice Actors: borrowers, lenders, a keeper, the guardian Safe, an attacker, time (a session cycle of the clock)
///         and price shocks (brief E). Every action is bounded and swallows expected reverts; ghost counters record
///         what an invariant forbids. Repay / add-collateral are also exercised with the engine, oracle and clock
///         reverting (INV-REPAY-01/02).
contract MarketHandler is Test {
    Sys internal s;
    address[4] internal borrowers;
    address[3] internal lenders;
    address internal keeper = makeAddr("inv-keeper");
    address internal attacker = makeAddr("inv-attacker");

    // session cycle: 0 REGULAR morning, 1 Bell window, 2 after bellAt, 3 EXTENDED, 4 CLOSED, 5 REOPEN
    uint256 public phase;
    uint64 public closureId = 1;
    uint256[3] internal price = [uint256(180e18), 200e18, 250e18];
    uint256[] internal openLots;

    // ── ghosts ──
    uint256 public ghostLiqViolations; // INV-LIQ-01/02
    uint256 public ghostRepayFailures; // INV-REPAY-01/02
    uint256 public ghostWaterfallViolations; // INV-WF-01
    uint256 public ghostCoverViolations; // INV-COV-01
    uint256 public ghostSharePriceViolations; // INV-SV-01
    uint256 public ghostGovViolations; // INV-GOV-01
    uint256 public ghostSeniorLosses;
    uint256 public lastSharePrice;
    uint256 public calls;
    // how deep the run went (successful inner calls)
    uint256 public okBorrows;
    uint256 public okCovers;
    uint256 public okBells;
    uint256 public okFlags;
    uint256 public okSettles;
    uint256 public okWithdraws;

    constructor(Sys memory sys) {
        s = sys;
        for (uint256 i; i < 4; ++i) {
            borrowers[i] = makeAddr(string.concat("inv-borrower-", vm.toString(i)));
        }
        for (uint256 i; i < 3; ++i) {
            lenders[i] = makeAddr(string.concat("inv-lender-", vm.toString(i)));
        }
        lastSharePrice = s.vault.convertToAssets(1e18);
        _setPhase(0);
    }

    function borrowerList() external view returns (address[4] memory) {
        return borrowers;
    }

    // ═════════════ time and prices ═════════════

    /// @dev Advance to the next phase of the session cycle; a close starts a new closure (closureId + 1).
    function advance(uint256 steps) external {
        steps = bound(steps, 1, 3);
        for (uint256 i; i < steps; ++i) {
            _setPhase((phase + 1) % 6);
        }
        _after(false);
    }

    function _setPhase(uint256 p) internal {
        phase = p;
        vm.warp(block.timestamp + 1 hours);
        uint256 t = block.timestamp;
        // the close of "today" is always 4 h ahead in phase 0, 90 min in the window, 10 min after bellAt
        uint40 closeAt;
        ClockState st = ClockState.REGULAR;
        if (p == 0) {
            closeAt = uint40(t + 4 hours);
        } else if (p == 1) {
            closeAt = uint40(t + 90 minutes);
        } else if (p == 2) {
            closeAt = uint40(t + 10 minutes);
        } else if (p == 3) {
            st = ClockState.EXTENDED;
            ++closureId;
            closeAt = uint40(t + 1 days);
        } else if (p == 4) {
            st = ClockState.CLOSED;
            closeAt = uint40(t + 1 days);
        } else {
            st = ClockState.REOPEN;
            closeAt = uint40(t + 1 days);
        }
        for (uint256 i; i < 3; ++i) {
            bytes32 a = s.assets[i];
            s.clk.setState(a, st);
            s.clk.setClosureId(a, closureId);
            s.clk.setNextClose(a, closeAt, ClosureType.WEEKEND, 3);
            if (st == ClockState.REOPEN) s.clk.setOpenPrint(a, uint128(price[i]), uint40(block.timestamp));
        }
    }

    function shock(uint256 i, uint256 pctDown) external {
        i = bound(i, 0, 2);
        pctDown = bound(pctDown, 0, 60);
        price[i] = price[i] * (100 - pctDown) / 100;
        if (price[i] < 1e18) price[i] = 1e18;
        s.orc.setPrice(s.assets[i], price[i]);
        _after(false);
    }

    function recover(uint256 i, uint256 pctUp) external {
        i = bound(i, 0, 2);
        price[i] = price[i] * (100 + bound(pctUp, 0, 50)) / 100;
        s.orc.setPrice(s.assets[i], price[i]);
        _after(false);
    }

    // ═════════════ lenders ═════════════

    function deposit(uint256 who, uint256 amt) external {
        address l = lenders[bound(who, 0, 2)];
        amt = bound(amt, 1e6, 500_000e6);
        s.usdc.mint(l, amt);
        vm.startPrank(l);
        s.usdc.approve(address(s.vault), amt);
        try s.vault.deposit(amt, l) {} catch {}
        vm.stopPrank();
        _after(false);
    }

    function withdraw(uint256 who, uint256 amt) external {
        address l = lenders[bound(who, 0, 2)];
        uint256 max = s.vault.maxWithdraw(l);
        if (max == 0) return;
        amt = bound(amt, 1, max);
        vm.prank(l);
        try s.vault.withdraw(amt, l, l) {} catch {}
        _after(false);
    }

    function requestRedeem(uint256 who, uint256 shares) external {
        address l = lenders[bound(who, 0, 2)];
        uint256 bal = s.vault.balanceOf(l);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(l);
        try s.vault.requestRedeem(shares, l) {} catch {}
        _after(false);
    }

    function processQueue(uint256 n) external {
        try s.vault.processQueue(bound(n, 1, 5)) {} catch {}
        _after(false);
    }

    function claimRedeem(uint256 id) external {
        uint256 next = s.vault.nextRequestId();
        if (next <= 1) return;
        id = bound(id, 1, next - 1);
        address o = s.vault.redeemRequest(id).owner;
        if (o == address(0)) return;
        vm.prank(o);
        try s.vault.claimRedeem(id) {} catch {}
        _after(false);
    }

    function rebalance(uint256 from, uint256 to, uint256 amt) external {
        bytes32 a = s.ids[bound(from, 0, 2)];
        bytes32 b = s.ids[bound(to, 0, 2)];
        uint256 liq = s.market.liquidity(a);
        uint256 sup = s.market.marketState(a).totalSupplyAssets;
        uint256 max = liq < sup ? liq : sup;
        if (max == 0) return;
        amt = bound(amt, 1, max);
        vm.startPrank(s.allocator);
        try s.vault.deallocate(a, amt) {
            try s.vault.allocate(b, amt) {} catch {}
        } catch {}
        vm.stopPrank();
        _after(false);
    }

    // ═════════════ borrowers ═════════════

    function addCollateral(uint256 who, uint256 m, uint256 q) external {
        address b = borrowers[bound(who, 0, 3)];
        uint256 i = bound(m, 0, 2);
        q = bound(q, 1e15, 1_000e18);
        s.tokens[i].mint(b, q);
        vm.startPrank(b);
        s.tokens[i].approve(address(s.market), q);
        try s.market.addCollateral(s.ids[i], b, q) {}
        catch {
            ++ghostRepayFailures; // INV-REPAY-02: never reverts for valid input
        }
        vm.stopPrank();
        _after(false);
    }

    /// @dev Sized inside the position's room (limit × collateral value − debt, and market liquidity), so borrows
    ///      mostly succeed and the deep paths (Bell, cover, liquidation) are reached.
    function borrow(uint256 who, uint256 m, uint256 amt) external {
        address b = borrowers[bound(who, 0, 3)];
        uint256 i = bound(m, 0, 2);
        if (s.market.position(s.ids[i], b).collateral == 0) {
            // a borrower posts collateral before borrowing (10–500 tokens)
            uint256 q = 10e18 + (amt % 490e18);
            s.tokens[i].mint(b, q);
            vm.startPrank(b);
            s.tokens[i].approve(address(s.market), q);
            s.market.addCollateral(s.ids[i], b, q);
            vm.stopPrank();
        }
        uint256 room;
        try s.market.borrowLimitLtv(s.ids[i], b) returns (uint256 lim) {
            uint256 c = uint256(s.market.position(s.ids[i], b).collateral) * price[i] / 1e30;
            uint256 cap = c * lim / 1e18;
            uint256 debt = s.market.debtOf(s.ids[i], b);
            room = cap > debt ? (cap - debt) * 99 / 100 : 0;
        } catch {}
        uint256 liq = s.market.liquidity(s.ids[i]);
        if (liq < room) room = liq;
        if (room < 1e6) return;
        amt = bound(amt, 1e6, room);
        vm.prank(b);
        try s.market.borrow(s.ids[i], amt, b) {
            ++okBorrows;
        } catch {}
        _after(false);
    }

    function repay(uint256 who, uint256 m, uint256 amt) external {
        _repay(who, m, amt);
        _after(false);
    }

    function _repay(uint256 who, uint256 m, uint256 amt) internal {
        address b = borrowers[bound(who, 0, 3)];
        uint256 i = bound(m, 0, 2);
        uint256 debt = s.market.debtOf(s.ids[i], b);
        if (debt < 2) return;
        amt = bound(amt, 1, debt - 1);
        s.usdc.mint(b, amt);
        vm.startPrank(b);
        s.usdc.approve(address(s.market), amt);
        // a tiny amount can burn 0 shares (ZeroAmount): not a valid input
        bool valid = amt * 1e6 >= debt / 1e6 + 1e6;
        try s.market.repay(s.ids[i], b, amt, 0) {}
        catch {
            if (valid) ++ghostRepayFailures; // INV-REPAY-01
        }
        vm.stopPrank();
    }

    /// @notice INV-REPAY-01/02 with the engine, oracle and clock all reverting.
    function repayWhileBroken(uint256 who, uint256 m, uint256 amt, uint256 q) external {
        s.engine.setReverting(true);
        s.orc.setReverting(true);
        s.clk.setReverting(true);
        _repay(who, m, amt);
        address b = borrowers[bound(who, 0, 3)];
        uint256 i = bound(m, 0, 2);
        q = bound(q, 1e15, 10e18);
        s.tokens[i].mint(b, q);
        vm.startPrank(b);
        s.tokens[i].approve(address(s.market), q);
        try s.market.addCollateral(s.ids[i], b, q) {}
        catch {
            ++ghostRepayFailures;
        }
        vm.stopPrank();
        s.engine.setReverting(false);
        s.orc.setReverting(false);
        s.clk.setReverting(false);
        _after(false);
    }

    function withdrawCollateral(uint256 who, uint256 m, uint256 q) external {
        address b = borrowers[bound(who, 0, 3)];
        uint256 i = bound(m, 0, 2);
        uint256 have = s.market.position(s.ids[i], b).collateral;
        if (have == 0) return;
        q = bound(q, 1, have);
        vm.prank(b);
        try s.market.withdrawCollateral(s.ids[i], q, b) {
            ++okWithdraws;
        } catch {}
        _after(true); // an owner's withdrawal may lower collateral in any state
    }

    function buyCover(uint256 who, uint256 m, bool fromWallet) external {
        address b = borrowers[bound(who, 0, 3)];
        uint256 i = bound(m, 0, 2);
        s.usdc.mint(b, 100e6);
        vm.startPrank(b);
        s.usdc.approve(address(s.market), 100e6);
        vm.recordLogs();
        try s.market.buyCover(s.ids[i], 100e6, !fromWallet) {
            ++okCovers;
        } catch {}
        _checkCover(vm.getRecordedLogs());
        vm.stopPrank();
        _after(false);
    }

    function setAutoCover(uint256 who, uint256 m, bool on) external {
        vm.prank(borrowers[bound(who, 0, 3)]);
        s.market.setAutoCover(s.ids[bound(m, 0, 2)], on);
    }

    // ═════════════ keeper ═════════════

    function enforceBell(uint256 m) external {
        address[] memory bs = _all();
        uint256 i = bound(m, 0, 2);
        vm.recordLogs();
        vm.prank(keeper);
        try s.market.enforceBell(s.ids[i], bs) {
            ++okBells;
        } catch {}
        _checkCover(vm.getRecordedLogs());
        _after(false);
        _runLot(i, AuctionKind.PRECLOSE, closureId + 1, bound(m, 90, 105)); // the keeper fixes and clears promptly
    }

    function flag(uint256 m) external {
        address[] memory bs = _all();
        uint256 i = bound(m, 0, 2);
        vm.prank(keeper);
        try s.market.flagForAuction(s.ids[i], bs) {
            ++okFlags;
        } catch {}
        _after(false);
        ClockState st = s.clk.st(s.assets[i]);
        AuctionKind k = st == ClockState.REGULAR
            ? AuctionKind.INTRADAY
            : st == ClockState.EXTENDED ? AuctionKind.EMERGENCY : AuctionKind.REOPEN;
        _runLot(i, k, closureId, bound(m >> 8, 40, 105));
    }

    /// @dev A late keeper: fix / clear / settle a lot of a random kind, if its state still allows it.
    function auction(uint256 m, uint256 kindSeed, uint256 pricePct) external {
        uint256 i = bound(m, 0, 2);
        AuctionKind k = AuctionKind(bound(kindSeed, 0, 3));
        _runLot(i, k, k == AuctionKind.PRECLOSE ? closureId + 1 : closureId, bound(pricePct, 40, 105));
    }

    function _runLot(uint256 i, AuctionKind k, uint64 cid, uint256 pricePct) internal {
        uint256 id = s.ah.idOf(keccak256(abi.encode(k, s.ids[i], s.assets[i], cid)));
        if (id == 0 || s.ah.settled(uint64(id))) return;
        if (!s.market.lotInfo(uint64(id)).released) {
            try s.ah.fix(uint64(id)) {}
            catch {
                return;
            }
        }
        if (s.ah.lotQty(uint64(id)) == 0) return;
        if (!s.market.lotInfo(uint64(id)).cleared) {
            uint256 p = price[i] * pricePct / 100;
            uint256 q = s.ah.lotQty(uint64(id));
            s.usdc.mint(address(s.ah), q * p / 1e30 + 1);
            try s.ah.clearAt(uint64(id), p, s.usdc, 18, 6) {}
            catch {
                return;
            }
        }
        _settle(uint64(id));
    }

    function _settle(uint64 id) internal {
        uint256 poolBal = s.usdc.balanceOf(address(s.pool));
        uint256 resBal = s.reserve.balance();
        vm.recordLogs();
        vm.prank(keeper);
        try s.market.settlePositions(id, s.market.lotBorrowers(id)) {
            ++okSettles;
        } catch {}
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = ICredenceMarketEvents.Shortfall.selector;
        bool loss;
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].topics[0] != sig) continue;
            (uint256 sf, uint256 paidPool, uint256 paidReserve, uint256 seniorLoss) =
                abi.decode(logs[j].data, (uint256, uint256, uint256, uint256));
            // INV-WF-01: pool pays min(S, free cash), reserve min(rest, balance), only then senior
            uint256 wantPool = sf < poolBal ? sf : poolBal;
            uint256 rest = sf - wantPool;
            uint256 wantRes = rest < resBal ? rest : resBal;
            if (paidPool != wantPool || paidReserve != wantRes || seniorLoss != rest - wantRes) {
                ++ghostWaterfallViolations;
            }
            poolBal -= paidPool;
            resBal -= paidReserve;
            if (seniorLoss != 0) loss = true;
        }
        if (loss) ++ghostSeniorLosses;
        _after(false, loss);
    }

    function claimFees(uint256 m) external {
        try s.market.claimFees(s.ids[bound(m, 0, 2)]) {} catch {}
        _after(false);
    }

    function fundBackstops(uint256 poolAmt, uint256 resAmt) external {
        s.usdc.mint(address(s.pool), bound(poolAmt, 0, 20_000e6));
        uint256 r = bound(resAmt, 0, 5_000e6);
        s.usdc.mint(address(this), r);
        s.usdc.approve(address(s.reserve), r);
        s.reserve.fund(r);
        _after(false);
    }

    // ═════════════ guardian and attacker (INV-GOV-01) ═════════════

    function guardianAct(uint256 what, uint256 m, uint256 bps) external {
        bytes32 id = s.ids[bound(m, 0, 2)];
        vm.startPrank(s.safe);
        uint256 w = bound(what, 0, 3);
        if (w == 0) {
            try s.guardian.pauseBorrow(id) {} catch {}
        } else if (w == 1) {
            try s.guardian.scheduleUnpauseBorrow(id) {} catch {}
        } else if (w == 2) {
            try s.guardian.executeUnpause(id) {} catch {}
        } else {
            uint64 before = _liveHaircut(id);
            try s.guardian.raiseHaircut(id, uint64(bound(bps, 0, 1000))) {
                if (_liveHaircut(id) < before) ++ghostGovViolations; // can only raise
            } catch {}
        }
        vm.stopPrank();
        _after(false);
    }

    function _liveHaircut(bytes32 id) internal view returns (uint64) {
        GuardianOverlay memory o = s.market.overlay(id);
        return o.haircutUntil > block.timestamp ? o.haircut : 0;
    }

    /// @dev Every parameter setter from a non-timelock address must revert.
    function attack(uint256 what, uint256 m) external {
        bytes32 id = s.ids[bound(m, 0, 2)];
        vm.startPrank(attacker);
        uint256 w = bound(what, 0, 6);
        bool ok;
        if (w == 0) (ok,) = address(s.market).call(abi.encodeCall(s.market.setCaps, (id, 1, 1)));
        else if (w == 1) (ok,) = address(s.market).call(abi.encodeCall(s.market.setRiskParams, (id, 0.5e18, 0.6e18, 0.01e18)));
        else if (w == 2) (ok,) = address(s.market).call(abi.encodeCall(s.market.setFeeSplit, (id, 0, 0)));
        else if (w == 3) (ok,) = address(s.market).call(abi.encodeCall(s.market.setEngine, (attacker)));
        else if (w == 4) (ok,) = address(s.vault).call(abi.encodeCall(s.vault.setCap, (id, 0)));
        else if (w == 5) (ok,) = address(s.market).call(abi.encodeCall(s.market.applyOverlay, (id, GuardianOverlay(0, 0, false, false))));
        else (ok,) = address(s.reserve).call(abi.encodeCall(s.reserve.setTargetSize, (0)));
        if (ok) ++ghostGovViolations;
        vm.stopPrank();
    }

    /// @dev INV-COV-01, against the clock's own times: cover only in REGULAR; a borrower buys before bellAt, the
    ///      Bell's auto-cover runs in [bellAt, close).
    function _checkCover(Vm.Log[] memory logs) internal {
        bytes32 sig = ICredenceMarketEvents.CoverBought.selector;
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].topics[0] != sig) continue;
            (,,,, bool auto_) = abi.decode(logs[j].data, (uint64, uint64, uint256, bool, bool));
            bytes32 asset = _assetOf(logs[j].topics[1]);
            ClockData memory d = s.clk.closureInfo(asset);
            bool regular = s.clk.st(asset) == ClockState.REGULAR;
            bool ok = auto_
                ? regular && block.timestamp >= d.bellAt && block.timestamp < d.nextCloseAt
                : regular && block.timestamp < d.bellAt;
            if (!ok) ++ghostCoverViolations;
        }
    }

    function _assetOf(bytes32 id) internal view returns (bytes32) {
        for (uint256 i; i < 3; ++i) {
            if (s.ids[i] == id) return s.assets[i];
        }
        revert("unknown market");
    }

    // ═════════════ checks after every action ═════════════

    function _after(bool ownerWithdrawal) internal {
        _after(ownerWithdrawal, false);
    }

    uint256[4][3] internal lastColl;

    function _after(bool ownerWithdrawal, bool lossRecorded) internal {
        ++calls;
        // INV-LIQ-01: collateral only leaves a position by its owner's withdrawal while CLOSED / HALTED / CORP_ACTION
        ClockState st = s.clk.st(s.assets[0]);
        bool shut = st == ClockState.CLOSED || st == ClockState.HALTED || st == ClockState.CORP_ACTION;
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 4; ++j) {
                uint256 c = s.market.position(s.ids[i], borrowers[j]).collateral;
                if (shut && !ownerWithdrawal && c < lastColl[i][j]) ++ghostLiqViolations;
                lastColl[i][j] = c;
            }
        }
        // INV-SV-01: the senior share price falls only with a recorded senior loss (1 wei of rounding tolerated)
        uint256 sp = s.vault.convertToAssets(1e18);
        if (sp + 1 < lastSharePrice && !lossRecorded) ++ghostSharePriceViolations;
        lastSharePrice = sp;
    }

    function _all() internal view returns (address[] memory bs) {
        bs = new address[](4);
        for (uint256 i; i < 4; ++i) {
            bs[i] = borrowers[i];
        }
    }
}
