// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoverRequest} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";

/// @notice Stand-in for the S3 UnderwriterPool with the market-facing half of its interface: quotes a premium the
///         test injects, records policies, keeps credited fees / penalties, and pays shortfalls from its balance
///         (up to an optional free-cash limit). Money-flow convention (ADR-0107): the market pushes, then notifies.
contract MockUnderwriterPool {
    IERC20 public immutable token;
    address public market;
    uint256 public premium;
    uint256 public uAfter;
    bool public capacityFull;
    uint256 public freeCashLimit = type(uint256).max;

    uint64 public policies;
    uint256 public premiumsReceived;
    uint256 public riskFees;
    uint256 public penalties;
    uint256 public shortfallsPaid;
    CoverRequest internal _last;

    constructor(IERC20 token_) {
        token = token_;
    }

    function setMarket(address m) external {
        market = m;
    }

    function setPremium(uint256 p, uint256 u) external {
        premium = p;
        uAfter = u;
    }

    function setCapacityFull(bool f) external {
        capacityFull = f;
    }

    function setFreeCashLimit(uint256 l) external {
        freeCashLimit = l;
    }

    function previewCover(CoverRequest calldata) external view returns (uint256, uint256) {
        require(!capacityFull, "capacity");
        return (premium, uAfter);
    }

    /// @dev v2 protocol (ADR-0110): the pool quotes once and the market pays in the same transaction.
    function writeCover(CoverRequest calldata r, uint256 maxPremium) external returns (uint64, uint256) {
        require(msg.sender == market, "only market");
        require(!capacityFull, "capacity");
        if (premium > maxPremium) revert ICredenceErrors.PremiumAboveMax(premium, maxPremium);
        _last = r;
        premiumsReceived += premium;
        return (++policies, premium);
    }

    function lastRequest() external view returns (CoverRequest memory) {
        return _last;
    }

    function creditRiskFee(uint256 a) external {
        require(msg.sender == market, "only market");
        riskFees += a;
    }

    function creditPenalty(uint256 a) external {
        require(msg.sender == market, "only market");
        penalties += a;
    }

    function payShortfall(uint256 s) external returns (uint256 paid) {
        require(msg.sender == market, "only market");
        uint256 bal = token.balanceOf(address(this));
        paid = s < bal ? s : bal;
        if (paid > freeCashLimit) paid = freeCashLimit;
        shortfallsPaid += paid;
        token.transfer(market, paid);
    }
}
