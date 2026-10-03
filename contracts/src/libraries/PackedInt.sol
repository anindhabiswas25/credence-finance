// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Packed integer vectors shared with risk-core (Build Guide §7.1, R-13, R-14).
/// @dev Layout (identical in crates/risk-core/src/scenarios.rs and capacity.rs):
///      - uint64 × 4 per word: element i lives in word i / 4, lane i % 4, bits [64·lane, 64·lane + 64)
///        (lane 0 = least-significant bits).
///      - int16 × 16 per word: element i lives in word i / 16, lane i % 16, bits [16·lane, 16·lane + 16),
///        two's complement.
library PackedInt {
    error PackedIndexOutOfRange(uint256 index, uint256 length);
    error PackedOverflow();

    uint256 internal constant U64_PER_WORD = 4;
    uint256 internal constant I16_PER_WORD = 16;
    uint256 private constant U64_MASK = 0xffffffffffffffff;
    uint256 private constant U16_MASK = 0xffff;

    /// @notice Words needed for `n` uint64 elements.
    function wordsForU64(uint256 n) internal pure returns (uint256) {
        return (n + 3) / 4;
    }

    /// @notice Words needed for `n` int16 elements.
    function wordsForI16(uint256 n) internal pure returns (uint256) {
        return (n + 15) / 16;
    }

    function getU64(uint256[] memory words, uint256 i) internal pure returns (uint64) {
        uint256 w = i / 4;
        if (w >= words.length) revert PackedIndexOutOfRange(i, words.length * 4);
        return uint64((words[w] >> (64 * (i % 4))) & U64_MASK);
    }

    function setU64(uint256[] memory words, uint256 i, uint64 v) internal pure {
        uint256 w = i / 4;
        if (w >= words.length) revert PackedIndexOutOfRange(i, words.length * 4);
        uint256 shift = 64 * (i % 4);
        words[w] = (words[w] & ~(U64_MASK << shift)) | (uint256(v) << shift);
    }

    /// @notice Pack uint64 values (reverts if any value exceeds uint64).
    function packU64(uint256[] memory values) internal pure returns (uint256[] memory words) {
        words = new uint256[](wordsForU64(values.length));
        for (uint256 i; i < values.length; ++i) {
            if (values[i] > U64_MASK) revert PackedOverflow();
            words[i / 4] |= values[i] << (64 * (i % 4));
        }
    }

    function unpackU64(uint256[] memory words, uint256 n) internal pure returns (uint256[] memory values) {
        if (wordsForU64(n) > words.length) revert PackedIndexOutOfRange(n, words.length * 4);
        values = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            values[i] = (words[i / 4] >> (64 * (i % 4))) & U64_MASK;
        }
    }

    /// @notice Element-wise a + b over the first `n` lanes; reverts on uint64 overflow.
    function addU64(uint256[] memory a, uint256[] memory b, uint256 n)
        internal
        pure
        returns (uint256[] memory out)
    {
        uint256 words = wordsForU64(n);
        if (words > a.length || words > b.length) revert PackedIndexOutOfRange(n, a.length * 4);
        out = new uint256[](words);
        for (uint256 i; i < n; ++i) {
            uint256 s = ((a[i / 4] >> (64 * (i % 4))) & U64_MASK) + ((b[i / 4] >> (64 * (i % 4))) & U64_MASK);
            if (s > U64_MASK) revert PackedOverflow();
            out[i / 4] |= s << (64 * (i % 4));
        }
    }

    /// @notice Largest of the first `n` uint64 lanes.
    function maxU64(uint256[] memory words, uint256 n) internal pure returns (uint64 m) {
        if (wordsForU64(n) > words.length) revert PackedIndexOutOfRange(n, words.length * 4);
        for (uint256 i; i < n; ++i) {
            uint64 v = uint64((words[i / 4] >> (64 * (i % 4))) & U64_MASK);
            if (v > m) m = v;
        }
    }

    /// @notice Signed int16 element `lane` of one word.
    function getI16(uint256 word, uint256 lane) internal pure returns (int16) {
        if (lane >= 16) revert PackedIndexOutOfRange(lane, 16);
        return int16(uint16((word >> (16 * lane)) & U16_MASK));
    }

    function getI16(uint256[] memory words, uint256 i) internal pure returns (int16) {
        uint256 w = i / 16;
        if (w >= words.length) revert PackedIndexOutOfRange(i, words.length * 16);
        return int16(uint16((words[w] >> (16 * (i % 16))) & U16_MASK));
    }

    function packI16(int16[] memory values) internal pure returns (uint256[] memory words) {
        words = new uint256[](wordsForI16(values.length));
        for (uint256 i; i < values.length; ++i) {
            words[i / 16] |= uint256(uint16(values[i])) << (16 * (i % 16));
        }
    }

    function unpackI16(uint256[] memory words, uint256 n) internal pure returns (int16[] memory values) {
        if (wordsForI16(n) > words.length) revert PackedIndexOutOfRange(n, words.length * 16);
        values = new int16[](n);
        for (uint256 i; i < n; ++i) {
            values[i] = int16(uint16((words[i / 16] >> (16 * (i % 16))) & U16_MASK));
        }
    }

    /// @notice True if the first `n` int16 lanes are sorted ascending (R-14 scenario sets).
    function isSortedI16(uint256[] memory words, uint256 n) internal pure returns (bool) {
        if (wordsForI16(n) > words.length) revert PackedIndexOutOfRange(n, words.length * 16);
        int16 prev = type(int16).min;
        for (uint256 i; i < n; ++i) {
            int16 v = int16(uint16((words[i / 16] >> (16 * (i % 16))) & U16_MASK));
            if (v < prev) return false;
            prev = v;
        }
        return true;
    }
}
