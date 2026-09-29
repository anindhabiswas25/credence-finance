// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SolverLot} from "../libraries/Types.sol";
import {WadMath} from "../libraries/WadMath.sol";
import {ICompliance} from "../interfaces/ICompliance.sol";
import {ISolverAuction} from "../interfaces/ISolverVenue.sol";

/// @title SolverAuction: the native testnet venue for NAV settlements (Build Guide §8.8 step 2, ADR-0111).
/// @notice An ascending open auction per settlement among allowlisted solvers. A bid is firm: its whole payment
///         (qty × price) is escrowed, and only the best bid is held; an outbid solver is refunded at once. At the end
///         of the window the adapter finalizes: the best solver receives the tokens and the adapter the payment, or,
///         with no bid, the tokens return to the adapter (which falls back to the pool advance).
/// @dev Money flows: the adapter transfers the lot here before `open`; `finalize` pushes both legs. A refund whose push
///      fails (a blocklisted solver) is credited to `refundOwed` so it can never block a better bid.
contract SolverAuction is ISolverAuction, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Minimum raise over the best bid: 1.0001 × best (§8.8), in basis points of a basis point (1 + 1/10,000).
    uint256 public constant MIN_RAISE_BPS = 10_001;
    uint256 internal constant BPS = 10_000;

    address public immutable timelock;
    address public adapter;
    address public loanToken;
    uint8 internal _loanDec;

    mapping(address solver => bool) public isSolver;
    mapping(address solver => uint256) public refundOwed;
    mapping(uint64 settlementId => SolverLot) internal _lots;

    constructor(address timelock_) {
        if (timelock_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert Unauthorized();
        _;
    }

    modifier onlyAdapter() {
        if (msg.sender != adapter || adapter == address(0)) revert Unauthorized();
        _;
    }

    /// @inheritdoc ISolverAuction
    function initializeWiring(address adapter_, address loanToken_) external onlyTimelock {
        if (adapter != address(0)) revert AlreadyWired();
        if (adapter_ == address(0) || loanToken_ == address(0)) revert ZeroAddress();
        adapter = adapter_;
        loanToken = loanToken_;
        _loanDec = IERC20Metadata(loanToken_).decimals();
    }

    /// @inheritdoc ISolverAuction
    function setSolver(address solver, bool allowed) external onlyTimelock {
        if (solver == address(0)) revert ZeroAddress();
        isSolver[solver] = allowed;
        emit SolverSet(solver, allowed);
    }

    /// @notice onlyAdapter: opens the window of `settlementId` over the `qty` tokens the adapter just transferred.
    function open(uint64 settlementId, address token, uint256 qty, uint256 floorPrice, uint40 endsAt)
        external
        onlyAdapter
    {
        SolverLot storage l = _lots[settlementId];
        if (l.token != address(0)) revert InvalidParam();
        if (token == address(0)) revert ZeroAddress();
        if (qty == 0 || floorPrice == 0) revert ZeroAmount();
        if (qty > type(uint128).max || floorPrice > type(uint128).max || endsAt <= block.timestamp) {
            revert InvalidParam();
        }
        l.token = token;
        l.qty = uint128(qty);
        l.floorPrice = uint128(floorPrice);
        l.endsAt = endsAt;
        emit SolverWindowOpened(settlementId, token, qty, floorPrice, endsAt);
    }

    /// @inheritdoc ISolverAuction
    function bid(uint64 settlementId, uint256 price) external nonReentrant {
        SolverLot storage l = _lots[settlementId];
        if (l.token == address(0)) revert UnknownSettlement(settlementId);
        if (l.finalized || block.timestamp >= l.endsAt) revert TooLate(l.endsAt);
        if (!isSolver[msg.sender]) revert NotAllowlisted(msg.sender);
        if (!_canHold(l.token, msg.sender)) revert NotAllowlisted(msg.sender);
        uint256 min = _minBid(l);
        if (price < min) revert SolverBidTooLow(price, min);
        if (price > type(uint128).max) revert InvalidParam();
        uint256 escrow = _valueUp(l.qty, price, l.token);
        (address prev, uint256 prevEscrow) = (l.best, l.escrow);
        l.best = msg.sender;
        l.bestPrice = uint128(price);
        l.escrow = uint128(escrow);
        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), escrow);
        if (prev != address(0)) _refund(settlementId, prev, prevEscrow);
        emit SolverBid(settlementId, msg.sender, price);
    }

    /// @notice onlyAdapter, at or after `endsAt`. Filled: tokens → the best solver, escrow → the adapter.
    ///         No bid: tokens → the adapter. A winner that can no longer receive the tokens (it lost the fund's
    ///         allowlist during the window) voids its bid: it is refunded and the lot returns to the adapter, so a
    ///         settlement can never be stuck.
    function finalize(uint64 settlementId)
        external
        onlyAdapter
        nonReentrant
        returns (bool filled, uint256 proceeds)
    {
        SolverLot storage l = _lots[settlementId];
        if (l.token == address(0)) revert UnknownSettlement(settlementId);
        if (l.finalized) revert SettlementNotOpen(settlementId);
        if (block.timestamp < l.endsAt) revert TooEarly(l.endsAt);
        l.finalized = true;
        if (l.best != address(0)) {
            if (_tryTransfer(l.token, l.best, l.qty)) {
                proceeds = l.escrow;
                IERC20(loanToken).safeTransfer(msg.sender, proceeds);
                return (true, proceeds);
            }
            _refund(settlementId, l.best, l.escrow);
            (l.best, l.bestPrice, l.escrow) = (address(0), 0, 0);
        }
        IERC20(l.token).safeTransfer(msg.sender, l.qty);
    }

    /// @inheritdoc ISolverAuction
    function withdrawRefund() external nonReentrant returns (uint256 amount) {
        amount = refundOwed[msg.sender];
        if (amount == 0) revert NothingToClaim();
        refundOwed[msg.sender] = 0;
        IERC20(loanToken).safeTransfer(msg.sender, amount);
        emit RefundWithdrawn(msg.sender, amount);
    }

    // ───────────── views ─────────────

    /// @notice The best bid so far (solver 0 = none).
    function best(uint64 settlementId) external view returns (address solver, uint256 price) {
        SolverLot storage l = _lots[settlementId];
        return (l.best, l.bestPrice);
    }

    /// @inheritdoc ISolverAuction
    function lot(uint64 settlementId) external view returns (SolverLot memory) {
        return _lots[settlementId];
    }

    /// @inheritdoc ISolverAuction
    function minBid(uint64 settlementId) external view returns (uint256) {
        SolverLot storage l = _lots[settlementId];
        if (l.token == address(0)) revert UnknownSettlement(settlementId);
        return _minBid(l);
    }

    // ───────────── internals ─────────────

    function _minBid(SolverLot storage l) internal view returns (uint256) {
        if (l.best == address(0)) return l.floorPrice;
        uint256 raised = WadMath.mulDivUp(l.bestPrice, MIN_RAISE_BPS, BPS);
        return raised > l.floorPrice ? raised : l.floorPrice;
    }

    /// @dev qty × price in loan units, rounded up: the escrow a solver pays (§7.2: against the acting user).
    function _valueUp(uint256 qty, uint256 price, address token) internal view returns (uint256) {
        return WadMath.mulDivUp(qty, price * 10 ** _loanDec, 10 ** IERC20Metadata(token).decimals() * 1e18);
    }

    /// @dev Push the refund; if the token refuses (blocklist), credit it for `withdrawRefund`.
    function _refund(uint64 settlementId, address solver, uint256 amount) internal {
        bool pushed = _tryTransfer(loanToken, solver, amount);
        if (!pushed) refundOwed[solver] += amount;
        emit SolverRefunded(settlementId, solver, amount, pushed);
    }

    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }

    /// @dev §8.7.3 step 7: the fund's compliance hook, if it has one (a missing hook means an open token).
    function _canHold(address token, address a) internal view returns (bool) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(ICompliance.canHold, (a)));
        if (!ok || ret.length < 32) return true;
        return abi.decode(ret, (bool));
    }
}
