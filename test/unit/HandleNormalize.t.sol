// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {HandleNormalize} from "../../src/lib/HandleNormalize.sol";

/// @notice Ports every test in `crates/handle-normalize/src/lib.rs` `mod tests` (x1-handles).
///         Each `test_<name>` below carries the Rust test's name; Solidity-only tests are suffixed
///         `_solidity`. Fuzz tests prove WP-102's acceptance: `normalize(normalize(x)) == normalize(x)`.
contract HandleNormalizeTest is Test {
    using HandleNormalize for string;

    string internal constant A32 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    string internal constant A33 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    string internal constant Z32 = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";

    function _n(string memory s) internal pure returns (string memory out, HandleNormalize.Reason r) {
        return HandleNormalize.tryNormalize(s);
    }

    function _ok(string memory s) internal pure returns (string memory out) {
        HandleNormalize.Reason r;
        (out, r) = HandleNormalize.tryNormalize(s);
        require(r == HandleNormalize.Reason.Ok, "expected Ok");
    }

    function _err(string memory s) internal pure returns (HandleNormalize.Reason r) {
        (, r) = HandleNormalize.tryNormalize(s);
    }

    /// Runtime bytes-to-string conversion: lets tests feed invalid UTF-8 the compiler rejects as a literal.
    function _raw(bytes memory b) internal pure returns (string memory) {
        return string(b);
    }

    // ---- Rust: case_and_at_prefix_and_whitespace_collapse -------------------------------------
    function test_case_and_at_prefix_and_whitespace_collapse() public pure {
        string[5] memory v = ["@Alice", "alice", "ALICE", " @alice ", "AlIcE"];
        for (uint256 i = 0; i < v.length; i++) {
            assertEq(_ok(v[i]), "alice", v[i]);
        }
    }

    // ---- Rust: homograph_class_is_excluded_entirely -------------------------------------------
    function test_homograph_class_is_excluded_entirely() public pure {
        // Cyrillic 'а' (U+0430) renders identically to ASCII 'a'.
        assertEq(uint256(_err(unicode"аlice")), uint256(HandleNormalize.Reason.NonAscii));
        assertEq(uint256(_err(unicode"alicе")), uint256(HandleNormalize.Reason.NonAscii));
        assertEq(uint256(_err(unicode"💎gem")), uint256(HandleNormalize.Reason.NonAscii));
        assertEq(uint256(_err(unicode"中文")), uint256(HandleNormalize.Reason.NonAscii));
    }

    // ---- Rust: hyphen_rules -------------------------------------------------------------------
    function test_hyphen_rules() public pure {
        assertEq(_ok("a-b"), "a-b");
        assertEq(uint256(_err("-abc")), uint256(HandleNormalize.Reason.HyphenAtEdge));
        assertEq(uint256(_err("abc-")), uint256(HandleNormalize.Reason.HyphenAtEdge));
        assertEq(uint256(_err("a--b")), uint256(HandleNormalize.Reason.ConsecutiveHyphens));
    }

    // ---- Rust: length_and_charset_bounds ------------------------------------------------------
    function test_length_and_charset_bounds() public pure {
        assertEq(uint256(_err("")), uint256(HandleNormalize.Reason.Empty));
        assertEq(uint256(_err("@")), uint256(HandleNormalize.Reason.Empty));
        assertEq(bytes(A33).length, HandleNormalize.MAX_LEN + 1);
        assertEq(uint256(_err(A33)), uint256(HandleNormalize.Reason.TooLong));
        assertEq(bytes(A32).length, HandleNormalize.MAX_LEN);
        assertEq(_ok(A32), A32);
        assertEq(uint256(_err("al ice")), uint256(HandleNormalize.Reason.IllegalCharacter));
        assertEq(uint256(_err("al_ice")), uint256(HandleNormalize.Reason.IllegalCharacter));
        assertEq(uint256(_err("al.ice")), uint256(HandleNormalize.Reason.IllegalCharacter));
    }

    // ---- Rust: all_digit_handles_are_reserved -------------------------------------------------
    function test_all_digit_handles_are_reserved() public pure {
        assertEq(uint256(_err("1234")), uint256(HandleNormalize.Reason.AllDigits));
        assertEq(_ok("a1234"), "a1234");
        assertEq(_ok("1234a"), "1234a");
    }

    // ---- Rust: normalize_is_idempotent_and_agrees_with_is_canonical ---------------------------
    function test_normalize_is_idempotent_and_agrees_with_is_canonical() public pure {
        string[5] memory v = ["alice", "a-b", "x1", "a1234", Z32];
        for (uint256 i = 0; i < v.length; i++) {
            string memory n = _ok(v[i]);
            assertEq(_ok(n), n, "not idempotent");
            assertTrue(HandleNormalize.isCanonical(n), "must be canonical");
        }
        assertFalse(HandleNormalize.isCanonical("Alice"));
        assertFalse(HandleNormalize.isCanonical("@alice"));
        assertFalse(HandleNormalize.isCanonical(" alice"));
    }

    // ---- Rust: seed_bytes_only_accepts_canonical_input ----------------------------------------
    function test_seed_bytes_only_accepts_canonical_input() public pure {
        (bytes32 s, bool ok) = HandleNormalize.seedBytes("alice");
        assertTrue(ok);
        assertEq(bytes5(s), bytes5("alice"));
        // zero-padded tail
        assertEq(uint256(s) & (type(uint256).max >> 40), 0, "tail must be zero");
        (s, ok) = HandleNormalize.seedBytes("Alice");
        assertFalse(ok, "must reject non-canonical");
        assertEq(s, bytes32(0));
        (, ok) = HandleNormalize.seedBytes("@alice");
        assertFalse(ok);
    }

    // ---- Rust: distinct_handles_never_share_a_seed --------------------------------------------
    function test_distinct_handles_never_share_a_seed() public pure {
        (bytes32 a,) = HandleNormalize.seedBytes(_ok("alice"));
        (bytes32 b,) = HandleNormalize.seedBytes(_ok("alicee"));
        (bytes32 c,) = HandleNormalize.seedBytes(_ok("alic"));
        assertTrue(a != b);
        assertTrue(a != c);
        assertTrue(b != c);
    }

    // ---- Rust: error_reasons_are_specific_enough_for_ui ---------------------------------------
    function test_error_reasons_are_specific_enough_for_ui() public pure {
        assertEq(uint256(_err(unicode"аlice")), uint256(HandleNormalize.Reason.NonAscii));
        assertEq(uint256(_err("-a")), uint256(HandleNormalize.Reason.HyphenAtEdge));
        assertEq(uint256(_err("a--b")), uint256(HandleNormalize.Reason.ConsecutiveHyphens));
        assertEq(uint256(_err("99")), uint256(HandleNormalize.Reason.AllDigits));
        assertEq(_ok("@ALICE "), "alice");
        // The names the UI renders are the Rust variant names.
        assertEq(HandleNormalize.reasonName(HandleNormalize.Reason.Ok), "Ok");
        assertEq(HandleNormalize.reasonName(HandleNormalize.Reason.Empty), "Empty");
        assertEq(HandleNormalize.reasonName(HandleNormalize.Reason.TooLong), "TooLong");
        assertEq(HandleNormalize.reasonName(HandleNormalize.Reason.IllegalCharacter), "IllegalCharacter");
        assertEq(HandleNormalize.reasonName(HandleNormalize.Reason.NonAscii), "NonAscii");
        assertEq(HandleNormalize.reasonName(HandleNormalize.Reason.HyphenAtEdge), "HyphenAtEdge");
        assertEq(HandleNormalize.reasonName(HandleNormalize.Reason.ConsecutiveHyphens), "ConsecutiveHyphens");
        assertEq(HandleNormalize.reasonName(HandleNormalize.Reason.AllDigits), "AllDigits");
    }

    // ---- Solidity-only ------------------------------------------------------------------------

    /// Rust `str::trim` strips Unicode `White_Space`; the port must not be ASCII-only here.
    function test_unicode_whitespace_trim_matches_rust_str_trim_solidity() public pure {
        assertEq(_ok(unicode" alice "), "alice");
        assertEq(_ok(unicode"　alice"), "alice");
        assertEq(_ok(string(hex"616c696365c285")), "alice"); // "alice" + U+0085 NEL
        assertEq(_ok(string(hex"e280a840616c696365e280af")), "alice"); // U+2028 "@alice" U+202F
        assertEq(_ok(string(hex"e280a9616c696365")), "alice"); // U+2029 "alice"
        assertEq(_ok(unicode" alice "), "alice");
        assertEq(_ok(unicode"  alice"), "alice");
        assertEq(_ok("\x09\x0a\x0b\x0c\x0d alice \x0d\x0c\x0b\x0a\x09"), "alice");
        // not White_Space → the non-ASCII byte survives the trim and is rejected
        assertEq(uint256(_err(unicode"​alice")), uint256(HandleNormalize.Reason.NonAscii));
        assertEq(uint256(_err(unicode"al ice")), uint256(HandleNormalize.Reason.NonAscii));
        assertEq(uint256(_err(unicode" ")), uint256(HandleNormalize.Reason.Empty));
    }

    /// `&str` can never hold invalid UTF-8; here any byte ≥ 0x80 maps to `NonAscii`.
    function test_invalid_utf8_high_bytes_are_non_ascii_solidity() public pure {
        assertEq(uint256(_err(_raw(hex"ff"))), uint256(HandleNormalize.Reason.NonAscii));
        assertEq(uint256(_err(_raw(hex"616c69636580"))), uint256(HandleNormalize.Reason.NonAscii));
        assertEq(uint256(_err(_raw(hex"c2"))), uint256(HandleNormalize.Reason.NonAscii)); // truncated NBSP
        assertEq(uint256(_err(_raw(hex"e280"))), uint256(HandleNormalize.Reason.NonAscii)); // truncated
    }

    function test_at_prefix_is_stripped_once_after_trim_solidity() public pure {
        assertEq(uint256(_err("@@alice")), uint256(HandleNormalize.Reason.IllegalCharacter));
        assertEq(uint256(_err("@ alice")), uint256(HandleNormalize.Reason.IllegalCharacter));
        assertEq(uint256(_err("alice@")), uint256(HandleNormalize.Reason.IllegalCharacter));
        assertEq(_ok("\t@alice\n"), "alice");
        assertEq(_ok(string.concat("@", A32)), A32);
        assertEq(uint256(_err(string.concat("@", A33))), uint256(HandleNormalize.Reason.TooLong));
    }

    function test_digit_and_hyphen_shapes_solidity() public pure {
        assertEq(_ok("a"), "a");
        assertEq(uint256(_err("0")), uint256(HandleNormalize.Reason.AllDigits));
        assertEq(_ok("1-2"), "1-2");
        assertEq(uint256(_err("-")), uint256(HandleNormalize.Reason.HyphenAtEdge));
        assertEq(uint256(_err("ab--")), uint256(HandleNormalize.Reason.HyphenAtEdge));
        assertEq(uint256(_err("a---b")), uint256(HandleNormalize.Reason.ConsecutiveHyphens));
    }

    /// Values cross-checked with `cast namehash arc` / `cast namehash circle` (foundry 1.8.1).
    function test_namehash_constants_match_cast_solidity() public pure {
        assertEq(HandleNormalize.ARC_NODE, 0x9a7ad1c5d8b1c60ef156c6723dbf462681d6462768a9e60c53665d7fc1337bae);
        assertEq(HandleNormalize.CIRCLE_NODE, 0xb3f3947bd9b363b1955fa597e342731ea6bde24d057527feb2cdfdeb807c2084);
        assertEq(HandleNormalize.tldNode("arc"), HandleNormalize.ARC_NODE);
        assertEq(HandleNormalize.tldNode("circle"), HandleNormalize.CIRCLE_NODE);
        assertEq(HandleNormalize.labelhash("arc"), keccak256("arc"));
        // alice.arc
        bytes32 expected = keccak256(abi.encodePacked(HandleNormalize.ARC_NODE, keccak256("alice")));
        assertEq(HandleNormalize.labelNode("alice", HandleNormalize.ARC_NODE), expected);
        assertEq(HandleNormalize.node(HandleNormalize.ARC_NODE, keccak256("alice")), expected);
    }

    function test_labelNode_rejects_non_canonical_solidity() public {
        vm.expectRevert(abi.encodeWithSelector(HandleNormalize.NotCanonical.selector, "Alice"));
        this.labelNodeExternal("Alice", HandleNormalize.ARC_NODE);
        vm.expectRevert(abi.encodeWithSelector(HandleNormalize.NotCanonical.selector, "@alice"));
        this.labelNodeExternal("@alice", HandleNormalize.ARC_NODE);
    }

    function labelNodeExternal(string calldata label, bytes32 parent) external pure returns (bytes32) {
        return HandleNormalize.labelNode(label, parent);
    }

    // ---- Fuzz (WP-102 acceptance) -------------------------------------------------------------

    /// `normalize(normalize(x)) == normalize(x)` and the output is canonical.
    function testFuzz_normalize_is_idempotent(string memory x) public pure {
        (string memory n, bool ok) = HandleNormalize.normalize(x);
        if (!ok) return;
        (string memory nn, bool ok2) = HandleNormalize.normalize(n);
        assertTrue(ok2);
        assertEq(nn, n);
        assertTrue(HandleNormalize.isCanonical(n));
    }

    /// Every accepted output is `a-z0-9-`, 1..=32 bytes, no edge/double hyphen, not all digits.
    function testFuzz_output_is_within_grammar(bytes memory raw) public pure {
        (string memory n, bool ok) = HandleNormalize.normalize(string(raw));
        if (!ok) {
            assertEq(bytes(n).length, 0);
            return;
        }
        bytes memory b = bytes(n);
        assertTrue(b.length >= HandleNormalize.MIN_LEN && b.length <= HandleNormalize.MAX_LEN);
        assertTrue(b[0] != "-" && b[b.length - 1] != "-");
        bool alpha;
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            bool lower = c >= 0x61 && c <= 0x7A;
            bool digit = c >= 0x30 && c <= 0x39;
            assertTrue(lower || digit || c == 0x2D, "charset");
            if (lower) alpha = true;
            if (c == 0x2D) assertTrue(b[i - 1] != "-", "double hyphen");
        }
        if (!alpha) {
            bool hyphen;
            for (uint256 i = 0; i < b.length; i++) {
                if (b[i] == "-") hyphen = true;
            }
            assertTrue(hyphen, "all digits");
        }
    }

    /// `isCanonical(x)` ⇔ `normalize(x) == (x, true)`.
    function testFuzz_canonical_iff_normalize_returns_self(string memory x) public pure {
        (string memory n, bool ok) = HandleNormalize.normalize(x);
        bool self = ok && keccak256(bytes(n)) == keccak256(bytes(x));
        assertEq(HandleNormalize.isCanonical(x), self);
    }

    /// Case-folding and at-sign/whitespace decoration never change the canonical result.
    function testFuzz_decoration_is_transparent(string memory x) public pure {
        (string memory n, bool ok) = HandleNormalize.normalize(x);
        if (!ok) return;
        (string memory m, bool ok2) = HandleNormalize.normalize(string.concat("  @", _upper(n), "\t"));
        assertTrue(ok2);
        assertEq(m, n);
    }

    function _upper(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes.concat(bytes(s)); // copy: `bytes(s)` would alias and mutate the input
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 0x61 && c <= 0x7A) b[i] = bytes1(c - 0x20);
        }
        return string(b);
    }
}
