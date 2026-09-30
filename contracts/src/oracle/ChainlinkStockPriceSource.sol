// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {ICalendarStore} from "../interfaces/ICalendarStore.sol";
import {IScaledUIAmount} from "../interfaces/IScaledUIAmount.sol";
import {Session, FeedMarketStatus} from "../libraries/Types.sol";

/// @notice Chainlink `AggregatorV3Interface` (the proxy's view).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkStockPriceSource: an IPriceSource over Chainlink's Robinhood Stock Token feeds (ADR-0121).
/// @notice MAINNET ONLY (Chainlink lists these feeds on Robinhood Chain mainnet, chain 4663; the testnet keeps the
///         relayer feeds). A feed reports the token's total-return price = underlying price × the token's ERC-8056
///         multiplier, 8 decimals, 24/5, deviation 0.5 %, heartbeat 24 h, holding its last price while the market is
///         closed. This source returns WAD per SHARE (the IPriceSource unit): answer ÷ the token's live multiplier. The
///         token price is continuous across a corporate action, so the division stays right whether or not the feed
///         has updated since; the OracleAdapter multiplies back with its cached multiplier (ADR-0119).
///         - `latest`: a round younger than the feed's `maxAge` (its heartbeat) is current (observedAt = now): a
///           deviation-triggered feed is unchanged within 0.5 % until its next round. An older round keeps its own
///           time, so the adapter sees it stale. The market status comes from the venue calendar, not the feed.
///         - `officialOpen`: the first round within `OPEN_WINDOW` of the regular open; `officialClose` /
///           `lastRegular`: the round in force at the last regular close (ADR-0009 D1's rule: no official prints);
///           `twap`: time-weighted over rounds. Each walks back at most `MAX_WALK` rounds of the current phase.
contract ChainlinkStockPriceSource is IPriceSource {
    uint256 public constant MAX_WALK = 64;
    uint256 public constant OPEN_WINDOW = 30 minutes;
    uint256 internal constant WAD = 1e18;

    struct Feed {
        address aggregator;
        address token; // ERC-8056 multiplier
        uint32 maxAge; // the feed's heartbeat
        uint8 decimals;
    }

    address public immutable timelock;
    ICalendarStore public immutable calendar;
    bytes32 public immutable venue;
    mapping(bytes32 asset => Feed) public feeds;

    error Unauthorized();
    error InvalidFeed();

    event FeedSet(bytes32 indexed assetId, address aggregator, address token, uint32 maxAge);

    constructor(address timelock_, address calendar_, bytes32 venue_) {
        if (timelock_ == address(0) || calendar_ == address(0)) revert InvalidFeed();
        timelock = timelock_;
        calendar = ICalendarStore(calendar_);
        venue = venue_;
    }

    /// @notice onlyTimelock: wire an asset to its Chainlink proxy and its Stock Token.
    function setFeed(bytes32 assetId, address aggregator, address token, uint32 maxAge) external {
        if (msg.sender != timelock) revert Unauthorized();
        if (aggregator == address(0) || token == address(0) || maxAge == 0) revert InvalidFeed();
        uint8 d = IAggregatorV3(aggregator).decimals();
        if (d > 18) revert InvalidFeed();
        feeds[assetId] = Feed(aggregator, token, maxAge, d);
        emit FeedSet(assetId, aggregator, token, maxAge);
    }

    // ───────────── IPriceSource ─────────────

    /// @inheritdoc IPriceSource
    function latest(bytes32 assetId)
        external
        view
        returns (uint256 price, uint40 observedAt, uint8 marketStatus)
    {
        Feed memory f = feeds[assetId];
        marketStatus = _status();
        if (f.aggregator == address(0)) return (0, 0, marketStatus);
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(f.aggregator).latestRoundData();
        if (answer <= 0 || updatedAt == 0) return (0, 0, marketStatus);
        price = _perShare(f, answer);
        observedAt = block.timestamp - updatedAt <= f.maxAge ? uint40(block.timestamp) : uint40(updatedAt);
    }

    /// @inheritdoc IPriceSource
    function officialOpen(bytes32 assetId, uint40 sessionOpen) external view returns (uint256, uint40, bool) {
        Feed memory f = feeds[assetId];
        if (f.aggregator == address(0) || block.timestamp < sessionOpen) return (0, 0, false);
        (uint80 id, int256 ans, uint256 at) = _latest(f);
        uint256 end = uint256(sessionOpen) + OPEN_WINDOW;
        (uint256 bestP, uint40 bestAt) = (0, 0);
        for (uint256 i; i < MAX_WALK && at >= sessionOpen; ++i) {
            if (at < end && ans > 0) (bestP, bestAt) = (_perShare(f, ans), uint40(at));
            bool ok;
            (ok, id, ans, at) = _prev(f, id);
            if (!ok) break;
        }
        return (bestP, bestAt, bestP != 0);
    }

    /// @inheritdoc IPriceSource
    function officialClose(bytes32 assetId) external view returns (uint256 p, uint40 t, uint40 sessionDate) {
        uint40 close = _lastClose();
        if (close == 0) return (0, 0, 0);
        (p, t) = _atOrBefore(feeds[assetId], close);
        sessionDate = uint40(uint256(close) / 1 days);
    }

    /// @inheritdoc IPriceSource
    function lastRegular(bytes32 assetId) external view returns (uint256 p, uint40 t) {
        Feed memory f = feeds[assetId];
        if (_status() == FeedMarketStatus.REGULAR) {
            if (f.aggregator == address(0)) return (0, 0);
            (, int256 ans, uint256 at) = _latest(f);
            return ans > 0 ? (_perShare(f, ans), uint40(at)) : (0, 0);
        }
        uint40 close = _lastClose();
        if (close == 0) return (0, 0);
        return _atOrBefore(f, close);
    }

    /// @inheritdoc IPriceSource
    function twap(bytes32 assetId, uint32 window) external view returns (uint256, bool) {
        Feed memory f = feeds[assetId];
        if (f.aggregator == address(0)) return (0, false);
        (uint80 id, int256 ans, uint256 at) = _latest(f);
        if (ans <= 0) return (0, false);
        if (window == 0) return (_perShare(f, ans), true);
        if (block.timestamp < window) return (0, false);
        uint256 start = block.timestamp - window;
        uint256 segEnd = block.timestamp;
        uint256 acc;
        for (uint256 i; i < MAX_WALK; ++i) {
            uint256 from = at > start ? at : start;
            acc += _perShare(f, ans) * (segEnd - from);
            if (at <= start) return (acc / window, true);
            segEnd = at;
            bool ok;
            (ok, id, ans, at) = _prev(f, id);
            if (!ok || ans <= 0) break;
        }
        return (0, false); // history does not reach back over the whole window
    }

    // ───────────── internals ─────────────

    /// @dev answer (feed decimals, per token) → WAD per share, ÷ the token's live multiplier.
    function _perShare(Feed memory f, int256 answer) internal view returns (uint256) {
        uint256 m = IScaledUIAmount(f.token).uiMultiplier();
        if (m == 0) return 0;
        return uint256(answer) * 10 ** (18 - f.decimals) * WAD / m;
    }

    function _latest(Feed memory f) internal view returns (uint80 id, int256 ans, uint256 at) {
        (id, ans,, at,) = IAggregatorV3(f.aggregator).latestRoundData();
    }

    /// @dev The previous round of the same phase (the low 64 bits of a proxy round id are the aggregator round).
    function _prev(Feed memory f, uint80 id)
        internal
        view
        returns (bool ok, uint80 pid, int256 ans, uint256 at)
    {
        if (uint64(id) <= 1) return (false, 0, 0, 0);
        pid = id - 1;
        try IAggregatorV3(f.aggregator).getRoundData(pid) returns (
            uint80, int256 a, uint256, uint256 u, uint80
        ) {
            return (u != 0, pid, a, u);
        } catch {
            return (false, 0, 0, 0);
        }
    }

    /// @dev The round in force at `t` (the last one updated at or before it).
    function _atOrBefore(Feed memory f, uint40 t) internal view returns (uint256, uint40) {
        if (f.aggregator == address(0)) return (0, 0);
        (uint80 id, int256 ans, uint256 at) = _latest(f);
        for (uint256 i; i < MAX_WALK; ++i) {
            if (at <= t) return ans > 0 ? (_perShare(f, ans), uint40(at)) : (0, 0);
            bool ok;
            (ok, id, ans, at) = _prev(f, id);
            if (!ok) break;
        }
        return (0, 0);
    }

    /// @dev The close of the latest regular session that has closed (0 if none). `findSession` gives the first session
    ///      whose extended close is after now: its close, if passed (post-market), else the previous session's.
    function _lastClose() internal view returns (uint40) {
        uint256 n = calendar.sessionCount(venue);
        if (n == 0) return 0;
        (uint256 i, bool found) = calendar.findSession(venue, uint40(block.timestamp));
        if (!found) return calendar.session(venue, n - 1).close;
        uint40 c = calendar.session(venue, i).close;
        if (c <= block.timestamp) return c;
        return i == 0 ? 0 : calendar.session(venue, i - 1).close;
    }

    function _status() internal view returns (uint8) {
        (uint256 i, bool found) = calendar.findSession(venue, uint40(block.timestamp));
        if (!found) return FeedMarketStatus.CLOSED;
        Session memory s = calendar.session(venue, i);
        if (block.timestamp >= s.open && block.timestamp < s.close) return FeedMarketStatus.REGULAR;
        if (block.timestamp >= s.extOpen && block.timestamp < s.open) return FeedMarketStatus.PRE;
        if (block.timestamp >= s.close && block.timestamp < s.extClose) return FeedMarketStatus.POST;
        return FeedMarketStatus.CLOSED;
    }
}
