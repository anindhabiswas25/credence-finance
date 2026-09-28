// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {IAssetClock} from "../interfaces/IAssetClock.sol";
import {ClockState, FeedMarketStatus} from "../libraries/Types.sol";

/// @title RedStonePriceSource: an IPriceSource fed by RedStone signed data packages (BE-backend REQUEST 13:10).
/// @notice Clean-room implementation from the documented payload format (no RedStone connector code). A keeper
///         submits the gateway's packages; each asset's price is accepted when at least `threshold` distinct
///         authorised signers (3 of the 5 `redstone-primary-prod` nodes) signed the same timestamp, which must be at
///         most 180 s old and at most 60 s ahead of the block. The price is the median of the signed values (the mean
///         of the two middle ones for an even count), 8 decimals → WAD.
///         RedStone has no official OPEN / CLOSE prints: per ADR-0009 D1 (accepted for testnet only, flagged
///         `OracleFirstRegular`) the first print of a regular session is its open and the latest regular print is
///         the close. The session status comes from the venue calendar (`clock.calendarState`).
///         LOCAL / TESTNET ONLY: public use is gated on the user's ADR-0009 D3 (RedStone's written permission).
/// @dev Payload = packages ‖ packageCount (2 B) ‖ unsignedMetadata ‖ metadataSize (3 B) ‖ marker (9 B), parsed from
///      the end. Package = n × (feedId bytes32 ‖ value, valueByteSize bytes) ‖ timestampMs (6 B) ‖ valueByteSize
///      (4 B) ‖ n (3 B) ‖ signature (65 B, r ‖ s ‖ v). The signer is ecrecover over keccak256 of the package bytes
///      (everything before the signature), with no message prefix.
contract RedStonePriceSource is IPriceSource {
    bytes9 public constant MARKER = 0x000002ed57011e0000;
    uint256 public constant MAX_DELAY = 180;
    uint256 public constant MAX_AHEAD = 60;
    uint256 public constant OPEN_WINDOW = 30 minutes; // the first regular print within it is the session's open
    uint256 public constant RING_SIZE = 96;
    uint256 internal constant SIG_LEN = 65;
    uint256 internal constant MAX_PACKAGES = 64;

    struct Obs {
        uint128 price;
        uint40 at;
    }

    struct Feed {
        bytes32 feedId; // RedStone data feed id, e.g. "NVDA" left-aligned
        uint128 livePrice;
        uint40 liveAt;
        uint8 status;
        uint128 regPrice;
        uint40 regAt;
        uint8 ringHead;
        uint8 ringCount;
    }

    address public immutable timelock;
    IAssetClock public clock;
    uint8 public threshold;
    address[] internal _signers;
    mapping(address => bool) public isSigner;
    mapping(bytes32 asset => Feed) internal _feeds;
    mapping(bytes32 asset => Obs[96]) internal _ring;
    mapping(bytes32 asset => mapping(uint256 day => Obs)) internal _opens;

    error Unauthorized();
    error BadPayload(uint8 code);
    error NotEnoughSigners(bytes32 assetId, uint256 got, uint256 need);
    error TimestampMismatch(bytes32 assetId);
    error StaleData(bytes32 assetId, uint256 at, uint256 blockTime);
    error NotNewer(bytes32 assetId, uint256 at, uint256 stored);
    error UnknownAsset(bytes32 assetId);
    error InvalidCommittee();

    event PriceAccepted(
        bytes32 indexed assetId, uint256 price, uint40 observedAt, uint8 marketStatus, uint8 signers
    );
    event FeedSet(bytes32 indexed assetId, bytes32 feedId);
    event CommitteeChanged(address[] signers, uint8 threshold);
    event ClockSet(address clock);

    constructor(address timelock_, address[] memory signers_, uint8 threshold_) {
        if (timelock_ == address(0)) revert Unauthorized();
        timelock = timelock_;
        _setCommittee(signers_, threshold_);
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert Unauthorized();
        _;
    }

    // ───────────── governance ─────────────

    function setFeed(bytes32 assetId, bytes32 feedId) external onlyTimelock {
        _feeds[assetId].feedId = feedId;
        emit FeedSet(assetId, feedId);
    }

    function setCommittee(address[] calldata signers_, uint8 threshold_) external onlyTimelock {
        _setCommittee(signers_, threshold_);
    }

    /// @notice The clock whose venue calendar gives each print's session status (0 = every print is REGULAR).
    function setClock(address clock_) external onlyTimelock {
        clock = IAssetClock(clock_);
        emit ClockSet(clock_);
    }

    function _setCommittee(address[] memory signers_, uint8 threshold_) internal {
        if (threshold_ == 0 || threshold_ > signers_.length) revert InvalidCommittee();
        for (uint256 i; i < _signers.length; ++i) {
            isSigner[_signers[i]] = false;
        }
        for (uint256 i; i < signers_.length; ++i) {
            if (signers_[i] == address(0) || isSigner[signers_[i]]) revert InvalidCommittee();
            isSigner[signers_[i]] = true;
        }
        _signers = signers_;
        threshold = threshold_;
        emit CommitteeChanged(signers_, threshold_);
    }

    // ───────────── submission ─────────────

    /// @notice Verifies the payload and updates every asset of `assetIds` (permissionless).
    function submit(bytes calldata payload, bytes32[] calldata assetIds) external {
        Pkg[] memory pkgs = _parse(payload);
        for (uint256 a; a < assetIds.length; ++a) {
            _accept(assetIds[a], pkgs, payload);
        }
    }

    struct Pkg {
        address signer;
        uint256 timestampMs;
        uint256 dataStart; // offset of the first data point in the payload
        uint256 count;
        uint256 valueSize;
    }

    function _parse(bytes calldata p) internal pure returns (Pkg[] memory pkgs) {
        uint256 end = p.length;
        if (end < 14 || bytes9(p[end - 9:end]) != MARKER) revert BadPayload(1);
        end -= 9;
        uint256 metaSize = uint24(bytes3(p[end - 3:end]));
        end -= 3;
        if (end < metaSize + 2) revert BadPayload(2);
        end -= metaSize;
        uint256 n = uint16(bytes2(p[end - 2:end]));
        end -= 2;
        if (n == 0 || n > MAX_PACKAGES) revert BadPayload(3);
        pkgs = new Pkg[](n);
        for (uint256 i; i < n; ++i) {
            // one package, from its end backwards
            if (end < SIG_LEN + 13) revert BadPayload(4);
            uint256 sigAt = end - SIG_LEN;
            uint256 cnt = uint24(bytes3(p[sigAt - 3:sigAt]));
            uint256 vbs = uint32(bytes4(p[sigAt - 7:sigAt - 3]));
            uint256 ts = uint48(bytes6(p[sigAt - 13:sigAt - 7]));
            if (vbs == 0 || vbs > 32 || cnt == 0) revert BadPayload(5);
            uint256 dataLen = cnt * (32 + vbs);
            if (sigAt < 13 + dataLen) revert BadPayload(6);
            uint256 start = sigAt - 13 - dataLen;
            pkgs[i] = Pkg({
                signer: _recover(keccak256(p[start:sigAt]), p[sigAt:end]),
                timestampMs: ts,
                dataStart: start,
                count: cnt,
                valueSize: vbs
            });
            end = start;
        }
        if (end != 0) revert BadPayload(7);
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (v < 27) v += 27;
        // reject high-s signatures (malleability)
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return address(0);
        }
        return ecrecover(digest, v, r, s);
    }

    function _accept(bytes32 assetId, Pkg[] memory pkgs, bytes calldata payload) internal {
        Feed storage f = _feeds[assetId];
        bytes32 feedId = f.feedId;
        if (feedId == bytes32(0)) revert UnknownAsset(assetId);
        uint256[] memory vals = new uint256[](pkgs.length);
        address[] memory seen = new address[](pkgs.length);
        uint256 m;
        uint256 ts;
        for (uint256 i; i < pkgs.length; ++i) {
            Pkg memory k = pkgs[i];
            if (!isSigner[k.signer] || _contains(seen, m, k.signer)) continue;
            (bool found, uint256 v) = _valueOf(payload, k, feedId);
            if (!found) continue;
            if (m == 0) ts = k.timestampMs;
            else if (k.timestampMs != ts) revert TimestampMismatch(assetId);
            seen[m] = k.signer;
            vals[m++] = v;
        }
        if (m < threshold) revert NotEnoughSigners(assetId, m, threshold);
        uint256 at = ts / 1000;
        if (at + MAX_DELAY < block.timestamp || at > block.timestamp + MAX_AHEAD) {
            revert StaleData(assetId, at, block.timestamp);
        }
        if (at <= f.liveAt) revert NotNewer(assetId, at, f.liveAt);
        uint256 price = _median(vals, m) * 1e10; // 8 decimals → WAD
        uint8 status = _status(assetId);
        f.livePrice = uint128(price);
        f.liveAt = uint40(at);
        f.status = status;
        if (status == FeedMarketStatus.REGULAR) {
            f.regPrice = uint128(price);
            f.regAt = uint40(at);
            Obs storage o = _opens[assetId][at / 1 days];
            if (o.price == 0) (o.price, o.at) = (uint128(price), uint40(at)); // first regular print of the day
        }
        _pushObs(assetId, f, uint128(price), uint40(at));
        emit PriceAccepted(assetId, price, uint40(at), status, uint8(m));
    }

    /// @dev The value of `feedId` in one package (values shorter than 32 bytes are big-endian, right-aligned).
    function _valueOf(bytes calldata p, Pkg memory k, bytes32 feedId) internal pure returns (bool, uint256) {
        uint256 step = 32 + k.valueSize;
        for (uint256 j; j < k.count; ++j) {
            uint256 at = k.dataStart + j * step;
            if (bytes32(p[at:at + 32]) == feedId) {
                return (true, uint256(bytes32(p[at + 32:at + 32 + k.valueSize])) >> (8 * (32 - k.valueSize)));
            }
        }
        return (false, 0);
    }

    function _contains(address[] memory xs, uint256 n, address x) internal pure returns (bool) {
        for (uint256 i; i < n; ++i) {
            if (xs[i] == x) return true;
        }
        return false;
    }

    /// @dev Median of the first n values (insertion sort; n ≤ 64); mean of the two middle ones for an even n.
    function _median(uint256[] memory v, uint256 n) internal pure returns (uint256) {
        for (uint256 i = 1; i < n; ++i) {
            uint256 x = v[i];
            uint256 j = i;
            while (j > 0 && v[j - 1] > x) {
                v[j] = v[j - 1];
                --j;
            }
            v[j] = x;
        }
        return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2;
    }

    function _status(bytes32 assetId) internal view returns (uint8) {
        if (address(clock) == address(0)) return FeedMarketStatus.REGULAR;
        ClockState s = clock.calendarState(assetId);
        if (s == ClockState.REGULAR) return FeedMarketStatus.REGULAR;
        if (s == ClockState.EXTENDED) return FeedMarketStatus.OVERNIGHT;
        return FeedMarketStatus.CLOSED;
    }

    function _pushObs(bytes32 asset, Feed storage f, uint128 price, uint40 at) internal {
        Obs[96] storage ring = _ring[asset];
        uint8 head = f.ringCount == 0 ? 0 : uint8((uint256(f.ringHead) + 1) % RING_SIZE);
        ring[head] = Obs(price, at);
        f.ringHead = head;
        if (f.ringCount < RING_SIZE) f.ringCount += 1;
    }

    // ───────────── IPriceSource ─────────────

    /// @inheritdoc IPriceSource
    function latest(bytes32 assetId) external view returns (uint256, uint40, uint8) {
        Feed storage f = _feeds[assetId];
        return (f.livePrice, f.liveAt, f.status);
    }

    /// @inheritdoc IPriceSource
    /// @dev ADR-0009 D1: the first regular print of that day, if it came within 30 min of the open.
    function officialOpen(bytes32 assetId, uint40 sessionOpen) external view returns (uint256, uint40, bool) {
        Obs memory o = _opens[assetId][sessionOpen / 1 days];
        bool ok = o.price != 0 && o.at >= sessionOpen && o.at < uint256(sessionOpen) + OPEN_WINDOW;
        return (o.price, o.at, ok);
    }

    /// @inheritdoc IPriceSource
    /// @dev ADR-0009 D1: the latest regular print stands in for the official close.
    function officialClose(bytes32 assetId) external view returns (uint256, uint40, uint40) {
        Feed storage f = _feeds[assetId];
        return (f.regPrice, f.regAt, uint40(uint256(f.regAt) / 1 days));
    }

    /// @inheritdoc IPriceSource
    function lastRegular(bytes32 assetId) external view returns (uint256, uint40) {
        Feed storage f = _feeds[assetId];
        return (f.regPrice, f.regAt);
    }

    /// @inheritdoc IPriceSource
    /// @dev Same rule as CredencePriceFeed: each print holds from its time to the next; ok needs history ≥ window.
    function twap(bytes32 assetId, uint32 window) external view returns (uint256, bool) {
        Feed storage f = _feeds[assetId];
        uint256 count = f.ringCount;
        if (count == 0) return (0, false);
        Obs[96] storage ring = _ring[assetId];
        if (window == 0) return (ring[f.ringHead].price, true);
        if (block.timestamp < window) return (0, false);
        uint256 start = block.timestamp - window;
        uint256 acc;
        uint256 segEnd = block.timestamp;
        uint256 idx = f.ringHead;
        for (uint256 i; i < count; ++i) {
            Obs memory o = ring[idx];
            uint256 at = o.at > block.timestamp ? block.timestamp : o.at;
            if (at <= start) return ((acc + uint256(o.price) * (segEnd - start)) / window, true);
            acc += uint256(o.price) * (segEnd - at);
            segEnd = at;
            idx = idx == 0 ? RING_SIZE - 1 : idx - 1;
        }
        return (0, false);
    }

    function signers() external view returns (address[] memory) {
        return _signers;
    }

    function feedOf(bytes32 assetId) external view returns (bytes32) {
        return _feeds[assetId].feedId;
    }
}
