// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title HandleNormalize — canonical `handle` grammar (and TLD-label grammar) for arcns
/// @notice Byte-for-byte port of `fortiblox/x1-handles` `crates/handle-normalize/src/lib.rs`
///         (`normalize`, `is_canonical`, `seed_bytes`, `MIN_LEN`, `MAX_LEN`, `NormalizeError`).
///         The Rust crate is the single source of truth (SR-01, INV-10); this library is
///         conformance-tested against the fixture corpus derived from its `#[cfg(test)]` module
///         (`test/unit/HandleNormalize.t.sol`, `test/fixtures/HandleCorpus.sol`,
///         `script/GenFixtures.s.sol` → `sdk/test/fixtures.json`).
///
/// # Policy (verbatim from the crate)
/// ASCII only, lowercase, `a-z 0-9 -`. No Unicode, no emoji. For a *payment* identifier a
/// homograph is a live attack vector (`аlice` with Cyrillic `а` renders identically to
/// `alice`); restricting the alphabet removes the class instead of trying to detect it.
///
/// # Algorithm (order matters — errors are reported in the same precedence as Rust)
/// 1. `trim()` — strip Unicode `White_Space` from both ends (Rust `str::trim`, see `_wsPrefixLen`).
/// 2. `strip_prefix` of the at-sign — one leading at-sign is accepted for convenience; it is not canonical.
/// 3. any byte ≥ 0x80 → `NonAscii`.
/// 4. empty → `Empty`; longer than `MAX_LEN` bytes → `TooLong`.
/// 5. per byte: ASCII-lowercase fold; `a-z` / `0-9` accepted; `-` rejected at either edge
///    (`HyphenAtEdge`) or after another `-` (`ConsecutiveHyphens`); anything else `IllegalCharacter`.
/// 6. no letter and only digits → `AllDigits` (keeps handles textually distinct from numeric ids).
///
/// # TldLabel grammar
/// `.arc` / `.circle` labels use the **same** grammar (onchain-design §3.2: "on-chain `valid()`
/// enforces the same ASCII grammar as `handle`"). There is no separate `TldLabel` type: a
/// registrar controller calls `isCanonical(label)` and derives `node(tldNode, labelhash(label))`.
/// ASCII names normalize to themselves under ENSIP-15, so ENS tooling sees the same node.
library HandleNormalize {
    /// @dev Shortest permitted handle (bytes). Single characters are reserved, not registrable.
    uint256 internal constant MIN_LEN = 1;
    /// @dev Longest permitted handle (bytes). Bounds the X1 PDA seed and the UI.
    uint256 internal constant MAX_LEN = 32;

    /// @dev Mirrors `NormalizeError` one-to-one, with `Ok` prepended so `Reason(0)` is success.
    enum Reason {
        Ok,
        Empty,
        TooLong,
        IllegalCharacter,
        NonAscii,
        HyphenAtEdge,
        ConsecutiveHyphens,
        AllDigits
    }

    /// @dev ENS root node.
    bytes32 internal constant ROOT_NODE = bytes32(0);
    /// @dev `namehash("arc")` — 0x9a7ad1c5d8b1c60ef156c6723dbf462681d6462768a9e60c53665d7fc1337bae.
    bytes32 internal constant ARC_NODE = keccak256(abi.encodePacked(bytes32(0), keccak256("arc")));
    /// @dev `namehash("circle")` — 0xb3f3947bd9b363b1955fa597e342731ea6bde24d057527feb2cdfdeb807c2084.
    bytes32 internal constant CIRCLE_NODE = keccak256(abi.encodePacked(bytes32(0), keccak256("circle")));

    /// @notice Thrown by `labelNode` when the label is not canonical.
    error NotCanonical(string label);

    // ---------------------------------------------------------------------------------------------
    // Normalization
    // ---------------------------------------------------------------------------------------------

    /// @notice `normalize(raw)` — canonical form plus success flag.
    /// @return canonical the canonical handle (empty when `ok == false`)
    /// @return ok true iff `raw` normalizes
    function normalize(string memory raw) internal pure returns (string memory canonical, bool ok) {
        Reason r;
        (canonical, r) = tryNormalize(raw);
        ok = r == Reason.Ok;
    }

    /// @notice `normalize(raw)` with the specific failure reason (UI renders these directly).
    function tryNormalize(string memory raw) internal pure returns (string memory canonical, Reason reason) {
        bytes memory b = bytes(raw);
        (uint256 start, uint256 end) = _trimBounds(b);
        if (end > start && b[start] == "@") start++;
        uint256 len = end - start;

        for (uint256 i = start; i < end; i++) {
            if (uint8(b[i]) >= 0x80) return ("", Reason.NonAscii);
        }
        if (len == 0) return ("", Reason.Empty);
        if (len > MAX_LEN) return ("", Reason.TooLong);

        bytes memory out = new bytes(len);
        bool prevHyphen;
        bool hasAlpha;
        bool hasHyphen;
        for (uint256 i = 0; i < len; i++) {
            uint8 c = uint8(b[start + i]);
            if (c >= 0x41 && c <= 0x5A) c += 0x20; // to_ascii_lowercase
            if (c >= 0x61 && c <= 0x7A) {
                hasAlpha = true;
                prevHyphen = false;
            } else if (c >= 0x30 && c <= 0x39) {
                prevHyphen = false;
            } else if (c == 0x2D) {
                if (i == 0 || i == len - 1) return ("", Reason.HyphenAtEdge);
                if (prevHyphen) return ("", Reason.ConsecutiveHyphens);
                prevHyphen = true;
                hasHyphen = true;
            } else {
                return ("", Reason.IllegalCharacter);
            }
            out[i] = bytes1(c);
        }
        // Rust: `!has_alpha && out.chars().all(is_ascii_digit)`; without a letter the only
        // non-digit that can be present is `-`.
        if (!hasAlpha && !hasHyphen) return ("", Reason.AllDigits);
        return (string(out), Reason.Ok);
    }

    /// @notice True when `s` is already canonical — i.e. `normalize` returns it unchanged.
    /// @dev Idempotency proof instead of trusting the caller (same as the X1 program).
    function isCanonical(string memory s) internal pure returns (bool) {
        (string memory n, Reason r) = tryNormalize(s);
        return r == Reason.Ok && keccak256(bytes(n)) == keccak256(bytes(s));
    }

    /// @notice Fixed-width seed material, zero-padded to `MAX_LEN` — the X1 `seed_bytes` twin.
    /// @return seed left-aligned canonical bytes (zero when `ok == false`)
    /// @return ok false unless `canonical` is canonical
    function seedBytes(string memory canonical) internal pure returns (bytes32 seed, bool ok) {
        if (!isCanonical(canonical)) return (bytes32(0), false);
        bytes memory b = bytes(canonical);
        uint256 len = b.length; // 1..=32 by construction
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(b, 32))
        }
        uint256 mask = type(uint256).max << (256 - len * 8);
        return (bytes32(word & mask), true);
    }

    /// @notice Human-readable reason, identical to the Rust `NormalizeError` variant names.
    function reasonName(Reason r) internal pure returns (string memory) {
        if (r == Reason.Ok) return "Ok";
        if (r == Reason.Empty) return "Empty";
        if (r == Reason.TooLong) return "TooLong";
        if (r == Reason.IllegalCharacter) return "IllegalCharacter";
        if (r == Reason.NonAscii) return "NonAscii";
        if (r == Reason.HyphenAtEdge) return "HyphenAtEdge";
        if (r == Reason.ConsecutiveHyphens) return "ConsecutiveHyphens";
        return "AllDigits";
    }

    // ---------------------------------------------------------------------------------------------
    // ENS namehash helpers for the `.arc` / `.circle` path
    // ---------------------------------------------------------------------------------------------

    /// @notice ENS `labelhash(label)` = keccak256 of the raw label bytes.
    function labelhash(string memory label) internal pure returns (bytes32) {
        return keccak256(bytes(label));
    }

    /// @notice ENS subnode: `keccak256(parent ‖ labelhash)`.
    function node(bytes32 parent, bytes32 labelHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(parent, labelHash));
    }

    /// @notice `namehash(tld)` for a top-level label (e.g. `"arc"` → `ARC_NODE`).
    function tldNode(string memory tld) internal pure returns (bytes32) {
        return node(ROOT_NODE, labelhash(tld));
    }

    /// @notice Node of `<label>.<tld>` for a **canonical** label; reverts otherwise.
    /// @dev Registrars must never derive a node from an un-normalized label (T-REG-3).
    function labelNode(string memory label, bytes32 parentNode) internal pure returns (bytes32) {
        if (!isCanonical(label)) revert NotCanonical(label);
        return node(parentNode, labelhash(label));
    }

    // ---------------------------------------------------------------------------------------------
    // Rust `str::trim` — Unicode `White_Space` at both ends, encoded as UTF-8
    // ---------------------------------------------------------------------------------------------

    /// @dev Returns the byte offsets `[start, end)` of `b` with `White_Space` removed from both ends.
    function _trimBounds(bytes memory b) private pure returns (uint256 start, uint256 end) {
        end = b.length;
        while (start < end) {
            uint256 n = _wsPrefixLen(b, start, end);
            if (n == 0) break;
            start += n;
        }
        while (end > start) {
            uint256 n = _wsSuffixLen(b, start, end);
            if (n == 0) break;
            end -= n;
        }
    }

    /// @dev Byte length of the `White_Space` character starting at `b[i]`, or 0.
    ///      Unicode `White_Space` (PropList.txt, stable since Unicode 6.3):
    ///      U+0009..U+000D, U+0020, U+0085, U+00A0, U+1680, U+2000..U+200A, U+2028, U+2029,
    ///      U+202F, U+205F, U+3000. (U+200B ZERO WIDTH SPACE is *not* White_Space.)
    function _wsPrefixLen(bytes memory b, uint256 i, uint256 end) private pure returns (uint256) {
        uint8 c0 = uint8(b[i]);
        if (c0 == 0x20 || (c0 >= 0x09 && c0 <= 0x0D)) return 1;
        if (c0 < 0x80) return 0;
        if (c0 == 0xC2) {
            if (i + 1 >= end) return 0;
            uint8 c1 = uint8(b[i + 1]);
            return (c1 == 0x85 || c1 == 0xA0) ? 2 : 0; // U+0085, U+00A0
        }
        if (i + 2 >= end) return 0;
        uint8 d1 = uint8(b[i + 1]);
        uint8 d2 = uint8(b[i + 2]);
        if (c0 == 0xE1) return (d1 == 0x9A && d2 == 0x80) ? 3 : 0; // U+1680
        if (c0 == 0xE2) {
            if (d1 == 0x80) {
                // U+2000..U+200A, U+2028, U+2029, U+202F
                return ((d2 >= 0x80 && d2 <= 0x8A) || d2 == 0xA8 || d2 == 0xA9 || d2 == 0xAF) ? 3 : 0;
            }
            if (d1 == 0x81) return d2 == 0x9F ? 3 : 0; // U+205F
            return 0;
        }
        if (c0 == 0xE3) return (d1 == 0x80 && d2 == 0x80) ? 3 : 0; // U+3000
        return 0;
    }

    /// @dev Byte length of the `White_Space` character ending at `b[end-1]`, or 0.
    function _wsSuffixLen(bytes memory b, uint256 start, uint256 end) private pure returns (uint256) {
        uint8 cL = uint8(b[end - 1]);
        if (cL < 0x80) return (cL == 0x20 || (cL >= 0x09 && cL <= 0x0D)) ? 1 : 0;
        if (end - start >= 2 && _wsPrefixLen(b, end - 2, end) == 2) return 2;
        if (end - start >= 3 && _wsPrefixLen(b, end - 3, end) == 3) return 3;
        return 0;
    }
}
