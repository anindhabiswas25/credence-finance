// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {
    ClockState,
    ClockData,
    ClosureType,
    MarketKind,
    FeedHealth,
    OracleConfig,
    FeedMarketStatus
} from "../libraries/Types.sol";
import {WadMath} from "../libraries/WadMath.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {INavSource} from "../interfaces/INavSource.sol";
import {ITwapSource} from "../interfaces/ITwapSource.sol";
import {IAssetClock} from "../interfaces/IAssetClock.sol";
import {ICollateralToken} from "../interfaces/ICollateralToken.sol";
import {IScaledUIAmount} from "../interfaces/IScaledUIAmount.sol";
import {INavFund} from "../interfaces/INavFund.sol";
import {ICalendarStore} from "../interfaces/ICalendarStore.sol";
import {GasGuard} from "../libraries/GasGuard.sol";

/// @title OracleAdapter: one valuation price per asset, by clock state (Build Guide §8.3.2, F-3.2).
/// @notice Core rule: when the home market is shut, an off-hours price can lower a collateral's value but never
///         raise it (INV-ORA-01). All returned prices are WAD USD per whole TOKEN = share price × sharesPerToken.
/// @dev Holds no funds. Replaceable through the timelock (R-21).
contract OracleAdapter is IOracleAdapter {
    using WadMath for uint256;

    uint256 internal constant WAD = 1e18;

    // ── thresholds (§3.2, §12.2) ──
    uint256 public constant STALE_REGULAR = 60;
    uint256 public constant STALE_EXTENDED = 300;
    uint256 public constant DISAGREE = 0.015e18;
    uint256 public constant SEVERE = 0.05e18;
    /// @dev Unused since R-23 (NAV freshness counts USBANK strikes, not hours). Kept so the v1 ABI stays additive.
    uint256 public constant NAV_FRESH = 26 hours;
    /// @dev Unused since R-23. Kept so the v1 ABI stays additive.
    uint256 public constant NAV_HALT = 50 hours;
    uint256 public constant NAV_MAX_DROP = 0.005e18;
    /// @notice R-23: a USBANK strike (session `close`, 17:00 ET) counts as missed this long after it passed.
    uint256 public constant NAV_GRACE = 6 hours;
    uint256 public constant OPEN_WAIT = 15 minutes;
    uint32 public constant OPEN_TWAP = 5 minutes;
    uint32 public constant EXT_TWAP = 30 minutes;
    uint32 public constant DEX_TWAP = 1 hours;
    uint256 public constant STRESS_RATIO = 0.9e18;
    uint256 public constant MAX_RATIO_CHANGE = 10;
    /// @notice ERC-8056 (ADR-0119): a multiplier step up to 2 % (a dividend) is applied at the next sync; a larger one is
    ///         a corporate action.
    uint256 public constant MULTIPLIER_AUTO_STEP = 0.02e18;
    /// @notice A scheduled large multiplier update puts the asset in CORP_ACTION this long before its `effectiveAt`.
    uint256 public constant MULTIPLIER_LEAD = 1 days;
    /// @notice A large step is cached only if the token price it implies stays within half the step (at most this) of
    ///         the corporate-action closure's reference: a print that still carries the old share price fails it.
    uint256 public constant MULTIPLIER_MAX_GAP = 0.25e18;

    address public immutable timelock;
    address public immutable deployer;
    address public clock;

    mapping(bytes32 asset => OracleConfig) internal _config;

    constructor(address timelock_) {
        if (timelock_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
        deployer = msg.sender;
    }

    // ───────────────────────────── governance / wiring ─────────────────────────────

    /// @inheritdoc IOracleAdapter
    function setClock(address clock_) external {
        if (msg.sender != deployer) revert Unauthorized();
        if (clock != address(0)) revert AlreadyWired();
        if (clock_ == address(0)) revert ZeroAddress();
        clock = clock_;
        emit ClockSet(clock_);
    }

    /// @inheritdoc IOracleAdapter
    function setAssetConfig(
        bytes32 assetId,
        address primary,
        address secondary,
        address dex,
        address token,
        MarketKind kind,
        uint128 minDepth
    ) external {
        if (msg.sender != timelock) revert Unauthorized();
        if (primary == address(0) || token == address(0)) revert ZeroAddress();
        // Equity prices must be cross-checked: without a secondary the open print could never be confirmed.
        if (kind == MarketKind.EQUITY && secondary == address(0)) revert ZeroAddress();
        OracleConfig storage c = _config[assetId];
        if (c.listed && (c.kind != kind || c.token != token)) revert InvalidParam();
        if (!c.listed) {
            (uint256 spt,,,) = _tokenMultiplier(token, 0);
            if (spt == 0 || spt > type(uint128).max) revert InvalidParam();
            c.sharesPerToken = uint128(spt);
            c.listed = true;
            c.kind = kind;
            c.token = token;
        }
        c.primary = primary;
        c.secondary = secondary;
        c.dex = dex;
        c.minDepth = minDepth;
        emit AssetSourcesSet(assetId, c);
    }

    /// @inheritdoc IOracleAdapter
    function setSharesPerToken(bytes32 assetId, uint256 newSharesPerToken) external {
        if (msg.sender != clock) revert Unauthorized();
        OracleConfig storage c = _cfg(assetId);
        uint256 cur = c.sharesPerToken;
        if (
            newSharesPerToken == 0 || newSharesPerToken > type(uint128).max
                || newSharesPerToken > cur * MAX_RATIO_CHANGE || newSharesPerToken * MAX_RATIO_CHANGE < cur
        ) revert SharesPerTokenChangeTooLarge(cur, newSharesPerToken);
        c.sharesPerToken = uint128(newSharesPerToken);
        emit SharesPerTokenChanged(assetId, cur, newSharesPerToken);
    }

    // ───────────────────────────── ERC-8056 multiplier (ADR-0119) ─────────────────────────────

    /// @inheritdoc IOracleAdapter
    function multiplierState(bytes32 assetId)
        external
        view
        returns (uint256 cached, uint256 live, uint256 next, uint256 at, bool corporateAction)
    {
        OracleConfig storage c = _cfg(assetId);
        return _multiplierState(c);
    }

    /// @inheritdoc IOracleAdapter
    function syncMultiplier(bytes32 assetId) external returns (bool corporateAction) {
        OracleConfig storage c = _cfg(assetId);
        uint256 cached;
        uint256 live;
        uint256 at;
        (cached, live,, at, corporateAction) = _multiplierState(c);
        if (live == cached) return corporateAction;
        // a small step at once; a large one only after it took effect and both feeds printed since (price and
        // multiplier switch together); a large jump nobody scheduled waits for the timelock (confirmCorporateAction)
        bool ok = !_large(live, cached)
            || (at != 0
                && at <= block.timestamp
                && live <= cached * MAX_RATIO_CHANGE
                && live * MAX_RATIO_CHANGE >= cached
                && _printedSince(assetId, c, at)
                && _continuous(assetId, c, live, cached));
        if (!ok) return corporateAction;
        c.sharesPerToken = uint128(live);
        emit SharesPerTokenChanged(assetId, cached, live);
        (,,,, corporateAction) = _multiplierState(c);
    }

    function _multiplierState(OracleConfig storage c)
        internal
        view
        returns (uint256 cached, uint256 live, uint256 next, uint256 at, bool corporateAction)
    {
        cached = c.sharesPerToken;
        if (c.kind == MarketKind.NAV) return (cached, cached, 0, 0, false);
        (live, next, at,) = _tokenMultiplier(c.token, cached);
        corporateAction = _large(live, cached)
            || (next != 0
                && at > block.timestamp
                && at <= block.timestamp + MULTIPLIER_LEAD
                && _large(next, live));
    }

    /// @dev The token's multiplier: ERC-8056 `uiMultiplier` (else the v0 `sharesPerToken`, else `fallback_`), and its
    ///      pending update when the token has one. `ok` is false when the token exposes no multiplier.
    function _tokenMultiplier(address token, uint256 fallback_)
        internal
        view
        returns (uint256 live, uint256 next, uint256 at, bool ok)
    {
        live = fallback_;
        uint256 g = gasleft();
        try IScaledUIAmount(token).uiMultiplier() returns (uint256 m) {
            (live, ok) = (m, true);
        } catch {
            GasGuard.check(g);
            g = gasleft();
            try ICollateralToken(token).sharesPerToken() returns (uint256 m) {
                (live, ok) = (m, true);
            } catch {
                GasGuard.check(g);
            }
        }
        if (live == 0 || live > type(uint128).max) revert InvalidParam();
        g = gasleft();
        try IScaledUIAmount(token).newUIMultiplier() returns (uint256 m) {
            next = m;
        } catch {
            GasGuard.check(g);
            return (live, 0, 0, ok);
        }
        g = gasleft();
        try IScaledUIAmount(token).effectiveAt() returns (uint256 t) {
            at = t;
        } catch {
            GasGuard.check(g);
            next = 0;
        }
    }

    function _large(uint256 x, uint256 ref) internal pure returns (bool) {
        return x.relDiffUp(ref) > MULTIPLIER_AUTO_STEP;
    }

    /// @dev Both feeds' latest share prices × the new multiplier are within min(|Δ multiplier| / 2, 25 %) of the
    ///      reference (per token, old multiplier) of the closure the corporate action holds.
    function _continuous(bytes32 assetId, OracleConfig storage c, uint256 live, uint256 cached)
        internal
        view
        returns (bool)
    {
        uint256 ref = IAssetClock(clock).closureInfo(assetId).refPrice;
        if (ref == 0) return false;
        uint256 tol = live.relDiffUp(cached) / 2;
        if (tol > MULTIPLIER_MAX_GAP) tol = MULTIPLIER_MAX_GAP;
        (uint256 p1,,) = IPriceSource(c.primary).latest(assetId);
        (uint256 p2,,) = IPriceSource(c.secondary).latest(assetId);
        return p1.mulWadDown(live).relDiffUp(ref) <= tol && p2.mulWadDown(live).relDiffUp(ref) <= tol;
    }

    /// @dev Both feeds hold a live print observed at or after `t`.
    function _printedSince(bytes32 assetId, OracleConfig storage c, uint256 t) internal view returns (bool) {
        (uint256 p1, uint40 t1,) = IPriceSource(c.primary).latest(assetId);
        (uint256 p2, uint40 t2,) = IPriceSource(c.secondary).latest(assetId);
        return p1 != 0 && p2 != 0 && t1 >= t && t2 >= t;
    }

    // ───────────────────────────── valuation ─────────────────────────────

    /// @inheritdoc IOracleAdapter
    function valuationPrice(bytes32 assetId) external view returns (uint256 v) {
        OracleConfig storage c = _cfg(assetId);
        if (c.kind == MarketKind.NAV) {
            (uint256 nav,,,) = INavSource(c.primary).latestNav(assetId);
            if (nav == 0) revert NoPrice(assetId);
            return _tok(nav, c);
        }
        IAssetClock clk = IAssetClock(clock);
        ClockState st = clk.state(assetId);
        if (st == ClockState.REGULAR) return _livePrice(assetId, c);

        ClockData memory d = clk.closureInfo(assetId);
        if (st == ClockState.REOPEN) {
            if (d.openPrint == 0) revert NoPrice(assetId);
            return d.openPrint;
        }
        uint256 ref = d.refPrice;
        if (ref == 0) revert NoReferencePrice(assetId);
        if (st == ClockState.EXTENDED) {
            (uint256 t, bool ok) = IPriceSource(c.primary).twap(assetId, EXT_TWAP);
            if (ok && t != 0) return ref.min(_tok(t, c));
            (uint256 p,,) = IPriceSource(c.primary).latest(assetId);
            return p == 0 ? ref : ref.min(_tok(p, c));
        }
        if (st == ClockState.CLOSED || st == ClockState.HALTED) {
            (uint256 dexP, bool usable) = _dexTwap(c);
            return usable ? ref.min(dexP) : ref;
        }
        return ref; // CORP_ACTION
    }

    /// @inheritdoc IOracleAdapter
    function livePrice(bytes32 assetId) external view returns (uint256) {
        return _livePrice(assetId, _cfg(assetId));
    }

    function _livePrice(bytes32 assetId, OracleConfig storage c) internal view returns (uint256) {
        if (c.kind == MarketKind.NAV) {
            (uint256 nav,,,) = INavSource(c.primary).latestNav(assetId);
            if (nav == 0) revert NoPrice(assetId);
            return _tok(nav, c);
        }
        (uint256 p1,,) = IPriceSource(c.primary).latest(assetId);
        if (p1 == 0) revert NoPrice(assetId);
        (uint256 p2,,) = IPriceSource(c.secondary).latest(assetId);
        if (p2 != 0 && p1.relDiffUp(p2) > DISAGREE) p1 = p1.min(p2);
        return _tok(p1, c);
    }

    /// @inheritdoc IOracleAdapter
    function lastRegularClose(bytes32 assetId) external view returns (uint256 p, uint40 t) {
        OracleConfig storage c = _cfg(assetId);
        if (c.kind == MarketKind.NAV) {
            (uint256 nav, uint40 at,,) = INavSource(c.primary).latestNav(assetId);
            return (_tok(nav, c), at);
        }
        (p, t) = _lastRegularShare(assetId, c);
        p = _tok(p, c);
    }

    function _lastRegularShare(bytes32 assetId, OracleConfig storage c)
        internal
        view
        returns (uint256 p, uint40 t)
    {
        (uint256 cp, uint40 ct,) = IPriceSource(c.primary).officialClose(assetId);
        (uint256 rp, uint40 rt) = IPriceSource(c.primary).lastRegular(assetId);
        // The official closing print wins unless a newer regular-session print exists (the CLOSE report of today
        // has not landed yet).
        if (cp != 0 && ct >= rt) return (cp, ct);
        return (rp, rt);
    }

    /// @inheritdoc IOracleAdapter
    function haltReferencePrice(bytes32 assetId) external view returns (uint256 p, uint40 t) {
        OracleConfig storage c = _cfg(assetId);
        if (c.kind == MarketKind.NAV) {
            (uint256 nav, uint40 at,,) = INavSource(c.primary).latestNav(assetId);
            return (_tok(nav, c), at);
        }
        (p, t) = _lastRegularShare(assetId, c);
        (uint256 p1, uint40 t1,) = IPriceSource(c.primary).latest(assetId);
        (uint256 p2, uint40 t2,) = IPriceSource(c.secondary).latest(assetId);
        if (p1 != 0 && (p == 0 || p1 < p)) (p, t) = (p1, t1);
        if (p2 != 0 && (p == 0 || p2 < p)) (p, t) = (p2, t2);
        p = _tok(p, c);
    }

    // ───────────────────────────── open print ─────────────────────────────

    /// @inheritdoc IOracleAdapter
    function openPrint(bytes32 assetId, uint40 reopenAt, uint40 ext)
        external
        view
        returns (bool ok, uint256 p, bool fallbackUsed)
    {
        OracleConfig storage c = _cfg(assetId);
        ClockData memory d = IAssetClock(clock).closureInfo(assetId);
        if (c.kind == MarketKind.NAV) return _navOpen(assetId, c, d.closeAt);
        if (d.closureType == ClosureType.HALT || d.closureType == ClosureType.CORP_ACTION) {
            return _haltOpen(assetId, c, d.closeAt);
        }
        return _scheduledOpen(assetId, c, reopenAt, ext);
    }

    /// @dev REOPEN for a fund = the first valid NAV published after the closure started, not missing a strike
    ///      (Architecture §3.8, R-23).
    function _navOpen(bytes32 assetId, OracleConfig storage c, uint40 closeAt)
        internal
        view
        returns (bool, uint256, bool)
    {
        (uint256 nav, uint40 at, uint256 prev,) = INavSource(c.primary).latestNav(assetId);
        (bool stale, bool invalid) = _navStatus(assetId, nav, at, prev);
        if (at <= closeAt || stale || invalid) return (false, 0, false);
        return (true, _tok(nav, c), false);
    }

    /// @dev After a halt: the first fresh cross-checked regular-session price is the open print (§8.2.2 step 8).
    function _haltOpen(bytes32 assetId, OracleConfig storage c, uint40 closeAt)
        internal
        view
        returns (bool, uint256, bool)
    {
        (uint256 p1, uint40 t1, uint8 s1) = IPriceSource(c.primary).latest(assetId);
        (uint256 p2, uint40 t2, uint8 s2) = IPriceSource(c.secondary).latest(assetId);
        if (
            _freshRegular(p1, t1, s1, closeAt) && _freshRegular(p2, t2, s2, closeAt)
                && p1.relDiffUp(p2) <= DISAGREE
        ) {
            return (true, _tok(p1, c), false);
        }
        return (false, 0, false);
    }

    /// @dev Both official opens, agreeing within 1.5%; after 15 min + ext, the agreeing 5-minute TWAPs.
    function _scheduledOpen(bytes32 assetId, OracleConfig storage c, uint40 reopenAt, uint40 ext)
        internal
        view
        returns (bool, uint256, bool)
    {
        (uint256 o1,, bool ok1) = IPriceSource(c.primary).officialOpen(assetId, reopenAt);
        (uint256 o2,, bool ok2) = IPriceSource(c.secondary).officialOpen(assetId, reopenAt);
        if (ok1 && ok2 && o1.relDiffUp(o2) <= DISAGREE) return (true, _tok(o1, c), false);
        if (block.timestamp < uint256(reopenAt) + OPEN_WAIT + ext) return (false, 0, false);
        // Fallback: 5-minute TWAPs. The window ends now ≥ reopenAt + 15 min, so it only holds prints from after
        // the scheduled open.
        return _twapOpen(assetId, c);
    }

    function _twapOpen(bytes32 assetId, OracleConfig storage c) internal view returns (bool, uint256, bool) {
        (uint256 w1, bool okA) = IPriceSource(c.primary).twap(assetId, OPEN_TWAP);
        (uint256 w2, bool okB) = IPriceSource(c.secondary).twap(assetId, OPEN_TWAP);
        if (okA && okB && w1 != 0 && w1.relDiffUp(w2) <= DISAGREE) return (true, _tok(w1, c), true);
        return (false, 0, false);
    }

    function _freshRegular(uint256 p, uint40 t, uint8 s, uint40 notBefore) internal view returns (bool) {
        return p != 0 && s == FeedMarketStatus.REGULAR && t >= notBefore && !_older(t, STALE_REGULAR);
    }

    // ───────────────────────────── health ─────────────────────────────

    /// @inheritdoc IOracleAdapter
    function feedHealth(bytes32 assetId) external view returns (FeedHealth memory h) {
        OracleConfig storage c = _cfg(assetId);
        if (c.kind == MarketKind.NAV) {
            (uint256 nav, uint40 at, uint256 prev,) = INavSource(c.primary).latestNav(assetId);
            (h.stale, h.navInvalid) = _navStatus(assetId, nav, at, prev);
            h.issuerFrozen = _fundGated(c.token);
            return h;
        }

        ClockState cal = IAssetClock(clock).calendarState(assetId);
        (uint256 p1, uint40 t1, uint8 s1) = IPriceSource(c.primary).latest(assetId);
        (uint256 p2, uint40 t2, uint8 s2) = IPriceSource(c.secondary).latest(assetId);

        if (cal != ClockState.CLOSED) {
            uint256 limit = cal == ClockState.REGULAR ? STALE_REGULAR : STALE_EXTENDED;
            bool stale1 = p1 == 0 || _older(t1, limit);
            bool stale2 = p2 == 0 || _older(t2, limit);
            h.stale = stale1;
            if (!stale1 && !stale2) {
                uint256 diff = p1.relDiffUp(p2);
                h.disagreement = diff > DISAGREE;
                h.severeDisagreement = diff > SEVERE;
            } else {
                // Cannot cross-check: pause borrowing (the primary's own staleness already HALTs).
                h.disagreement = true;
            }
            h.statusClosed = p1 != 0 && s1 == FeedMarketStatus.CLOSED;
        }
        h.statusHalted = s1 == FeedMarketStatus.HALTED || s2 == FeedMarketStatus.HALTED;
        h.issuerFrozen = _tokenFrozen(c.token);
    }

    /// @dev R-23. Freshness is counted in strikes of the asset's venue calendar (USBANK), not in hours, so weekends
    ///      and holidays never make a NAV stale. A strike is missed when its NAV_GRACE has passed and the latest NAV
    ///      was published before it. One missed strike → `stale` (the clock goes CLOSED); two → `navInvalid`
    ///      (HALTED), as is a one-step drop > NAV_MAX_DROP or no NAV at all.
    function _navStatus(bytes32 assetId, uint256 nav, uint40 at, uint256 prev)
        internal
        view
        returns (bool stale, bool invalid)
    {
        if (nav == 0) return (true, true);
        invalid = prev != 0 && nav < prev && (prev - nav).divWadUp(prev) > NAV_MAX_DROP;
        (uint40 lastStrike, uint40 strikeBefore) = _missableStrikes(assetId);
        if (at < strikeBefore) return (true, true);
        stale = at < lastStrike;
    }

    /// @dev The two most recent strikes (session closes) whose grace period has passed, newest first (0 = none).
    function _missableStrikes(bytes32 assetId)
        internal
        view
        returns (uint40 lastStrike, uint40 strikeBefore)
    {
        if (block.timestamp <= NAV_GRACE) return (0, 0);
        uint40 t = uint40(block.timestamp - NAV_GRACE);
        IAssetClock clk = IAssetClock(clock);
        ICalendarStore cal = ICalendarStore(clk.calendar());
        bytes32 venue = clk.assetConfig(assetId).venue;
        // n = number of sessions whose close < t (grace strictly over). findSession returns the first session with
        // extClose > t; its own close may already be < t (t inside its post-close window).
        (uint256 i, bool found) = cal.findSession(venue, t);
        uint256 n = !found ? cal.sessionCount(venue) : (cal.session(venue, i).close < t ? i + 1 : i);
        if (n >= 1) lastStrike = cal.session(venue, n - 1).close;
        if (n >= 2) strikeBefore = cal.session(venue, n - 2).close;
    }

    /// @dev A token whose probe reverts is treated as frozen (fail closed).
    function _tokenFrozen(address token) internal view returns (bool) {
        uint256 g0 = gasleft();
        try ICollateralToken(token).frozen() returns (bool f) {
            return f;
        } catch {
            GasGuard.check(g0);
            return true;
        }
    }

    function _fundGated(address token) internal view returns (bool) {
        uint256 g1 = gasleft();
        try INavFund(token).redemptionsGated() returns (bool g) {
            if (g) return true;
        } catch {
            GasGuard.check(g1);
            return true;
        }
        return _tokenFrozen(token);
    }

    /// @inheritdoc IOracleAdapter
    function stressFlag(bytes32 assetId) external view returns (bool) {
        OracleConfig storage c = _cfg(assetId);
        if (c.kind == MarketKind.NAV) return false;
        IAssetClock clk = IAssetClock(clock);
        ClockState st = clk.state(assetId);
        if (st != ClockState.CLOSED && st != ClockState.HALTED) return false;
        (uint256 dexP, bool usable) = _dexTwap(c);
        if (!usable) return false;
        uint256 ref = clk.closureInfo(assetId).refPrice;
        return ref != 0 && dexP < ref.mulWadDown(STRESS_RATIO);
    }

    /// @inheritdoc IOracleAdapter
    function dexTwap(bytes32 assetId) external view returns (uint256 p, bool usable) {
        return _dexTwap(_cfg(assetId));
    }

    /// @dev The DEX trades the token itself, so its price is already per token (no sharesPerToken).
    ///      Shallow pool (depth < minDepth), a failed read, or no pool → unusable.
    function _dexTwap(OracleConfig storage c) internal view returns (uint256 p, bool usable) {
        address dex = c.dex;
        if (dex == address(0)) return (0, false);
        uint256 g2 = gasleft();
        try ITwapSource(dex).twap(DEX_TWAP) returns (uint256 tp, bool ok) {
            if (!ok || tp == 0) return (0, false);
            p = tp;
        } catch {
            GasGuard.check(g2);
            return (0, false);
        }
        uint256 g3 = gasleft();
        try ITwapSource(dex).depth() returns (uint256 depthUsd) {
            usable = depthUsd >= c.minDepth;
        } catch {
            GasGuard.check(g3);
            usable = false;
        }
        if (!usable) p = 0;
    }

    // ───────────────────────────── views / helpers ─────────────────────────────

    /// @inheritdoc IOracleAdapter
    function sharesPerToken(bytes32 assetId) external view returns (uint256) {
        return _cfg(assetId).sharesPerToken;
    }

    /// @inheritdoc IOracleAdapter
    function config(bytes32 assetId) external view returns (OracleConfig memory) {
        return _config[assetId];
    }

    function _cfg(bytes32 assetId) internal view returns (OracleConfig storage c) {
        c = _config[assetId];
        if (!c.listed) revert NoPrice(assetId);
    }

    /// @dev share price → token price (rounded down).
    function _tok(uint256 sharePrice, OracleConfig storage c) internal view returns (uint256) {
        return sharePrice.mulWadDown(c.sharesPerToken);
    }

    /// @dev true if `t` is more than `limit` seconds old. A timestamp in the (allowed) future is fresh.
    function _older(uint40 t, uint256 limit) internal view returns (bool) {
        return block.timestamp > t && block.timestamp - t > limit;
    }
}
