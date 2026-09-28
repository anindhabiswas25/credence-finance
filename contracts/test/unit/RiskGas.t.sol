// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Auction, AuctionKind} from "../../src/libraries/Types.sol";

/// @notice Gas at the §8.7.1 maximum sizes, in the EVM with the Solidity engine stand-in (the risk-core ports):
///         `flagForAuction` of 256 positions (two tranches), `fixLots` and `settlePositions` over one full lot of 128, and `clear` with the
///         64-bid maximum. The Stylus engine calls inside them (liquidationLot per position, one `clear`) are measured
///         on the devnode by `make devnode-gas`; the report combines both (acceptance 6).
contract RiskGasTest is RiskFixture {
    uint256 constant N = 256;
    address[] bs;

    function setUp() public {
        setUpRisk();
        _underwrite(uw1, 500_000e6);
        vm.warp(_openAt(0, 1) + 1 hours);
        _day(0, 1);
        for (uint256 i; i < N; ++i) {
            address b = address(uint160(0x10000 + i));
            bs.push(b);
            _position(b, idNVDA, tNVDA, 1e18, 130e6); // $180 of NVDA, $130 of debt each
        }
        orc.setPrice(NVDA, 150e18); // HF 0.92 for everyone
    }

    function test_gas_fullLotLifecycle() public {
        vm.prank(keeper);
        uint256 g = gasleft();
        market.flagForAuction(idNVDA, bs);
        uint256 gFlag = g - gasleft();
        uint64 id = market.position(idNVDA, bs[0]).auctionId;
        uint64 id2 = market.position(idNVDA, bs[N - 1]).auctionId;
        assertEq(market.lotInfo(id).positions, 128, "a full lot");
        assertEq(market.lotInfo(id2).positions, 128, "the second tranche");
        Auction memory a = house.auction(id);
        assertTrue(a.full, "the next tranche takes new positions");
        assertEq(house.auction(id2).tranche, 1);
        assertEq(house.auction(id2).deadlines[3], a.deadlines[3], "same schedule");

        vm.warp(a.deadlines[0]);
        g = gasleft();
        house.fixLots(id);
        uint256 gFix = g - gasleft();
        a = house.auction(id);
        assertEq(a.positionCount, 128);

        // 64 bidders, each for 1/64 of the lot at prices 147.00 … 153.30
        for (uint256 i; i < 64; ++i) {
            address x = address(uint160(0x20000 + i));
            usdc.mint(x, 100_000e6);
            vm.startPrank(x);
            usdc.approve(address(house), type(uint256).max);
            house.placeBid(id, uint128(a.lot / 64 + 1), uint128(147e18 + i * 0.1e18));
            vm.stopPrank();
        }
        vm.warp(a.deadlines[3]);
        g = gasleft();
        house.clear(id);
        uint256 gClear = g - gasleft();

        address[] memory lot = market.lotBorrowers(id);
        g = gasleft();
        market.settlePositions(id, lot);
        uint256 gSettle = g - gasleft();
        assertTrue(house.auction(id).settled);

        emit log_named_uint("flagForAuction (256 positions, 2 tranches)", gFlag);
        emit log_named_uint("fixLots (128 positions, engine = Solidity port)", gFix);
        emit log_named_uint("clear (64 bids, engine = Solidity port)", gClear);
        emit log_named_uint("settlePositions (128 positions)", gSettle);
        // the coverage build is unoptimised: gas bounds hold for the real (optimised) build only
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) return;
        assertLt(gFlag, 24_000_000);
        assertLt(gFix, 24_000_000);
        assertLt(gClear, 24_000_000);
        assertLt(gSettle, 24_000_000);
    }
}
