// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Two-level bitmap over uint24 ticks. `words` marks non-empty ticks,
/// `summary` marks non-empty words, so a search reads at most ~512 slots.
library TickBitmap {
    struct Bitmap {
        mapping(uint256 => uint256) words;
        mapping(uint256 => uint256) summary;
    }

    uint256 private constant MAX_WORD = type(uint24).max >> 8; // 65535
    uint256 private constant MAX_SUMMARY = MAX_WORD >> 8; // 255

    function set(Bitmap storage b, uint24 t) internal {
        uint256 w = uint256(t) >> 8;
        b.words[w] |= uint256(1) << (t & 255);
        b.summary[w >> 8] |= uint256(1) << (w & 255);
    }

    function clear(Bitmap storage b, uint24 t) internal {
        uint256 w = uint256(t) >> 8;
        uint256 word = b.words[w] & ~(uint256(1) << (t & 255));
        b.words[w] = word;
        if (word == 0) b.summary[w >> 8] &= ~(uint256(1) << (w & 255));
    }

    /// @return found true if a set tick <= t exists; tick is the highest such tick.
    function atOrBelow(Bitmap storage b, uint24 t) internal view returns (bool found, uint24 tick) {
        uint256 w = uint256(t) >> 8;
        uint256 masked = b.words[w] & _upTo(t & 255);
        if (masked != 0) return (true, uint24((w << 8) | Math.log2(masked)));
        if (w == 0) return (false, 0);
        uint256 sw = (w - 1) >> 8;
        uint256 smask = b.summary[sw] & _upTo((w - 1) & 255);
        while (true) {
            if (smask != 0) {
                uint256 word = (sw << 8) | Math.log2(smask);
                return (true, uint24((word << 8) | Math.log2(b.words[word])));
            }
            if (sw == 0) return (false, 0);
            smask = b.summary[--sw];
        }
    }

    /// @return found true if a set tick >= t exists; tick is the lowest such tick.
    function atOrAbove(Bitmap storage b, uint24 t) internal view returns (bool found, uint24 tick) {
        uint256 w = uint256(t) >> 8;
        uint256 masked = b.words[w] & ~_below(t & 255);
        if (masked != 0) return (true, uint24((w << 8) | _lsb(masked)));
        if (w == MAX_WORD) return (false, 0);
        uint256 sw = (w + 1) >> 8;
        uint256 smask = b.summary[sw] & ~_below((w + 1) & 255);
        while (true) {
            if (smask != 0) {
                uint256 word = (sw << 8) | _lsb(smask);
                return (true, uint24((word << 8) | _lsb(b.words[word])));
            }
            if (sw == MAX_SUMMARY) return (false, 0);
            smask = b.summary[++sw];
        }
    }

    /// bits 0..bit inclusive
    function _upTo(uint256 bit) private pure returns (uint256) {
        return bit == 255 ? type(uint256).max : (uint256(1) << (bit + 1)) - 1;
    }

    /// bits 0..bit-1
    function _below(uint256 bit) private pure returns (uint256) {
        return (uint256(1) << bit) - 1;
    }

    function _lsb(uint256 x) private pure returns (uint256) {
        unchecked {
            return Math.log2(x & (0 - x));
        }
    }
}
