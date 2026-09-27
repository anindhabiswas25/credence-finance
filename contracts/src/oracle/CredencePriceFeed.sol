// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Report, ReportKind, FeedMarketStatus} from "../libraries/Types.sol";
import {ICredencePriceFeed} from "../interfaces/ICredencePriceFeed.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {INavSource} from "../interfaces/INavSource.sol";

/// @title CredencePriceFeed: signed push feed written by a relayer committee (Build Guide §8.3.1, §10.1).
/// @notice Two independent deployments on testnet (vendor A primary, vendor B secondary) plus one for NAV.
///         Large moves are NOT rejected (real crashes happen); cross-feed checks in the OracleAdapter handle bad
///         data. See ICredencePriceFeed for the exact EIP-712 encoding (ADR-0101 §1).
contract CredencePriceFeed is ICredencePriceFeed, EIP712 {
    /// @inheritdoc ICredencePriceFeed
    bytes32 public constant REPORTS_TYPEHASH = keccak256("Reports(bytes32 reportsHash)");
    /// @inheritdoc ICredencePriceFeed
    uint40 public constant MAX_FUTURE_SKEW = 5;
    /// @inheritdoc ICredencePriceFeed
    uint256 public constant RING_SIZE = 96;
    /// @notice An official open print may carry an exchange timestamp up to this much before the scheduled open.
    uint40 public constant OPEN_TOLERANCE = 60;

    address public immutable timelock;

    struct Obs {
        uint128 price;
        uint40 at;
    }

    struct AssetFeed {
        // slot 0
        uint64 seq;
        uint128 livePrice;
        uint40 liveAt;
        uint8 status;
        // slot 1
        uint128 regPrice;
        uint40 regAt;
        uint8 ringHead; // index of the newest observation
        uint8 ringCount;
        // slot 2
        uint128 closePrice;
        uint40 closeAt;
        uint40 closeSession;
        // slot 3
        uint128 nav;
        uint40 navAt;
        // slot 4
        uint128 prevNav;
        uint40 prevNavAt;
    }

    mapping(bytes32 asset => AssetFeed) internal _feeds;
    mapping(bytes32 asset => Obs[96]) internal _ring;
    mapping(bytes32 asset => mapping(uint40 sessionDay => Obs)) internal _opens;

    address[] internal _signers;
    mapping(address => bool) public isSigner;
    uint8 public threshold;

    constructor(address timelock_, address[] memory signers_, uint8 threshold_)
        EIP712("CredencePriceFeed", "1")
    {
        if (timelock_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
        _setCommittee(signers_, threshold_);
    }

    // ───────────────────────────── committee ─────────────────────────────

    /// @inheritdoc ICredencePriceFeed
    function setCommittee(address[] calldata signers, uint8 threshold_) external {
        if (msg.sender != timelock) revert Unauthorized();
        _setCommittee(signers, threshold_);
    }

    function _setCommittee(address[] memory signers, uint8 threshold_) internal {
        uint256 n = signers.length;
        if (n == 0 || threshold_ == 0 || threshold_ > n) revert InvalidCommittee();
        for (uint256 i; i < _signers.length; ++i) {
            isSigner[_signers[i]] = false;
        }
        delete _signers;
        address prev;
        for (uint256 i; i < n; ++i) {
            address s = signers[i];
            if (s <= prev) revert InvalidCommittee(); // non-zero, strictly ascending, no duplicates
            isSigner[s] = true;
            _signers.push(s);
            prev = s;
        }
        threshold = threshold_;
        emit CommitteeChanged(signers, threshold_);
    }

    /// @inheritdoc ICredencePriceFeed
    function committee() external view returns (address[] memory, uint8) {
        return (_signers, threshold);
    }

    // ───────────────────────────── submit ─────────────────────────────

    /// @inheritdoc ICredencePriceFeed
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @inheritdoc ICredencePriceFeed
    function hashReports(Report[] calldata reports) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(REPORTS_TYPEHASH, keccak256(abi.encode(reports)))));
    }

    /// @inheritdoc ICredencePriceFeed
    /// @custom:state any
    function submit(Report[] calldata reports, bytes[] calldata signatures) external {
        if (reports.length == 0) revert EmptyReports();
        _verify(hashReports(reports), signatures);
        for (uint256 i; i < reports.length; ++i) {
            _store(reports[i]);
        }
    }

    function _verify(bytes32 digest, bytes[] calldata signatures) internal view {
        uint256 count;
        address prev;
        for (uint256 i; i < signatures.length; ++i) {
            (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signatures[i]);
            if (err != ECDSA.RecoverError.NoError) revert InvalidSignature();
            if (rec <= prev) revert SignersNotSorted();
            if (!isSigner[rec]) revert UnknownSigner(rec);
            prev = rec;
            ++count;
        }
        if (count < threshold) revert NotEnoughSigners(count, threshold);
    }

    function _store(Report calldata r) internal {
        if (r.kind > ReportKind.STATUS) revert InvalidReportKind(r.kind);
        if (r.marketStatus > FeedMarketStatus.HALTED) revert InvalidMarketStatus(r.marketStatus);
        if (r.observedAt > block.timestamp + MAX_FUTURE_SKEW) {
            revert ReportFromFuture(r.observedAt, block.timestamp);
        }
        if (r.price == 0 && r.kind != ReportKind.STATUS) revert ZeroPrice();

        AssetFeed storage f = _feeds[r.assetId];
        if (r.seq <= f.seq) revert StaleReport(r.assetId, r.seq, f.seq);
        f.seq = r.seq;

        uint8 kind = r.kind;
        if (kind == ReportKind.LIVE) {
            // An out-of-order print (older than the stored live one) advances seq but is not stored.
            if (r.observedAt < f.liveAt) return;
            f.livePrice = r.price;
            f.liveAt = r.observedAt;
            f.status = r.marketStatus;
            if (r.marketStatus == FeedMarketStatus.REGULAR) {
                f.regPrice = r.price;
                f.regAt = r.observedAt;
            }
            _pushObs(r.assetId, f, r.price, r.observedAt);
        } else if (kind == ReportKind.OPEN) {
            _opens[r.assetId][r.sessionDate] = Obs(r.price, r.observedAt);
        } else if (kind == ReportKind.CLOSE) {
            if (r.sessionDate < f.closeSession) return; // an older session's close never replaces a newer one
            f.closePrice = r.price;
            f.closeAt = r.observedAt;
            f.closeSession = r.sessionDate;
        } else if (kind == ReportKind.NAV) {
            if (r.observedAt <= f.navAt) return; // NAV prints are strictly time-ordered
            f.prevNav = f.nav;
            f.prevNavAt = f.navAt;
            f.nav = r.price;
            f.navAt = r.observedAt;
        } else {
            // STATUS
            f.status = r.marketStatus;
        }
        emit ReportAccepted(r.assetId, kind, r.price, r.observedAt, r.seq, r.marketStatus);
    }

    function _pushObs(bytes32 asset, AssetFeed storage f, uint128 price, uint40 at) internal {
        Obs[96] storage ring = _ring[asset];
        if (f.ringCount != 0 && ring[f.ringHead].at == at) {
            ring[f.ringHead].price = price; // same timestamp: the later report wins
            return;
        }
        uint8 head = f.ringCount == 0 ? 0 : uint8((uint256(f.ringHead) + 1) % RING_SIZE);
        ring[head] = Obs(price, at);
        f.ringHead = head;
        if (f.ringCount < RING_SIZE) f.ringCount += 1;
    }

    // ───────────────────────────── IPriceSource ─────────────────────────────

    /// @inheritdoc IPriceSource
    function latest(bytes32 assetId)
        external
        view
        returns (uint256 price, uint40 observedAt, uint8 marketStatus)
    {
        AssetFeed storage f = _feeds[assetId];
        return (f.livePrice, f.liveAt, f.status);
    }

    /// @inheritdoc IPriceSource
    function officialOpen(bytes32 assetId, uint40 sessionOpen) external view returns (uint256, uint40, bool) {
        Obs memory o = _opens[assetId][sessionOpen / 1 days];
        bool ok = o.price != 0 && uint256(o.at) + OPEN_TOLERANCE >= sessionOpen;
        return (o.price, o.at, ok);
    }

    /// @inheritdoc IPriceSource
    function officialClose(bytes32 assetId) external view returns (uint256, uint40, uint40) {
        AssetFeed storage f = _feeds[assetId];
        return (f.closePrice, f.closeAt, f.closeSession);
    }

    /// @inheritdoc IPriceSource
    function lastRegular(bytes32 assetId) external view returns (uint256, uint40) {
        AssetFeed storage f = _feeds[assetId];
        return (f.regPrice, f.regAt);
    }

    /// @inheritdoc IPriceSource
    /// @dev Each observation holds its price from its timestamp until the next one (the newest until now).
    ///      ok = false unless some stored observation is at or before `now − window`. Rounded down.
    function twap(bytes32 assetId, uint32 window) external view returns (uint256 price, bool ok) {
        AssetFeed storage f = _feeds[assetId];
        uint256 count = f.ringCount;
        if (count == 0) return (0, false);
        Obs[96] storage ring = _ring[assetId];
        uint256 nowTs = block.timestamp;
        if (window == 0) return (ring[f.ringHead].price, true);
        if (nowTs < window) return (0, false);
        uint256 start = nowTs - window;

        uint256 acc;
        uint256 segEnd = nowTs;
        uint256 idx = f.ringHead;
        for (uint256 i; i < count; ++i) {
            Obs memory o = ring[idx];
            uint256 at = o.at > nowTs ? nowTs : o.at; // clamp the allowed 5 s future skew
            if (at <= start) {
                acc += uint256(o.price) * (segEnd - start);
                return (acc / window, true);
            }
            acc += uint256(o.price) * (segEnd - at);
            segEnd = at;
            idx = idx == 0 ? RING_SIZE - 1 : idx - 1;
        }
        return (0, false);
    }

    // ───────────────────────────── INavSource / views ─────────────────────────────

    /// @inheritdoc INavSource
    function latestNav(bytes32 assetId) external view returns (uint256, uint40, uint256, uint40) {
        AssetFeed storage f = _feeds[assetId];
        return (f.nav, f.navAt, f.prevNav, f.prevNavAt);
    }

    /// @inheritdoc ICredencePriceFeed
    function latestSeq(bytes32 assetId) external view returns (uint64) {
        return _feeds[assetId].seq;
    }

    /// @inheritdoc ICredencePriceFeed
    function observationCount(bytes32 assetId) external view returns (uint256) {
        return _feeds[assetId].ringCount;
    }

    /// @inheritdoc ICredencePriceFeed
    function observation(bytes32 assetId, uint256 i) external view returns (uint256, uint40) {
        AssetFeed storage f = _feeds[assetId];
        if (i >= f.ringCount) return (0, 0);
        uint256 idx = (uint256(f.ringHead) + RING_SIZE - i) % RING_SIZE;
        Obs memory o = _ring[assetId][idx];
        return (o.price, o.at);
    }
}
