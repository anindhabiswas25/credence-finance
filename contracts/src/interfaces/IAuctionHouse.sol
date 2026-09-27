// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AuctionKind, Auction} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {IAuctionHouseEvents} from "../libraries/Events.sol";

/// @title Uniform-price batch auctions for every liquidation (Build Guide §8.7). Implemented in S3.
/// @notice Commitment = keccak256(abi.encode(block.chainid, address(this), auctionId, msg.sender, qty, price, salt)).
interface IAuctionHouse is IAuctionHouseEvents, ICredenceErrors {
    function getOrCreate(AuctionKind k, bytes32 marketId, bytes32 assetId, uint64 closureId)
        external
        returns (uint64 auctionId); // onlyMarket
    function lotSettled(uint64 auctionId) external; // onlyMarket
    // keeper steps (permissionless, tipped)
    function fixLots(uint64 auctionId) external;
    function clear(uint64 auctionId) external;
    // sealed bidding (REOPEN)
    function commitBid(uint64 auctionId, bytes32 commitment, uint128 maxNotional) external; // bond = 10% × maxNotional (R-04)
    function revealBid(uint64 auctionId, uint128 qty, uint128 price, bytes32 salt) external;
    // open bidding (INTRADAY, EMERGENCY, PRECLOSE)
    function placeBid(uint64 auctionId, uint128 qty, uint128 price) external;
    // after clearing
    function claim(uint64 auctionId) external;
    // GDA resale of pool inventory
    function startGda(
        bytes32 assetId,
        address token,
        uint256 qty,
        uint256 k,
        uint256 decay,
        uint256 emissionPerSec
    ) external; // onlyPool
    function gdaBuy(uint64 gdaId, uint256 qty, uint256 maxCost) external;
    function gdaPrice(uint64 gdaId, uint256 qty) external view returns (uint256);
    // views
    function allReopenLotsSettled(bytes32 venue, uint64 epochId) external view returns (bool);
    function auction(uint64 auctionId) external view returns (Auction memory);
}
