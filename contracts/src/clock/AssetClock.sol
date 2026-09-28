// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {GasGuard} from "../libraries/GasGuard.sol";
import {
    ClockState,
    ClosureType,
    MarketKind,
    Session,
    AssetConfig,
    ClockData,
    Restriction,
    FeedHealth
} from "../libraries/Types.sol";
import {ClockLib} from "../libraries/ClockLib.sol";
import {IAssetClock} from "../interfaces/IAssetClock.sol";
import {ICalendarStore} from "../interfaces/ICalendarStore.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {ISequencerHealth} from "../interfaces/ISequencerHealth.sol";

/// @title AssetClock: what state is each asset's home market in right now? (Build Guide §8.2.2)
/// @notice State = the most restrictive of four independent inputs: calendar, oracle, guardian, corporate action.
///         Transitions are lazy: anyone may `poke`, and every money contract pokes first. Holds no funds.
/// @dev Invariants proven in test/invariant: INV-CLK-01 (closureId monotone, +1 per scheduled close),
///      INV-CLK-02 (guardian only restricts), INV-CLK-03 (one open print per closure), INV-FAIL-01 (fail closed).
contract AssetClock is IAssetClock {
    using ClockLib for ClockState;

    /// @notice R-20: a gap between observed pokes above this, during an open phase, extends the phase.
    uint40 public constant SEQ_GAP = 120;
    /// @notice R-20: grace added on top of the measured gap.
    uint40 public constant GRACE = 120;
    uint40 public constant BELL_WINDOW = 2 hours;
    uint40 public constant BELL_DEADLINE = 15 minutes;
    /// @notice Longest guardian restriction per call (renewable), §8.11.
    uint40 public constant MAX_RESTRICTION = 7 days;

    address public immutable timelock;
    address public immutable guardian;
    address public immutable calendar;
    address public immutable sequencerHealth;
    address public immutable deployer;

    address public oracle;
    address public auctionHouse;
    address public settlement;
    bool public wired;

    mapping(bytes32 asset => AssetConfig) internal _config;
    mapping(bytes32 asset => ClockData) internal _data;
    mapping(bytes32 asset => uint40) public closedUntil;
    mapping(bytes32 asset => uint40) public haltedUntil;

    constructor(address timelock_, address guardian_, address calendar_, address sequencerHealth_) {
        if (
            timelock_ == address(0) || guardian_ == address(0) || calendar_ == address(0)
                || sequencerHealth_ == address(0)
        ) revert ZeroAddress();
        timelock = timelock_;
        guardian = guardian_;
        calendar = calendar_;
        sequencerHealth = sequencerHealth_;
        deployer = msg.sender;
    }

    // ═════════════════════════════ governance / wiring ═════════════════════════════

    /// @inheritdoc IAssetClock
    function initializeWiring(address oracle_, address auctionHouse_, address settlement_) external {
        if (msg.sender != deployer) revert Unauthorized();
        if (wired) revert AlreadyWired();
        if (oracle_ == address(0)) revert ZeroAddress();
        wired = true;
        oracle = oracle_;
        auctionHouse = auctionHouse_;
        settlement = settlement_;
        emit WiringInitialized(oracle_, sequencerHealth, auctionHouse_, settlement_);
    }

    /// @inheritdoc IAssetClock
    function setOracle(address oracle_) external {
        if (msg.sender != timelock) revert Unauthorized();
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = oracle_;
        emit OracleSet(oracle_);
    }

    /// @inheritdoc IAssetClock
    /// @custom:state any (governance)
    function listAsset(bytes32 assetId, bytes32 venue, MarketKind kind) external {
        if (msg.sender != timelock) revert Unauthorized();
        if (_config[assetId].listed) revert AssetAlreadyListed(assetId);
        ICalendarStore cal = ICalendarStore(calendar);
        uint256 count = cal.sessionCount(venue);
        if (count == 0) revert UnknownVenue(venue);

        (uint256 idx, bool found) = cal.findSession(venue, uint40(block.timestamp));
        ClockData storage d = _data[assetId];
        if (found) {
            d.sessionCursor = uint32(idx);
            // Closures that ended before listing are not replayed; the one in progress (if any) is not tracked.
            d.closedSessions = cal.session(venue, idx).close > block.timestamp ? uint32(idx) : uint32(idx + 1);
        } else {
            d.sessionCursor = uint32(count - 1);
            d.closedSessions = uint32(count);
        }
        d.state = ClockState.CLOSED; // fail closed until the first poke
        _config[assetId] = AssetConfig({venue: venue, kind: kind, listed: true});
        emit AssetListed(assetId, venue, kind);
    }

    /// @inheritdoc IAssetClock
    /// @custom:state any
    function restrict(bytes32 assetId, ClockState s, uint40 until) external {
        if (msg.sender != guardian) revert Unauthorized();
        _cfgOf(assetId);
        if (s != ClockState.CLOSED && s != ClockState.HALTED) revert InvalidRestriction(s);
        uint40 maxUntil = uint40(block.timestamp) + MAX_RESTRICTION;
        if (until > maxUntil) revert RestrictionTooLong(until, maxUntil);
        uint40 current = s == ClockState.HALTED ? haltedUntil[assetId] : closedUntil[assetId];
        // Never shortens: a new restriction must end at or after the active one of the same kind, and in the future.
        if (until <= block.timestamp || until < current) revert RestrictionNotTighter(s, until, current);
        if (s == ClockState.HALTED) haltedUntil[assetId] = until;
        else closedUntil[assetId] = until;
        emit Restricted(assetId, s, until);
        _poke(assetId);
    }

    /// @inheritdoc IAssetClock
    /// @custom:state any
    function beginCorporateAction(bytes32 assetId) external {
        if (msg.sender != guardian && msg.sender != timelock) revert Unauthorized();
        _cfgOf(assetId);
        ClockData storage d = _data[assetId];
        if (d.corporateAction) revert CorporateActionActive(assetId);
        d.corporateAction = true;
        _poke(assetId);
        emit CorporateActionBegun(assetId, d.closureId);
    }

    /// @inheritdoc IAssetClock
    /// @custom:state CORP_ACTION
    function confirmCorporateAction(bytes32 assetId, uint256 newSharesPerToken) external {
        if (msg.sender != timelock) revert Unauthorized();
        _cfgOf(assetId);
        ClockData storage d = _data[assetId];
        if (!d.corporateAction) revert CorporateActionNotActive(assetId);
        IOracleAdapter(_oracle()).setSharesPerToken(assetId, newSharesPerToken);
        d.corporateAction = false;
        emit CorporateActionConfirmed(assetId, newSharesPerToken);
        _poke(assetId);
    }

    /// @inheritdoc IAssetClock
    /// @custom:state REOPEN
    function markReopenComplete(bytes32 assetId, uint64 closureId) external {
        if (msg.sender == address(0) || (msg.sender != auctionHouse && msg.sender != settlement)) {
            revert Unauthorized();
        }
        _cfgOf(assetId);
        ClockData storage d = _data[assetId];
        if (closureId > d.closureId) revert WrongClosure(d.closureId, closureId);
        if (closureId < d.closureId || !d.reopenPending) return; // stale or already complete: no-op
        if (d.openPrint == 0) revert ReopenNotPending(assetId);
        d.reopenPending = false;
        emit ReopenComplete(assetId, closureId);
        _poke(assetId);
    }

    // ═════════════════════════════ poke ═════════════════════════════

    /// @inheritdoc IAssetClock
    /// @custom:state any
    function poke(bytes32 assetId) external returns (ClockState) {
        return _poke(assetId);
    }

    /// @inheritdoc IAssetClock
    function pokeMany(bytes32[] calldata assetIds) external {
        for (uint256 i; i < assetIds.length; ++i) {
            _poke(assetIds[i]);
        }
    }

    struct Cal {
        ICalendarStore store;
        bytes32 venue;
        uint256 count;
        uint32 cursor;
        Session cur; // session at `cursor`
        uint40 coverageEnd;
    }

    function _poke(bytes32 a) internal returns (ClockState) {
        AssetConfig memory cfg = _cfgOf(a);
        IOracleAdapter orc = IOracleAdapter(_oracle());
        ClockData storage d = _data[a];
        uint40 nowTs = uint40(block.timestamp);

        // 1. Sequencer gap (R-20): only time after the scheduled reopen of a pending closure counts.
        uint40 prevSeen = ISequencerHealth(sequencerHealth).recordPoke();
        if (d.reopenPending && d.reopenAt != 0 && prevSeen != 0 && nowTs > d.reopenAt) {
            uint40 from = prevSeen > d.reopenAt ? prevSeen : d.reopenAt;
            uint40 gap = nowTs - from;
            if (gap > SEQ_GAP) {
                d.phaseExtension += gap + GRACE;
                emit PhaseExtended(gap);
            }
        }

        // 2. Advance the cursor and read the calendar state.
        Cal memory c = _loadCal(cfg.venue, d.sessionCursor, nowTs);
        d.sessionCursor = c.cursor;
        ClockState calState = _calState(c, nowTs);

        // 3. Scheduled closure start(s): exactly one per scheduled close, even if pokes were missed (INV-CLK-01).
        while (d.closedSessions < c.count) {
            uint32 idx = d.closedSessions;
            Session memory s = idx == c.cursor ? c.cur : c.store.session(c.venue, idx);
            if (nowTs < s.close) break;
            _openScheduledClosure(a, cfg.kind, orc, d, c, s, idx);
            d.closedSessions = idx + 1;
        }
        _refreshReference(a, cfg.kind, orc, d, c);

        // 4–6. Oracle, guardian and corporate-action inputs; the most restrictive wins (INV-FAIL-01).
        ClockState target = _target(
            a,
            cfg.kind,
            orc,
            d.reopenPending && _scheduled(d.closureType),
            d.refPrice,
            d.corporateAction,
            calState
        );

        // A non-calendar closure (halt, guardian, feed-closed, corporate action) also opens a closure.
        if (!d.reopenPending && target.rank() >= ClockState.CLOSED.rank()) {
            _openUnscheduledClosure(a, orc, d, c, nowTs);
        }

        // 7–8. Reopen: the first REGULAR after a closure waits for the open print, then holds REOPEN.
        if (d.reopenPending && target == ClockState.REGULAR) {
            if (d.openPrint == 0) {
                uint256 g = gasleft();
                try orc.openPrint(a, d.reopenAt, d.phaseExtension) returns (bool ok, uint256 p, bool fb) {
                    if (ok && p != 0 && p <= type(uint128).max) {
                        d.openPrint = uint128(p); // INV-CLK-03: written only here, only while 0
                        d.openPrintAt = nowTs;
                        emit OpenPrint(a, d.closureId, p, fb);
                    }
                } catch {
                    GasGuard.check(g);
                }
            }
            target = d.openPrint != 0 ? ClockState.REOPEN : ClockState.CLOSED;
        }

        // 9. Commit.
        if (target != d.state) {
            emit StateChanged(a, d.state, target, d.closureId);
            d.state = target;
        }

        // 10. Next scheduled close and its Bell times.
        uint40 nextClose = _nextClose(c, nowTs);
        d.nextCloseAt = nextClose;
        d.bellWindowAt = nextClose == 0 ? 0 : nextClose - BELL_WINDOW;
        d.bellAt = nextClose == 0 ? 0 : nextClose - BELL_DEADLINE;
        return target;
    }

    function _openScheduledClosure(
        bytes32 a,
        MarketKind kind,
        IOracleAdapter orc,
        ClockData storage d,
        Cal memory c,
        Session memory s,
        uint32 idx
    ) internal {
        uint64 cid = d.closureId + 1;
        d.closureId = cid;
        d.venueEpoch = idx;
        d.closureType = s.closureTypeAfter;
        d.closeAt = s.close;
        uint40 reopenAt = idx + 1 < c.count
            ? (idx + 1 == c.cursor ? c.cur.open : c.store.session(c.venue, idx + 1).open)
            : 0;
        d.reopenAt = reopenAt;
        d.reopenPending = true;
        d.openPrint = 0;
        d.openPrintAt = 0;
        d.phaseExtension = 0;
        (uint128 ref, uint40 rt) = _fetchRef(a, kind, orc, s.open);
        d.refPrice = ref;
        d.refTime = rt;
        emit ClosureStarted(a, cid, idx, s.closureTypeAfter, ref, reopenAt);
    }

    function _openUnscheduledClosure(
        bytes32 a,
        IOracleAdapter orc,
        ClockData storage d,
        Cal memory c,
        uint40 nowTs
    ) internal {
        uint64 cid = d.closureId + 1;
        d.closureId = cid;
        d.venueEpoch = c.cursor;
        ClosureType t = d.corporateAction ? ClosureType.CORP_ACTION : ClosureType.HALT;
        d.closureType = t;
        d.closeAt = nowTs;
        uint40 reopenAt;
        if (c.count != 0 && nowTs <= c.coverageEnd) {
            if (c.cur.open > nowTs) reopenAt = c.cur.open;
            else if (c.cursor + 1 < c.count) reopenAt = c.store.session(c.venue, c.cursor + 1).open;
        }
        d.reopenAt = reopenAt;
        d.reopenPending = true;
        d.openPrint = 0;
        d.openPrintAt = 0;
        d.phaseExtension = 0;
        uint128 ref;
        uint40 rt;
        uint256 g = gasleft();
        try orc.haltReferencePrice(a) returns (uint256 p, uint40 t_) {
            if (p <= type(uint128).max) (ref, rt) = (uint128(p), t_);
        } catch {
            GasGuard.check(g);
        }
        d.refPrice = ref;
        d.refTime = rt;
        emit ClosureStarted(a, cid, c.cursor, t, ref, reopenAt);
    }

    /// @dev While a scheduled closure's reference is provisional (the official CLOSE had not landed at the close)
    ///      or missing, adopt a newer regular-session close as soon as the oracle has one.
    function _refreshReference(
        bytes32 a,
        MarketKind kind,
        IOracleAdapter orc,
        ClockData storage d,
        Cal memory c
    ) internal {
        if (!d.reopenPending || d.openPrint != 0 || kind != MarketKind.EQUITY) return;
        ClosureType t = d.closureType;
        if (!_scheduled(t)) return;
        if (d.refTime >= d.closeAt) return; // final
        uint40 sessionOpen =
            d.venueEpoch == c.cursor ? c.cur.open : c.store.session(c.venue, d.venueEpoch).open;
        (uint128 ref, uint40 rt) = _fetchRef(a, kind, orc, sessionOpen);
        if (ref != 0 && rt > d.refTime) {
            d.refPrice = ref;
            d.refTime = rt;
            emit ReferenceUpdated(a, d.closureId, ref, rt);
        }
    }

    // ═════════════════════════════ shared state logic (poke + preview) ═════════════════════════════

    function _scheduled(ClosureType t) internal pure returns (bool) {
        return t == ClosureType.OVERNIGHT || t == ClosureType.WEEKEND || t == ClosureType.HOLIDAY_WEEKEND;
    }

    /// @dev Steps 4–6. Pure function of inputs + oracle views; used by both `poke` and `previewState`.
    /// @param inScheduledClosure A scheduled closure is pending: its reference close must exist (step 3).
    function _target(
        bytes32 a,
        MarketKind kind,
        IOracleAdapter orc,
        bool inScheduledClosure,
        uint128 refPrice,
        bool corporateAction,
        ClockState calState
    ) internal view returns (ClockState target) {
        target = calState.mostRestrictive(_oracleState(a, kind, orc, inScheduledClosure, refPrice, calState));
        target = target.mostRestrictive(_guardianState(a));
        if (corporateAction) target = ClockState.CORP_ACTION;
    }

    /// @dev Step 4. A failing oracle is HALTED (fail closed).
    ///      A HALT / CORP_ACTION closure without a reference is not held HALTED by this rule: its valuation already
    ///      fails closed (`NoReferencePrice`), and holding it would stop it from ever reaching REOPEN.
    function _oracleState(
        bytes32 a,
        MarketKind kind,
        IOracleAdapter orc,
        bool inScheduledClosure,
        uint128 refPrice,
        ClockState calState
    ) internal view returns (ClockState s) {
        FeedHealth memory h;
        uint256 g = gasleft();
        try orc.feedHealth(a) returns (FeedHealth memory x) {
            h = x;
        } catch {
            GasGuard.check(g);
            return ClockState.HALTED;
        }
        s = calState;
        if (kind == MarketKind.EQUITY) {
            bool open = calState != ClockState.CLOSED;
            if (h.statusHalted || h.issuerFrozen || (open && (h.stale || h.severeDisagreement))) {
                return ClockState.HALTED;
            }
            // §8.2.2 step 3: a closure without a valid regular-session reference is HALTED.
            if (inScheduledClosure && refPrice == 0) return ClockState.HALTED;
            if (open && h.statusClosed) s = ClockState.CLOSED;
        } else {
            if (h.navInvalid || h.issuerFrozen) return ClockState.HALTED;
            if (h.stale) s = s.mostRestrictive(ClockState.CLOSED);
        }
    }

    /// @dev Step 5.
    function _guardianState(bytes32 a) internal view returns (ClockState) {
        if (haltedUntil[a] > block.timestamp) return ClockState.HALTED;
        if (closedUntil[a] > block.timestamp) return ClockState.CLOSED;
        return ClockState.REGULAR;
    }

    function _fetchRef(bytes32 a, MarketKind kind, IOracleAdapter orc, uint40 sessionOpen)
        internal
        view
        returns (uint128, uint40)
    {
        uint256 g = gasleft();
        try orc.lastRegularClose(a) returns (uint256 p, uint40 t) {
            if (p == 0 || p > type(uint128).max) return (0, 0);
            if (kind == MarketKind.EQUITY && t < sessionOpen) return (0, 0); // must belong to this session
            return (uint128(p), t);
        } catch {
            GasGuard.check(g);
            return (0, 0);
        }
    }

    // ═════════════════════════════ calendar helpers ═════════════════════════════

    function _loadCal(bytes32 venue, uint32 cursor, uint40 nowTs) internal view returns (Cal memory c) {
        c.store = ICalendarStore(calendar);
        c.venue = venue;
        c.count = c.store.sessionCount(venue);
        if (c.count == 0) return c;
        if (cursor >= c.count) cursor = uint32(c.count - 1);
        Session memory s = c.store.session(venue, cursor);
        // §8.2.2 step 2: while now ≥ sessions[cursor].extClose and cursor+1 < count: cursor++
        while (nowTs >= s.extClose && cursor + 1 < c.count) {
            cursor += 1;
            s = c.store.session(venue, cursor);
        }
        c.cursor = cursor;
        c.cur = s;
        c.coverageEnd = cursor + 1 == c.count ? s.close : c.store.coverageEnd(venue);
    }

    function _calState(Cal memory c, uint40 nowTs) internal pure returns (ClockState) {
        if (c.count == 0 || nowTs > c.coverageEnd) return ClockState.CLOSED;
        Session memory s = c.cur;
        if (nowTs >= s.open && nowTs < s.close) return ClockState.REGULAR;
        if ((nowTs >= s.extOpen && nowTs < s.open) || (nowTs >= s.close && nowTs < s.extClose)) {
            return ClockState.EXTENDED;
        }
        return ClockState.CLOSED;
    }

    function _nextClose(Cal memory c, uint40 nowTs) internal view returns (uint40) {
        if (c.count == 0 || nowTs > c.coverageEnd) return 0;
        if (nowTs < c.cur.close) return c.cur.close;
        if (c.cursor + 1 < c.count) return c.store.session(c.venue, c.cursor + 1).close;
        return 0;
    }

    /// @dev The closure between session j−1's close and session j's open, j = first session with open > now.
    function _closureWindow(Cal memory c, uint40 nowTs)
        internal
        view
        returns (uint40 closeAt, uint40 reopenAt, ClosureType t)
    {
        if (c.count == 0) return (0, 0, ClosureType.NONE);
        uint256 j = nowTs < c.cur.open ? c.cursor : uint256(c.cursor) + 1;
        if (j > 0) {
            Session memory prev = j - 1 == c.cursor ? c.cur : c.store.session(c.venue, j - 1);
            closeAt = prev.close;
            t = prev.closureTypeAfter;
        }
        if (j < c.count) reopenAt = c.store.session(c.venue, j).open;
    }

    function _cfgOf(bytes32 a) internal view returns (AssetConfig memory cfg) {
        cfg = _config[a];
        if (!cfg.listed) revert AssetNotListed(a);
    }

    function _oracle() internal view returns (address o) {
        o = oracle;
        if (o == address(0)) revert NotWired();
    }

    // ═════════════════════════════ views ═════════════════════════════

    /// @inheritdoc IAssetClock
    function state(bytes32 assetId) external view returns (ClockState) {
        _cfgOf(assetId);
        return _data[assetId].state;
    }

    /// @inheritdoc IAssetClock
    function closureInfo(bytes32 assetId) external view returns (ClockData memory) {
        return _data[assetId];
    }

    /// @inheritdoc IAssetClock
    function assetConfig(bytes32 assetId) external view returns (AssetConfig memory) {
        return _config[assetId];
    }

    /// @inheritdoc IAssetClock
    function calendarState(bytes32 assetId) public view returns (ClockState) {
        AssetConfig memory cfg = _cfgOf(assetId);
        uint40 nowTs = uint40(block.timestamp);
        return _calState(_loadCal(cfg.venue, _data[assetId].sessionCursor, nowTs), nowTs);
    }

    /// @inheritdoc IAssetClock
    /// @dev Simulates steps 2–8 without writes. The phase extension and the oracle's view of the closure are the
    ///      stored ones, so a poke that opens a new closure in this block may differ in the open-print step.
    function previewState(bytes32 assetId) external view returns (ClockState) {
        AssetConfig memory cfg = _cfgOf(assetId);
        IOracleAdapter orc = IOracleAdapter(_oracle());
        ClockData memory d = _data[assetId];
        uint40 nowTs = uint40(block.timestamp);
        Cal memory c = _loadCal(cfg.venue, d.sessionCursor, nowTs);
        ClockState calState = _calState(c, nowTs);

        // step 3 (simulated): the latest scheduled close that poke would process
        uint256 idx = d.closedSessions;
        bool opened;
        Session memory last;
        while (idx < c.count) {
            Session memory s = idx == c.cursor ? c.cur : c.store.session(c.venue, idx);
            if (nowTs < s.close) break;
            last = s;
            opened = true;
            ++idx;
        }
        if (opened) {
            d.reopenPending = true;
            d.openPrint = 0;
            d.closureType = last.closureTypeAfter;
            (d.refPrice,) = _fetchRef(assetId, cfg.kind, orc, last.open);
        } else if (
            d.reopenPending && d.openPrint == 0 && d.refTime < d.closeAt && cfg.kind == MarketKind.EQUITY
                && d.closureType != ClosureType.HALT && d.closureType != ClosureType.CORP_ACTION
        ) {
            Session memory s = c.store.session(c.venue, d.venueEpoch);
            (uint128 ref,) = _fetchRef(assetId, cfg.kind, orc, s.open);
            if (ref != 0) d.refPrice = ref;
        }

        ClockState target = _target(
            assetId,
            cfg.kind,
            orc,
            d.reopenPending && _scheduled(d.closureType),
            d.refPrice,
            d.corporateAction,
            calState
        );
        if (!d.reopenPending && target.rank() >= ClockState.CLOSED.rank()) {
            d.reopenPending = true;
            d.openPrint = 0;
        }
        if (d.reopenPending && target == ClockState.REGULAR) {
            if (d.openPrint == 0) {
                uint256 g = gasleft();
                try orc.openPrint(assetId, d.reopenAt, d.phaseExtension) returns (bool ok, uint256 p, bool) {
                    if (ok && p != 0) d.openPrint = uint128(p);
                } catch {
                    GasGuard.check(g);
                }
            }
            target = d.openPrint != 0 ? ClockState.REOPEN : ClockState.CLOSED;
        }
        return target;
    }

    /// @inheritdoc IAssetClock
    function isBellWindow(bytes32 assetId) external view returns (bool) {
        (uint40 nextClose, uint40 nowTs) = _viewNextClose(assetId);
        return nextClose != 0 && nowTs >= nextClose - BELL_WINDOW && nowTs < nextClose;
    }

    /// @inheritdoc IAssetClock
    function isAfterBellDeadline(bytes32 assetId) external view returns (bool) {
        (uint40 nextClose, uint40 nowTs) = _viewNextClose(assetId);
        return nextClose != 0 && nowTs >= nextClose - BELL_DEADLINE && nowTs < nextClose;
    }

    function _viewNextClose(bytes32 assetId) internal view returns (uint40 nextClose, uint40 nowTs) {
        AssetConfig memory cfg = _cfgOf(assetId);
        nowTs = uint40(block.timestamp);
        nextClose = _nextClose(_loadCal(cfg.venue, _data[assetId].sessionCursor, nowTs), nowTs);
    }

    /// @inheritdoc IAssetClock
    function closureWindow(bytes32 assetId)
        public
        view
        returns (uint40 closeAt, uint40 reopenAt, ClosureType t)
    {
        AssetConfig memory cfg = _cfgOf(assetId);
        uint40 nowTs = uint40(block.timestamp);
        return _closureWindow(_loadCal(cfg.venue, _data[assetId].sessionCursor, nowTs), nowTs);
    }

    /// @inheritdoc IAssetClock
    function closureDays(bytes32 assetId) external view returns (uint256) {
        (uint40 closeAt, uint40 reopenAt,) = closureWindow(assetId);
        if (closeAt == 0 || reopenAt <= closeAt) revert ClosureOpenEnded(assetId); // also covers reopenAt == 0
        return (uint256(reopenAt - closeAt) + 1 days - 1) / 1 days;
    }

    /// @inheritdoc IAssetClock
    function restriction(bytes32 assetId) external view returns (Restriction memory r) {
        uint40 h = haltedUntil[assetId];
        if (h > block.timestamp) return Restriction(ClockState.HALTED, h);
        uint40 cl = closedUntil[assetId];
        if (cl > block.timestamp) return Restriction(ClockState.CLOSED, cl);
        return Restriction(ClockState.REGULAR, 0);
    }
}
