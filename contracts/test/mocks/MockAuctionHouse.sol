// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AuctionKind} from "../../src/libraries/Types.sol";
import {ICredenceMarket} from "../../src/interfaces/ICredenceMarket.sol";

/// @notice Stand-in for the S3 AuctionHouse: one lot per (kind, market, closure), and test hooks to fix the lot and
///         clear it at a chosen blended price (paying the proceeds with tokens the test funds it with).
contract MockAuctionHouse {
    ICredenceMarket public market;
    uint64 public nextId = 1;
    mapping(bytes32 => uint64) public idOf;
    mapping(uint64 => bool) public settled;
    mapping(uint64 => uint256) public lotQty;
    bytes32[] internal keys;

    function setMarket(address m) external {
        market = ICredenceMarket(m);
    }

    function getOrCreate(AuctionKind k, bytes32 marketId, bytes32 assetId, uint64 closureId)
        external
        returns (uint64 id)
    {
        require(msg.sender == address(market), "only market");
        bytes32 key = keccak256(abi.encode(k, marketId, assetId, closureId));
        id = idOf[key];
        if (id == 0) {
            id = nextId++;
            idOf[key] = id;
            keys.push(key);
        }
    }

    /// @dev v2: a full lot hands new positions to a fresh tranche (the key now maps to it).
    function nextTranche(uint64 id) external returns (uint64 t) {
        require(msg.sender == address(market), "only market");
        t = nextId++;
        for (uint256 i; i < keys.length; ++i) {
            if (idOf[keys[i]] == id) idOf[keys[i]] = t;
        }
    }

    function fix(uint64 id) external returns (uint256 q) {
        q = market.releaseLots(id);
        lotQty[id] = q;
    }

    /// @dev Clears at `blendedPrice` (WAD per token): proceeds = value(q, p̄) in loan units, paid from this contract.
    function clearAt(uint64 id, uint256 blendedPrice, IERC20 loan, uint8 collDec, uint8 loanDec)
        external
        returns (uint256 proceeds)
    {
        proceeds = lotQty[id] * blendedPrice * 10 ** loanDec / (10 ** collDec * 1e18);
        loan.approve(address(market), proceeds);
        market.onAuctionCleared(id, proceeds, blendedPrice);
    }

    function lotSettled(uint64 id) external {
        require(msg.sender == address(market), "only market");
        settled[id] = true;
    }
}
