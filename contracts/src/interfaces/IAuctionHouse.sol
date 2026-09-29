// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AuctionKind, Auction, Bid, Gda} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {IAuctionHouseEvents} from "../libraries/Events.sol";

/// @title Uniform-price batch auctions for every liquidation (Build Guide §8.7). Interface v2 (S3, ADR-0110).
/// @notice Commitment = keccak256(abi.encode(block.chainid, address(this), auctionId, msg.sender, qty, price, salt)).
///         Deadlines = [lotFixAt, biddingStartAt, commitEnd (REOPEN) / biddingEnd, clearAt], phase extension included.
interface IAuctionHouse is IAuctionHouseEvents, ICredenceErrors {
    // ── market ──
    /// @notice onlyMarket: the joinable auction of (kind, market, closure), or a new one (same schedule for a
    ///         REOPEN / PRECLOSE closure; a new 60 s / 5 min batch for INTRADAY / EMERGENCY once the lot is fixed).
    function getOrCreate(AuctionKind k, bytes32 marketId, bytes32 assetId, uint64 closureId)
        external
        returns (uint64 auctionId);
    /// @notice onlyMarket: `auctionId` holds 256 positions; the next tranche (same schedule) takes new ones.
    function nextTranche(uint64 auctionId) external returns (uint64 trancheId);
    /// @notice onlyMarket: every position of the lot is settled.
    function lotSettled(uint64 auctionId) external;

    // ── keeper steps (permissionless, tipped) ──
    /// @notice Permissionless, tipped, at the lot-fix deadline: the market releases the lot (F-4.5a/b); a lot
    ///        that can no longer be fixed is cancelled.
    function fixLots(uint64 auctionId) external;
    /// @notice Permissionless, tipped, at the clear deadline: engine.clear over the revealed / open bids ≥ R,
    ///        everyone pays p*, the rest to the pool at R, proceeds to the market.
    function clear(uint64 auctionId) external;
    /// @notice Ends an asset's REOPEN (clock.markReopenComplete) once its queue window is over and every REOPEN
    ///         tranche of the closure has cleared, including when none was ever created.
    function completeReopen(bytes32 assetId) external;

    // ── sealed bidding (REOPEN) ──
    /// @notice REOPEN commit window: a sealed commitment with a bond of 10 % of `maxNotional` (R-04).
    function commitBid(uint64 auctionId, bytes32 commitment, uint128 maxNotional) external;
    /// @notice REOPEN reveal window: opens a commitment and escrows qty × price (the bond counts toward it).
    ///        A reveal below R stays unrevealed and forfeits its bond (QA-02).
    function revealBid(uint64 auctionId, uint128 qty, uint128 price, bytes32 salt) external;
    // ── open bidding (INTRADAY, EMERGENCY, PRECLOSE) ──
    /// @notice INTRADAY / EMERGENCY / PRECLOSE bidding window: a firm open bid at ≥ the lot's reserve,
    ///        escrowing qty × price.
    function placeBid(uint64 auctionId, uint128 qty, uint128 price) external;
    // ── after clearing ──
    /// @notice After clearing: winners take their tokens and unused escrow; losers their escrow (and bond).
    function claim(uint64 auctionId) external;

    // ── GDA resale of pool inventory ──
    /// @notice onlyPool: a continuous GDA over backstop inventory the pool transferred here (F-4.5e).
    function startGda(
        bytes32 assetId,
        address token,
        uint256 qty,
        uint256 k,
        uint256 decay,
        uint256 emissionPerSec
    ) external returns (uint64 gdaId); // onlyPool
    /// @notice Buys the next `qty` units of a GDA at `gdaPrice` (≤ maxCost), only while the asset is REGULAR;
    ///        the proceeds go to the pool.
    function gdaBuy(uint64 gdaId, uint256 qty, uint256 maxCost) external returns (uint256 cost);
    /// @notice onlyPool: ends a GDA and returns the unsold tokens to the pool.
    function closeGda(uint64 gdaId) external returns (uint256 unsold);
    /// @notice Cost of the next `qty` GDA units in loan units: the continuous GDA price, floored at qty × (1
    ///        − κ) × V.
    function gdaPrice(uint64 gdaId, uint256 qty) external view returns (uint256);

    // ── views ──
    /// @notice Every REOPEN auction of a venue epoch is settled (settleEpoch precondition).
    function allReopenLotsSettled(bytes32 venue, uint64 epochId) external view returns (bool);
    /// @notice Every REOPEN auction of (asset, closure) cleared and settled (true when there was none).
    function reopenSettled(bytes32 assetId, uint64 closureId) external view returns (bool);
    /// @notice One auction's state, deadlines and results.
    function auction(uint64 auctionId) external view returns (Auction memory);
    /// @notice One bidder's bid in an auction.
    function bid(uint64 auctionId, address bidder) external view returns (Bid memory);
    /// @notice Every bidder of an auction, in bidding order.
    function bidders(uint64 auctionId) external view returns (address[] memory);
    /// @notice One GDA resale.
    function gda(uint64 gdaId) external view returns (Gda memory);
    /// @notice The id the next auction will get.
    function nextAuctionId() external view returns (uint64);
}
