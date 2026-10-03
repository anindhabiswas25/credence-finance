// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MarketState, Auction, AuctionPhase, Bid, Gda, ClosureType} from "../../src/libraries/Types.sol";
import {RiskFixture} from "../utils/RiskFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RiskHandler, RSys} from "./RiskHandler.sol";

/// @notice Risk-transfer invariants on the REAL UnderwriterPool and AuctionHouse at 256 runs × depth 128 (Build Guide
///         §8.6.3, §8.7.4, §14.2): INV-POOL-01/02, INV-AH-01..04, and the S2 lending invariants (INV-MKT-01..03,
///         INV-DEBT-01, INV-WF-01, INV-LIQ-01, INV-COV-01, INV-SV-01) with the real pool instead of the mock.
contract RiskInvariantsTest is RiskFixture {
    RiskHandler internal h;

    function setUp() public {
        setUpRisk();
        _underwrite(uw1, 300_000e6);
        // every closure's safe LTV is 65%: borrowers above it need action at each Bell
        for (uint256 i; i < 3; ++i) {
            for (uint8 t = 1; t <= 3; ++t) {
                engine.setSafeLtv([NVDA, AAPL, TSLA][i], t, 0.65e18);
            }
        }
        engine.setQuote(50e6, 10e6, 200e6);
        usdc.mint(address(tips), 10_000_000e6);
        h = new RiskHandler(
            RSys({
                market: market,
                vault: vault,
                reserve: reserve,
                pool: up,
                house: house,
                cal: cal,
                usdc: usdc,
                tokens: [tNVDA, tAAPL, tTSLA],
                ids: [idNVDA, idAAPL, idTSLA],
                assets: [NVDA, AAPL, TSLA],
                clk: clk,
                orc: orc,
                engine: engine,
                venue: VENUE
            })
        );
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](20);
        (sel[0], sel[1], sel[2], sel[3], sel[4]) =
        (h.advance.selector, h.advance.selector, h.advance.selector, h.advance.selector, h.advance.selector);
        (sel[5], sel[6], sel[7], sel[8]) =
        (h.borrow.selector, h.borrow.selector, h.borrow.selector, h.repay.selector);
        (sel[9], sel[10], sel[11], sel[12]) =
        (h.buyCover.selector, h.underwrite.selector, h.requestWithdraw.selector, h.claimPool.selector);
        (sel[13], sel[14], sel[15], sel[16]) =
        (h.advance.selector, h.advance.selector, h.resell.selector, h.gdaBuy.selector);
        (sel[17], sel[18], sel[19]) =
        (h.releaseReserve.selector, h.setAutoCover.selector, h.claimFees.selector);
        targetSelector(StdInvariant.FuzzSelector({addr: address(h), selectors: sel}));
        excludeSender(address(market));
        excludeSender(address(up));
        excludeSender(address(house));
    }

    function _ids() internal view returns (bytes32[3] memory) {
        return [idNVDA, idAAPL, idTSLA];
    }

    // ───────────── pool ─────────────

    /// INV-POOL-01: epoch accounting sums to zero (checked at every settlement by the handler)
    function invariant_POOL01_epochAccounting() public view {
        assertEq(h.ghostPool01(), 0);
    }

    /// INV-POOL-02: no cover is written with u_after > u_max
    function invariant_POOL02_utilisationBound() public view {
        assertEq(h.ghostPool02(), 0);
    }

    // ───────────── auction house ─────────────

    /// INV-AH-01: cash in = cash to the market at every clearing, refunds = escrow − payment, and the loan tokens the
    ///            auction house holds are exactly the escrows still owed to bidders
    function invariant_AH01_cashConservation() public view {
        assertEq(h.ghostAh01(), 0);
        uint64[] memory list = h.auctionList();
        uint256 owed;
        for (uint256 i; i < list.length; ++i) {
            Auction memory a = house.auction(list[i]);
            address[] memory bs = house.bidders(list[i]);
            for (uint256 k; k < bs.length; ++k) {
                Bid memory b = house.bid(list[i], bs[k]);
                if (a.phase == AuctionPhase.CLEARED) {
                    if (b.claimed || !b.revealed) continue;
                    owed += b.escrow - (b.fill == 0 ? 0 : (uint256(b.fill) * a.pStar + 1e30 - 1) / 1e30);
                } else {
                    owed += b.escrow;
                }
            }
        }
        assertEq(usdc.balanceOf(address(house)), owed);
    }

    /// INV-AH-02: every filled bid pays exactly p*
    function invariant_AH02_uniformPrice() public view {
        assertEq(h.ghostAh02(), 0);
    }

    /// INV-AH-03: a bid below R is never filled
    function invariant_AH03_reserveRespected() public view {
        assertEq(h.ghostAh03(), 0);
    }

    /// INV-AH-04: collateral in = collateral out: the auction house holds exactly the lots being auctioned, the
    ///            unclaimed fills, and the unsold GDA inventory
    function invariant_AH04_collateralConservation() public view {
        MockERC20[3] memory toks = [tNVDA, tAAPL, tTSLA];
        bytes32[3] memory assets = [NVDA, AAPL, TSLA];
        uint64[] memory list = h.auctionList();
        for (uint256 t; t < 3; ++t) {
            uint256 held;
            for (uint256 i; i < list.length; ++i) {
                Auction memory a = house.auction(list[i]);
                if (a.assetId != assets[t]) continue;
                if (a.phase == AuctionPhase.COMMIT || a.phase == AuctionPhase.OPEN_BIDDING) {
                    held += a.lot;
                } else if (a.phase == AuctionPhase.CLEARED) {
                    address[] memory bs = house.bidders(list[i]);
                    for (uint256 k; k < bs.length; ++k) {
                        Bid memory b = house.bid(list[i], bs[k]);
                        if (!b.claimed) held += b.fill;
                    }
                }
            }
            for (uint64 g = 1; g < house.nextGdaId(); ++g) {
                Gda memory x = house.gda(g);
                if (x.active && x.assetId == assets[t]) held += x.qty - x.sold;
            }
            assertEq(toks[t].balanceOf(address(house)), held);
        }
    }

    // ───────────── S2 lending invariants, against the real pool ─────────────

    function invariant_MKT01_solvency() public view {
        uint256 lhs = usdc.balanceOf(address(market));
        uint256 rhs;
        bytes32[3] memory ids = _ids();
        for (uint256 i; i < 3; ++i) {
            MarketState memory st = market.marketState(ids[i]);
            lhs += st.totalBorrowAssets;
            rhs += uint256(st.totalSupplyAssets) + st.poolFeeAccrued + st.treasuryFeeAccrued;
        }
        assertGe(lhs, rhs);
    }

    function invariant_MKT02_borrowsCovered() public view {
        bytes32[3] memory ids = _ids();
        for (uint256 i; i < 3; ++i) {
            MarketState memory st = market.marketState(ids[i]);
            assertLe(
                st.totalBorrowAssets,
                uint256(st.totalSupplyAssets) + st.poolFeeAccrued + st.treasuryFeeAccrued
            );
        }
    }

    function invariant_MKT03_collateral() public view {
        bytes32[3] memory ids = _ids();
        MockERC20[3] memory toks = [tNVDA, tAAPL, tTSLA];
        address[4] memory bs = h.borrowerList();
        for (uint256 i; i < 3; ++i) {
            uint256 sum;
            for (uint256 j; j < 4; ++j) {
                sum += market.position(ids[i], bs[j]).collateral;
            }
            uint256 total = market.marketState(ids[i]).totalCollateral;
            assertEq(sum, total);
            assertGe(toks[i].balanceOf(address(market)), total);
        }
    }

    function invariant_DEBT01_debtSums() public view {
        bytes32[3] memory ids = _ids();
        address[4] memory bs = h.borrowerList();
        for (uint256 i; i < 3; ++i) {
            uint256 sum;
            for (uint256 j; j < 4; ++j) {
                sum += market.debtOf(ids[i], bs[j]);
            }
            uint256 b = market.marketState(ids[i]).totalBorrowAssets;
            assertLe(b, sum + 5);
            assertLe(sum, b + 5);
        }
    }

    function invariant_WF01_waterfallOrder() public view {
        assertEq(h.ghostWf01(), 0);
    }

    function invariant_LIQ01_noLiquidationWhileShut() public view {
        assertEq(h.ghostLiq01(), 0);
    }

    function invariant_COV01_coverWindow() public view {
        assertEq(h.ghostCov01(), 0);
    }

    function invariant_SV01_sharePriceFallsOnlyOnLoss() public view {
        assertEq(h.ghostSv01(), 0);
    }

    /// @dev Queued deposits are never spent (payShortfall, backstopBuy and claimWithdraw use cash net of them);
    ///      reserved withdrawals may wait for inventory resale (FIFO), so they are not bounded by cash.
    function invariant_POOL_queuedDepositsInCash() public view {
        assertGe(usdc.balanceOf(address(up)), up.queuedDeposits());
    }

    function afterInvariant() external view {
        console2.log(
            string.concat(
                "depth: session ",
                vm.toString(h.session()),
                ", covers ",
                vm.toString(h.okCovers()),
                ", clears ",
                vm.toString(h.okClears()),
                ", settles ",
                vm.toString(h.okSettles()),
                ", epochs ",
                vm.toString(h.okEpochs()),
                ", backstops ",
                vm.toString(h.okBackstops()),
                ", forfeits ",
                vm.toString(h.okForfeits()),
                ", claims ",
                vm.toString(h.okClaims())
            )
        );
    }
}
