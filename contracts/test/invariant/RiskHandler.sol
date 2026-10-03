// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {
    ClockState,
    ClockData,
    ClosureType,
    AuctionKind,
    AuctionPhase,
    Auction,
    Bid,
    Epoch,
    EpochPhase,
    Inventory,
    Session
} from "../../src/libraries/Types.sol";
import {CredenceMarket} from "../../src/core/CredenceMarket.sol";
import {SeniorVault} from "../../src/core/SeniorVault.sol";
import {ProtocolReserve} from "../../src/core/ProtocolReserve.sol";
import {UnderwriterPool} from "../../src/pool/UnderwriterPool.sol";
import {AuctionHouse} from "../../src/auction/AuctionHouse.sol";
import {CalendarStore} from "../../src/clock/CalendarStore.sol";
import {ICredenceMarketEvents, IUnderwriterPoolEvents} from "../../src/libraries/Events.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRiskEngine} from "../mocks/MockRiskEngine.sol";
import {MockMarketClock} from "../mocks/MockMarketClock.sol";
import {MockMarketOracle} from "../mocks/MockMarketOracle.sol";

struct RSys {
    CredenceMarket market;
    SeniorVault vault;
    ProtocolReserve reserve;
    UnderwriterPool pool;
    AuctionHouse house;
    CalendarStore cal;
    MockERC20 usdc;
    MockERC20[3] tokens;
    bytes32[3] ids;
    bytes32[3] assets;
    MockMarketClock clk;
    MockMarketOracle orc;
    MockRiskEngine engine;
    bytes32 venue;
}

/// @notice Drives the whole risk-transfer cycle on the REAL pool and auction house, one venue session at a time
///         (brief E): morning (borrow, repay, deposits, withdrawals) → Bell window (cover, epoch opens) → Bell
///         deadline (snapshot, enforceBell: auto-cover or pre-close sale) → pre-close batch (fix, open bids, clear,
///         settle) → close → open print with a price shock → REOPEN auction (fix, sealed bids by an honest, a low-ball
///         and a non-revealing bidder; reveal; clear with the pool backstop; settle; completion) → epoch settlement.
///         Ghosts record INV-POOL-01/02, INV-AH-01..04 and the S2 lending invariants against the real pool.
contract RiskHandler is Test {
    RSys internal s;
    address[4] internal borrowers;
    address[2] internal uws;
    address internal honest = makeAddr("inv-bidder-honest");
    address internal lowball = makeAddr("inv-bidder-lowball");
    address internal silent = makeAddr("inv-bidder-silent");
    address internal keeper = makeAddr("inv-keeper");

    uint64 public session; // calendar session of the current day
    uint256 public phase; // 0 morning … 10 epoch settlement
    uint64 public closureId = 1; // the current (last) closure; cover bought now protects closureId + 1
    uint256[3] public price = [uint256(180e18), 200e18, 250e18];
    uint64[] internal auctions; // every auction created (for the conservation checks)
    mapping(uint64 => bool) internal seen;

    // ── ghosts ──
    uint256 public ghostPool01; // INV-POOL-01
    uint256 public ghostPool02; // INV-POOL-02
    uint256 public ghostAh01; // INV-AH-01 (cash at clearing, refunds at claim)
    uint256 public ghostAh02; // INV-AH-02 (every filled bid pays p*)
    uint256 public ghostAh03; // INV-AH-03 (no fill below R)
    uint256 public ghostWf01; // INV-WF-01
    uint256 public ghostLiq01; // INV-LIQ-01
    uint256 public ghostCov01; // INV-COV-01
    uint256 public ghostSv01; // INV-SV-01
    // INV-POOL-01 bookkeeping of the active epoch
    uint64 internal trackedEpoch = type(uint64).max;
    int256 internal unrealAtOpen;
    uint256 internal releasedDuring;
    uint256 internal lastSharePrice;
    uint256[4][3] internal lastColl;
    // depth
    uint256 public okCovers;
    uint256 public okClears;
    uint256 public okSettles;
    uint256 public okEpochs;
    uint256 public okBackstops;
    uint256 public okForfeits;
    uint256 public okClaims;

    constructor(RSys memory sys) {
        s = sys;
        for (uint256 i; i < 4; ++i) {
            borrowers[i] = makeAddr(string.concat("inv-risk-borrower-", vm.toString(i)));
        }
        for (uint256 i; i < 2; ++i) {
            uws[i] = makeAddr(string.concat("inv-underwriter-", vm.toString(i)));
        }
        address[3] memory bidders = [honest, lowball, silent];
        for (uint256 i; i < 3; ++i) {
            s.usdc.mint(bidders[i], 100_000_000e6);
            vm.prank(bidders[i]);
            s.usdc.approve(address(s.house), type(uint256).max);
        }
        lastSharePrice = s.vault.convertToAssets(1e18);
        _morning();
    }

    function borrowerList() external view returns (address[4] memory) {
        return borrowers;
    }

    function auctionList() external view returns (uint64[] memory) {
        return auctions;
    }

    // ═════════════════════════════ time: the session cycle ═════════════════════════════

    function _sess(uint64 i) internal view returns (Session memory) {
        return s.cal.session(s.venue, i);
    }

    /// @dev Next phase of the cycle, with the keeper steps that phase needs (random actions come on top).
    function advance(uint256 shockSeed, uint256 bidSeed) external {
        phase = phase == 10 ? 0 : phase + 1;
        Session memory cur = _sess(session);
        if (phase == 0) {
            ++session;
            _morning();
        } else if (phase == 1) {
            vm.warp(cur.close - 1 hours);
            _try(address(s.pool), abi.encodeCall(s.pool.openEpoch, (s.venue)));
        } else if (phase == 2) {
            vm.warp(cur.close - 10 minutes);
            _try(address(s.pool), abi.encodeCall(s.pool.snapshotEpoch, (session)));
            for (uint256 i; i < 3; ++i) {
                _bell(i);
            }
        } else if (phase == 3) {
            vm.warp(cur.close - 5 minutes);
            _fixAll();
            _openBids(bidSeed);
        } else if (phase == 4) {
            vm.warp(cur.close - 30);
            _clearAll();
        } else if (phase == 5) {
            vm.warp(cur.close + 1 hours);
            ++closureId;
            for (uint256 i; i < 3; ++i) {
                s.clk.setState(s.assets[i], ClockState.CLOSED);
                s.clk.setReopen(s.assets[i], closureId, session, true);
            }
            _fixAll(); // a pre-close lot the keeper missed is cancelled now
        } else if (phase == 6) {
            uint40 printAt = _sess(session + 1).open;
            vm.warp(printAt + 5);
            for (uint256 i; i < 3; ++i) {
                uint256 pct = bound(uint256(keccak256(abi.encode(shockSeed, i))), 60, 105);
                price[i] = price[i] * pct / 100;
                s.orc.setPrice(s.assets[i], price[i]);
                s.clk.setState(s.assets[i], ClockState.REOPEN);
                s.clk.setReopen(s.assets[i], closureId, session, true);
                s.clk.setOpenPrint(s.assets[i], uint128(price[i]), printAt);
                vm.prank(keeper);
                try s.market.flagForAuction(s.ids[i], _all()) {} catch {}
            }
        } else if (phase == 7) {
            vm.warp(_sess(session + 1).open + 120);
            _fixAll();
            _sealedBids(bidSeed);
        } else if (phase == 8) {
            vm.warp(_sess(session + 1).open + 300);
            _reveal();
        } else if (phase == 9) {
            vm.warp(_sess(session + 1).open + 420);
            _clearAll();
            for (uint256 i; i < 3; ++i) {
                _try(address(s.house), abi.encodeCall(s.house.completeReopen, (s.assets[i])));
            }
        } else {
            vm.warp(_sess(session + 1).open + 11 minutes);
            _clearAll(); // a late keeper clears / settles what is left
            _settleEpoch(session);
        }
        _after(false, false);
    }

    function _morning() internal {
        Session memory cur = _sess(session);
        vm.warp(cur.open + 1 hours);
        for (uint256 i; i < 3; ++i) {
            bytes32 a = s.assets[i];
            s.clk.setState(a, ClockState.REGULAR);
            s.clk.setReopen(a, closureId, session == 0 ? 0 : session - 1, false);
            bool fri = cur.closureTypeAfter == ClosureType.WEEKEND;
            s.clk.setNextClose(a, cur.close, cur.closureTypeAfter, fri ? 3 : 1);
            s.clk.setCursor(a, uint32(session));
        }
    }

    // ═════════════════════════════ actors ═════════════════════════════

    function underwrite(uint256 who, uint256 amt) external {
        address u = uws[bound(who, 0, 1)];
        uint256 a = bound(amt, 1_000e6, 200_000e6);
        s.usdc.mint(u, a);
        vm.startPrank(u);
        s.usdc.approve(address(s.pool), a);
        try s.pool.deposit(a, u) {} catch {}
        vm.stopPrank();
        _after(false, false);
    }

    function requestWithdraw(uint256 who, uint256 pct) external {
        address u = uws[bound(who, 0, 1)];
        uint256 sh = s.pool.balanceOf(u) * bound(pct, 1, 50) / 100;
        if (sh == 0) return;
        vm.prank(u);
        try s.pool.requestWithdraw(sh) {} catch {}
        _after(false, false);
    }

    function claimPool(uint256 who, uint256 back) external {
        address u = uws[bound(who, 0, 1)];
        uint64 e = session > bound(back, 0, 3) ? session - uint64(bound(back, 0, 3)) : 0;
        vm.startPrank(u);
        try s.pool.claimWithdraw(e) {} catch {}
        try s.pool.claimDeposit(e) {} catch {}
        vm.stopPrank();
        _after(false, false);
    }

    function borrow(uint256 who, uint256 m, uint256 ltvBps) external {
        if (phase > 1) return; // before the Bell deadline only
        uint256 i = bound(m, 0, 2);
        address b = borrowers[bound(who, 0, 3)];
        uint256 q = 100e18;
        if (s.market.position(s.ids[i], b).collateral == 0) {
            s.tokens[i].mint(b, q);
            vm.startPrank(b);
            s.tokens[i].approve(address(s.market), q);
            s.market.addCollateral(s.ids[i], b, q);
            vm.stopPrank();
        }
        uint256 c = s.market.position(s.ids[i], b).collateral * price[i] / 1e30;
        uint256 want = c * bound(ltvBps, 5_000, 7_450) / 10_000;
        uint256 d = s.market.debtOf(s.ids[i], b);
        if (want <= d + 1e6) return;
        vm.prank(b);
        try s.market.borrow(s.ids[i], want - d, b) {} catch {}
        _after(false, false);
    }

    function repay(uint256 who, uint256 m, uint256 pct) external {
        uint256 i = bound(m, 0, 2);
        address b = borrowers[bound(who, 0, 3)];
        uint256 d = s.market.debtOf(s.ids[i], b);
        if (d == 0) return;
        uint256 amt = d * bound(pct, 1, 100) / 100;
        s.usdc.mint(b, amt);
        vm.startPrank(b);
        s.usdc.approve(address(s.market), amt);
        try s.market.repay(s.ids[i], b, amt, 0) {} catch {}
        vm.stopPrank();
        _after(false, false);
    }

    function buyCover(uint256 who, uint256 m) external {
        uint256 i = bound(m, 0, 2);
        address b = borrowers[bound(who, 0, 3)];
        s.usdc.mint(b, 1_000e6);
        vm.startPrank(b);
        s.usdc.approve(address(s.market), 1_000e6);
        vm.recordLogs();
        try s.market.buyCover(s.ids[i], 1_000e6, false) {
            ++okCovers;
        } catch {}
        vm.stopPrank();
        _checkCoverLogs(vm.getRecordedLogs());
        _after(false, false);
    }

    function setAutoCover(uint256 who, uint256 m, bool on) external {
        vm.prank(borrowers[bound(who, 0, 3)]);
        s.market.setAutoCover(s.ids[bound(m, 0, 2)], on);
    }

    function claimFees(uint256 m) external {
        try s.market.claimFees(s.ids[bound(m, 0, 2)]) {} catch {}
        _after(false, false);
    }

    function resell(uint256 m) external {
        _try(address(s.pool), abi.encodeCall(s.pool.resellInventory, (s.assets[bound(m, 0, 2)])));
        _after(false, false);
    }

    function gdaBuy(uint256 g, uint256 pct) external {
        uint64 id = uint64(bound(g, 1, s.house.nextGdaId()));
        if (!s.house.gda(id).active) return;
        uint256 q = s.house.gda(id).qty * bound(pct, 1, 30) / 100;
        try s.house.gdaPrice(id, q) returns (uint256 cost) {
            s.usdc.mint(honest, cost);
            vm.prank(honest);
            try s.house.gdaBuy(id, q, cost) {} catch {}
        } catch {}
        _after(false, false);
    }

    function releaseReserve(uint256 back, uint256 m) external {
        uint64 e = session > bound(back, 0, 5) ? session - uint64(bound(back, 0, 5)) : 0;
        bytes32 a = s.assets[bound(m, 0, 2)];
        uint256 x = s.pool.lossReserve(e, a);
        try s.pool.releaseLossReserve(e, a) {
            (, bool live) = s.pool.activeEpoch();
            if (live) releasedDuring += x;
        } catch {}
        _after(false, false);
    }

    // ═════════════════════════════ keeper steps ═════════════════════════════

    function _bell(uint256 i) internal {
        vm.recordLogs();
        vm.prank(keeper);
        try s.market.enforceBell(s.ids[i], _all()) {} catch {}
        _checkCoverLogs(vm.getRecordedLogs());
        _track();
    }

    function _fixAll() internal {
        uint64 n = s.house.nextAuctionId();
        for (uint64 id = 1; id < n; ++id) {
            _note(id);
            Auction memory a = s.house.auction(id);
            if (a.phase != AuctionPhase.QUEUE || block.timestamp < a.deadlines[0]) continue;
            vm.prank(keeper);
            try s.house.fixLots(id) {} catch {}
        }
    }

    function _openBids(uint256 seed) internal {
        uint64 n = s.house.nextAuctionId();
        for (uint64 id = 1; id < n; ++id) {
            Auction memory a = s.house.auction(id);
            if (a.phase != AuctionPhase.OPEN_BIDDING || a.lot == 0) continue;
            uint256 v = s.orc.valuationPrice(a.assetId);
            uint256 frac = bound(seed, 30, 110);
            uint256 q = a.lot * frac / 100;
            if (q != 0) {
                vm.prank(honest);
                try s.house.placeBid(id, uint128(q), uint128(v * 995 / 1000)) {} catch {}
            }
            vm.prank(lowball);
            try s.house.placeBid(id, a.lot, uint128(v * 90 / 100)) {} catch {}
        }
    }

    function _sealedBids(uint256 seed) internal {
        uint64 n = s.house.nextAuctionId();
        for (uint64 id = 1; id < n; ++id) {
            Auction memory a = s.house.auction(id);
            if (a.kind != AuctionKind.REOPEN || a.phase != AuctionPhase.COMMIT || a.lot == 0) continue;
            uint256 v = uint256(a.reserve) * 100 / 97;
            (uint128 qh, uint128 ph) = _honestBid(a.lot, v, seed);
            _commit(honest, id, qh, ph);
            _commit(lowball, id, a.lot, uint128(v * 80 / 100));
            _commit(silent, id, a.lot, uint128(v));
        }
    }

    function _honestBid(uint128 lot, uint256 v, uint256 seed) internal pure returns (uint128, uint128) {
        return
            (
                uint128(uint256(lot) * bound(seed, 30, 110) / 100),
                uint128(v * bound(seed >> 8, 975, 1000) / 1000)
            );
    }

    mapping(uint64 => mapping(address => uint128[2])) internal committed;

    function _commit(address who, uint64 id, uint128 qty, uint128 p) internal {
        if (qty == 0) return;
        committed[id][who] = [qty, p];
        uint256 notional = (uint256(qty) * p + 1e30 - 1) / 1e30 + 1;
        bytes32 c =
            keccak256(abi.encode(block.chainid, address(s.house), id, who, qty, p, bytes32(uint256(id))));
        vm.prank(who);
        try s.house.commitBid(id, c, uint128(notional)) {} catch {}
    }

    function _reveal() internal {
        uint64 n = s.house.nextAuctionId();
        for (uint64 id = 1; id < n; ++id) {
            Auction memory a = s.house.auction(id);
            if (a.kind != AuctionKind.REOPEN || a.phase != AuctionPhase.COMMIT) continue;
            address[2] memory who = [honest, lowball];
            for (uint256 k; k < 2; ++k) {
                Bid memory b = s.house.bid(id, who[k]);
                if (b.commitment == bytes32(0)) continue;
                // recover the committed (qty, price) from the handler's own rule
                (uint128 q, uint128 p) = (committed[id][who[k]][0], committed[id][who[k]][1]);
                vm.prank(who[k]);
                try s.house.revealBid(id, q, p, bytes32(uint256(id))) {} catch {}
            }
        }
    }

    function _clearAll() internal {
        uint64 n = s.house.nextAuctionId();
        for (uint64 id = 1; id < n; ++id) {
            _note(id);
            Auction memory a = s.house.auction(id);
            if (
                (a.phase == AuctionPhase.COMMIT || a.phase == AuctionPhase.OPEN_BIDDING)
                    && block.timestamp >= a.deadlines[3]
            ) {
                _clear(id);
            }
            a = s.house.auction(id);
            if (a.phase == AuctionPhase.CLEARED && !a.settled) _settle(id);
            if (a.phase == AuctionPhase.CLEARED) _claims(id);
        }
    }

    function _clear(uint64 id) internal {
        Auction memory a = s.house.auction(id);
        MockERC20 loan = s.usdc;
        uint256 poolBefore = loan.balanceOf(address(s.pool));
        uint256 mktBefore = loan.balanceOf(address(s.market));
        vm.prank(keeper);
        try s.house.clear(id) {
            ++okClears;
        } catch {
            return;
        }
        a = s.house.auction(id);
        address[] memory list = s.house.bidders(id);
        uint256 paidBidders;
        uint256 bonds;
        for (uint256 k; k < list.length; ++k) {
            Bid memory b = s.house.bid(id, list[k]);
            if (!b.revealed) {
                bonds += 0; // forfeited bonds went to the pool: escrow was zeroed
                if (b.escrow != 0) ++ghostAh01;
                ++okForfeits;
                continue;
            }
            if (b.price < a.reserve && b.fill != 0) ++ghostAh03; // INV-AH-03
            if (b.fill != 0) paidBidders += (uint256(b.fill) * a.pStar + 1e30 - 1) / 1e30;
            if (b.fill != 0 && b.price < a.pStar) ++ghostAh02; // a bid below p* can never fill
        }
        uint256 poolPaid;
        uint256 poolAfter = loan.balanceOf(address(s.pool));
        // the pool received the forfeited bonds and paid the backstop
        uint256 forfeited;
        for (uint256 k; k < list.length; ++k) {
            Bid memory b = s.house.bid(id, list[k]);
            if (!b.revealed) forfeited += _bondOf(id, list[k]);
        }
        if (poolBefore + forfeited >= poolAfter) poolPaid = poolBefore + forfeited - poolAfter;
        if (a.qPool != 0) ++okBackstops;
        // INV-AH-01: cash in (Σ fills × p* + pool) = proceeds = cash to the market
        if (a.proceeds != paidBidders + poolPaid) ++ghostAh01;
        if (loan.balanceOf(address(s.market)) - mktBefore != a.proceeds) ++ghostAh01;
        if (a.filled + a.qPool != a.lot) ++ghostAh01;
        _track();
    }

    mapping(uint64 => mapping(address => uint256)) internal _bonds;

    function _bondOf(uint64 id, address who) internal view returns (uint256) {
        return _bonds[id][who];
    }

    function _note(uint64 id) internal {
        if (!seen[id]) {
            seen[id] = true;
            auctions.push(id);
        }
        address[] memory list = s.house.bidders(id);
        for (uint256 k; k < list.length; ++k) {
            Bid memory b = s.house.bid(id, list[k]);
            if (_bonds[id][list[k]] == 0 && b.commitment != bytes32(0)) {
                _bonds[id][list[k]] = uint256(b.maxNotional) * 1000 / 10_000
                    + (uint256(b.maxNotional) * 1000 % 10_000 == 0 ? 0 : 1);
            }
        }
    }

    function _settle(uint64 id) internal {
        uint256 poolFree = s.pool.freeCash();
        uint256 resBal = s.reserve.balance();
        vm.recordLogs();
        vm.prank(keeper);
        try s.market.settlePositions(id, s.market.lotBorrowers(id)) {
            ++okSettles;
        } catch {}
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool loss;
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].topics[0] != ICredenceMarketEvents.Shortfall.selector) continue;
            (uint256 sf, uint256 paidPool, uint256 paidReserve, uint256 seniorLoss) =
                abi.decode(logs[j].data, (uint256, uint256, uint256, uint256));
            uint256 wantPool = sf < poolFree ? sf : poolFree;
            uint256 rest = sf - wantPool;
            uint256 wantRes = rest < resBal ? rest : resBal;
            if (paidPool != wantPool || paidReserve != wantRes || seniorLoss != rest - wantRes) ++ghostWf01;
            poolFree -= paidPool;
            resBal -= paidReserve;
            if (seniorLoss != 0) loss = true;
        }
        _track();
        _after(false, loss);
    }

    function _claims(uint64 id) internal {
        Auction memory a = s.house.auction(id);
        address[] memory list = s.house.bidders(id);
        for (uint256 k; k < list.length; ++k) {
            Bid memory b = s.house.bid(id, list[k]);
            if (b.claimed || !b.revealed || b.escrow == 0) continue;
            MockERC20 coll = _tokenOf(a.assetId);
            uint256 u0 = s.usdc.balanceOf(list[k]);
            uint256 c0 = coll.balanceOf(list[k]);
            vm.prank(list[k]);
            try s.house.claim(id) {
                ++okClaims;
            } catch {
                continue;
            }
            uint256 pay = b.fill == 0 ? 0 : (uint256(b.fill) * a.pStar + 1e30 - 1) / 1e30;
            // INV-AH-02: a filled bid pays exactly fill × p*, whatever its own price; the rest is refunded
            if (s.usdc.balanceOf(list[k]) - u0 != b.escrow - pay) ++ghostAh02;
            if (coll.balanceOf(list[k]) - c0 != b.fill) ++ghostAh02;
        }
    }

    function _settleEpoch(uint64 e) internal {
        Epoch memory before = s.pool.epoch(e);
        (uint64 act, bool live) = s.pool.activeEpoch();
        bool opened = live && act == e;
        vm.prank(keeper);
        try s.pool.settleEpoch(e) {
            ++okEpochs;
        } catch {
            return;
        }
        Epoch memory x = s.pool.epoch(e);
        if (opened && before.phase != EpochPhase.NONE && trackedEpoch == e) {
            // INV-POOL-01: NAV_after − NAV_before = premiums + fees + penalties + bonds + realised backstop P&L − losses
            //              (− the R-11 reserve, + unrealised inventory marks and reserves released meanwhile)
            int256 lhs = int256(uint256(x.navAfter)) - int256(uint256(x.navBefore));
            int256 rhs = int256(uint256(x.premiums) + x.riskFees + x.penalties + x.bonds) + x.backstopPnl
                - int256(uint256(x.lossesPaid) + x.pendingLossReserve) + (_unrealised() - unrealAtOpen)
                + int256(releasedDuring);
            int256 diff = lhs - rhs;
            if (diff > 64 || diff < -64) ++ghostPool01; // ≤ 1 unit of rounding per operation
            // sharePriceAfter = NAV_after / supply before the queues are processed
            uint256 supplyBefore = s.pool.totalSupply() + x.withdrawSharesQueued - x.depositSharesMinted;
            if (x.sharePriceAfter != (uint256(x.navAfter) + 1) * 1e30 / (supplyBefore + 1e12)) ++ghostPool01;
        }
        trackedEpoch = type(uint64).max;
        _after(false, false);
    }

    // ═════════════════════════════ checks ═════════════════════════════

    /// @dev Remember the unrealised inventory mark when an epoch becomes active (INV-POOL-01).
    function _track() internal {
        (uint64 e, bool live) = s.pool.activeEpoch();
        if (live && trackedEpoch != e) {
            trackedEpoch = e;
            unrealAtOpen = _unrealised();
            releasedDuring = 0;
        }
    }

    /// @dev Σ min(cost, V × (1 − κ) × qty) − Σ cost over the pool's inventory, as the pool computes it.
    function _unrealised() internal view returns (int256 u) {
        uint256 kappa = s.engine.params().kappa;
        for (uint256 i; i < 3; ++i) {
            Inventory memory inv = s.pool.inventory(s.assets[i]);
            if (inv.qty == 0) continue;
            uint256 v = s.orc.valuationPrice(s.assets[i]);
            uint256 mark = uint256(inv.qty) * (v * (1e18 - kappa) / 1e18) / 1e30;
            uint256 val = mark < inv.cost ? mark : inv.cost;
            u += int256(val) - int256(uint256(inv.cost));
        }
    }

    function _checkCoverLogs(Vm.Log[] memory logs) internal {
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].topics[0] == IUnderwriterPoolEvents.CoverWritten.selector) {
                (,,, uint256 uAfter,) = abi.decode(logs[j].data, (uint64, bytes32, uint256, uint256, uint256));
                if (uAfter > s.engine.params().uMax) ++ghostPool02; // INV-POOL-02
                ++okCovers;
            }
            if (logs[j].topics[0] == ICredenceMarketEvents.CoverBought.selector) {
                (,,,, bool auto_) = abi.decode(logs[j].data, (uint64, uint64, uint256, bool, bool));
                ClockData memory d = s.clk.closureInfo(_assetOf(logs[j].topics[1]));
                bool regular = d.state == ClockState.REGULAR;
                bool ok = auto_
                    ? regular && block.timestamp >= d.bellAt && block.timestamp < d.nextCloseAt
                    : regular && block.timestamp < d.bellAt;
                if (!ok) ++ghostCov01; // INV-COV-01
            }
        }
        _track();
    }

    function _after(bool ownerWithdrawal, bool lossRecorded) internal {
        ClockState st = s.clk.st(s.assets[0]);
        bool shut = st == ClockState.CLOSED || st == ClockState.HALTED;
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 4; ++j) {
                uint256 c = s.market.position(s.ids[i], borrowers[j]).collateral;
                if (shut && !ownerWithdrawal && c < lastColl[i][j]) ++ghostLiq01; // INV-LIQ-01
                lastColl[i][j] = c;
            }
        }
        uint256 sp = s.vault.convertToAssets(1e18);
        if (sp + 1 < lastSharePrice && !lossRecorded) ++ghostSv01; // INV-SV-01
        lastSharePrice = sp;
    }

    function _try(address to, bytes memory data) internal {
        vm.prank(keeper);
        (bool ok,) = to.call(data);
        ok;
        _track();
    }

    function _all() internal view returns (address[] memory bs) {
        bs = new address[](4);
        for (uint256 i; i < 4; ++i) {
            bs[i] = borrowers[i];
        }
    }

    function _assetOf(bytes32 id) internal view returns (bytes32) {
        for (uint256 i; i < 3; ++i) {
            if (s.ids[i] == id) return s.assets[i];
        }
        revert("unknown market");
    }

    function _tokenOf(bytes32 asset) internal view returns (MockERC20) {
        for (uint256 i; i < 3; ++i) {
            if (s.assets[i] == asset) return s.tokens[i];
        }
        revert("unknown asset");
    }
}
