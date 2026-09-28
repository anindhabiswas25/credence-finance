// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClockState, GuardianOverlay} from "../libraries/Types.sol";
import {ICredenceGuardian} from "../interfaces/ICredenceGuardian.sol";
import {ICredenceMarket} from "../interfaces/ICredenceMarket.sol";
import {IAssetClock} from "../interfaces/IAssetClock.sol";
import {GasGuard} from "../libraries/GasGuard.sol";

/// @title CredenceGuardian: emergency powers that can only make the protocol safer (Build Guide §8.11).
/// @notice Called by the Guardian Safe. Instant: pause borrowing, pause cover, halt an asset (≤ 7 days, renewable),
///         extend a closure (never shorten), raise a haircut (≤ 10 pp, expires after 7 days unless the timelock
///         confirms it through `setRiskParams`). Undoing a pause waits 6 hours, or is instant through the timelock.
///         Nothing else is in this contract (INV-GOV-01).
/// @dev `bytes32(0)` as a market id = every market of every wired market singleton. `pauseCover(market)` pauses
///      cover on every market of that singleton (its global overlay, id 0).
contract CredenceGuardian is ICredenceGuardian {
    uint40 public constant UNPAUSE_DELAY = 6 hours;
    uint40 public constant MAX_HALT = 7 days;
    uint40 public constant HAIRCUT_TTL = 7 days;
    uint64 public constant MAX_HAIRCUT_BPS = 1000;

    address public immutable safe;
    address public immutable timelock;
    address internal immutable deployer;

    address[] internal _markets;
    address public clock;

    mapping(bytes32 marketId => uint40) public unpauseBorrowAt;
    mapping(address target => uint40) public unpauseCoverAt;

    modifier onlySafe() {
        if (msg.sender != safe) revert Unauthorized();
        _;
    }

    constructor(address timelock_, address safe_) {
        if (timelock_ == address(0) || safe_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
        safe = safe_;
        deployer = msg.sender;
    }

    /// @inheritdoc ICredenceGuardian
    function initializeWiring(address[] calldata markets_, address clock_) external {
        if (msg.sender != deployer) revert Unauthorized();
        if (clock != address(0)) revert AlreadyWired();
        if (clock_ == address(0)) revert ZeroAddress();
        for (uint256 i; i < markets_.length; ++i) {
            if (markets_[i] == address(0)) revert ZeroAddress();
            _markets.push(markets_[i]);
        }
        clock = clock_;
        emit GuardianWired(markets_, clock_);
    }

    // ───────────── borrowing ─────────────

    /// @inheritdoc ICredenceGuardian
    function pauseBorrow(bytes32 marketId) external onlySafe {
        delete unpauseBorrowAt[marketId];
        _setBorrowPaused(marketId, true);
        emit BorrowPausedByGuardian(marketId);
    }

    /// @inheritdoc ICredenceGuardian
    function scheduleUnpauseBorrow(bytes32 marketId) external onlySafe {
        uint40 at = uint40(block.timestamp) + UNPAUSE_DELAY;
        unpauseBorrowAt[marketId] = at;
        emit UnpauseScheduled(marketId, at);
    }

    /// @inheritdoc ICredenceGuardian
    function executeUnpause(bytes32 marketId) external {
        if (msg.sender != timelock) {
            if (msg.sender != safe) revert Unauthorized();
            uint40 at = unpauseBorrowAt[marketId];
            if (at == 0) revert UnpauseNotScheduled(marketId);
            if (block.timestamp < at) revert UnpauseNotReady(marketId, at);
        }
        delete unpauseBorrowAt[marketId];
        _setBorrowPaused(marketId, false);
        emit BorrowUnpaused(marketId);
    }

    /// @inheritdoc ICredenceGuardian
    function raiseHaircut(bytes32 marketId, uint64 bps) external onlySafe {
        if (bps > MAX_HAIRCUT_BPS) revert HaircutTooLarge(bps, MAX_HAIRCUT_BPS);
        uint64 wad = bps * 1e14;
        uint40 until = uint40(block.timestamp) + HAIRCUT_TTL;
        bool applied;
        for (uint256 i; i < _markets.length; ++i) {
            ICredenceMarket m = ICredenceMarket(_markets[i]);
            if (!_has(m, marketId)) continue;
            GuardianOverlay memory o = m.overlay(marketId);
            uint64 current = o.haircutUntil > block.timestamp ? o.haircut : 0;
            if (wad <= current) revert HaircutNotHigher(bps, current / 1e14);
            o.haircut = wad;
            o.haircutUntil = until;
            m.applyOverlay(marketId, o);
            applied = true;
        }
        if (!applied) revert UnknownMarket(marketId);
        emit HaircutRaised(marketId, bps, until);
    }

    // ───────────── cover ─────────────

    /// @inheritdoc ICredenceGuardian
    function pauseCover(address target) external onlySafe {
        delete unpauseCoverAt[target];
        _setCoverPaused(target, true);
        emit CoverPaused(target);
    }

    /// @inheritdoc ICredenceGuardian
    function scheduleUnpauseCover(address target) external onlySafe {
        uint40 at = uint40(block.timestamp) + UNPAUSE_DELAY;
        unpauseCoverAt[target] = at;
        emit CoverUnpauseScheduled(target, at);
    }

    /// @inheritdoc ICredenceGuardian
    function executeUnpauseCover(address target) external {
        if (msg.sender != timelock) {
            if (msg.sender != safe) revert Unauthorized();
            uint40 at = unpauseCoverAt[target];
            if (at == 0) revert UnpauseNotScheduled(bytes32(uint256(uint160(target))));
            if (block.timestamp < at) revert UnpauseNotReady(bytes32(uint256(uint160(target))), at);
        }
        delete unpauseCoverAt[target];
        _setCoverPaused(target, false);
        emit CoverUnpaused(target);
    }

    // ───────────── clock ─────────────

    /// @inheritdoc ICredenceGuardian
    function haltAsset(bytes32 assetId, uint40 until) external onlySafe {
        _checkUntil(until);
        IAssetClock(clock).restrict(assetId, ClockState.HALTED, until);
        emit AssetHalted(assetId, until);
    }

    /// @inheritdoc ICredenceGuardian
    /// @dev The clock rejects anything that would shorten an active restriction (INV-CLK-02).
    function extendClosed(bytes32 assetId, uint40 until) external onlySafe {
        _checkUntil(until);
        IAssetClock(clock).restrict(assetId, ClockState.CLOSED, until);
        emit ClosedExtended(assetId, until);
    }

    /// @inheritdoc ICredenceGuardian
    function markets() external view returns (address[] memory) {
        return _markets;
    }

    // ───────────── internals ─────────────

    function _checkUntil(uint40 until) internal view {
        if (clock == address(0)) revert NotWired();
        if (until <= block.timestamp) revert UntilInPast(until);
        uint40 max = uint40(block.timestamp) + MAX_HALT;
        if (until > max) revert UntilTooLate(until, max);
    }

    function _setBorrowPaused(bytes32 marketId, bool paused) internal {
        bool applied;
        for (uint256 i; i < _markets.length; ++i) {
            ICredenceMarket m = ICredenceMarket(_markets[i]);
            if (!_has(m, marketId)) continue;
            GuardianOverlay memory o = m.overlay(marketId);
            o.borrowPaused = paused;
            m.applyOverlay(marketId, o);
            applied = true;
        }
        if (!applied) revert UnknownMarket(marketId);
    }

    function _setCoverPaused(address target, bool paused) internal {
        for (uint256 i; i < _markets.length; ++i) {
            if (_markets[i] != target) continue;
            ICredenceMarket m = ICredenceMarket(target);
            GuardianOverlay memory o = m.overlay(bytes32(0));
            o.coverPaused = paused;
            m.applyOverlay(bytes32(0), o);
            return;
        }
        revert UnknownMarket(bytes32(uint256(uint160(target))));
    }

    /// @dev id 0 (ALL) exists on every market singleton.
    function _has(ICredenceMarket m, bytes32 marketId) internal view returns (bool) {
        if (marketId == bytes32(0)) return true;
        uint256 g0 = gasleft();
        try m.marketParams(marketId) {
            return true;
        } catch {
            GasGuard.check(g0);
            return false;
        }
    }
}
