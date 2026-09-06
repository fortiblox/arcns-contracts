// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title HandleCorpus — the conformance corpus for `HandleNormalize`
/// @notice Every case in `crates/handle-normalize/src/lib.rs` `#[cfg(test)]` (x1-handles) is here,
///         tagged with the Rust test it comes from, plus Solidity-side edge cases (Unicode
///         `White_Space` trimming, at-sign handling, hyphen/digit shapes). `reason` uses the Rust
///         `NormalizeError` variant names, or `Ok`.
///         Consumed by `test/unit/HandleCorpus.t.sol` (asserts the library agrees) and
///         `script/GenFixtures.s.sol` (emits `sdk/test/fixtures.json` for the SDK / WASM builds).
///         Append only: fixture order is the JSON order and must stay deterministic.
library HandleCorpus {
    struct Case {
        string input;
        string canonical; // empty when reason != "Ok"
        string reason;
        string source; // Rust test name or "solidity"
    }

    function cases() internal pure returns (Case[] memory c) {
        c = new Case[](65);
        uint256 i;
        string memory a32 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; // MAX_LEN
        string memory a33 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; // MAX_LEN + 1
        string memory z32 = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";

        // case_and_at_prefix_and_whitespace_collapse
        c[i++] = Case("@Alice", "alice", "Ok", "case_and_at_prefix_and_whitespace_collapse");
        c[i++] = Case("alice", "alice", "Ok", "case_and_at_prefix_and_whitespace_collapse");
        c[i++] = Case("ALICE", "alice", "Ok", "case_and_at_prefix_and_whitespace_collapse");
        c[i++] = Case(" @alice ", "alice", "Ok", "case_and_at_prefix_and_whitespace_collapse");
        c[i++] = Case("AlIcE", "alice", "Ok", "case_and_at_prefix_and_whitespace_collapse");

        // homograph_class_is_excluded_entirely
        c[i++] = Case(unicode"аlice", "", "NonAscii", "homograph_class_is_excluded_entirely"); // U+0430
        c[i++] = Case(unicode"alicе", "", "NonAscii", "homograph_class_is_excluded_entirely"); // U+0435
        c[i++] = Case(unicode"💎gem", "", "NonAscii", "homograph_class_is_excluded_entirely");
        c[i++] = Case(unicode"中文", "", "NonAscii", "homograph_class_is_excluded_entirely");

        // hyphen_rules
        c[i++] = Case("a-b", "a-b", "Ok", "hyphen_rules");
        c[i++] = Case("-abc", "", "HyphenAtEdge", "hyphen_rules");
        c[i++] = Case("abc-", "", "HyphenAtEdge", "hyphen_rules");
        c[i++] = Case("a--b", "", "ConsecutiveHyphens", "hyphen_rules");

        // length_and_charset_bounds
        c[i++] = Case("", "", "Empty", "length_and_charset_bounds");
        c[i++] = Case("@", "", "Empty", "length_and_charset_bounds");
        c[i++] = Case(a33, "", "TooLong", "length_and_charset_bounds");
        c[i++] = Case(a32, a32, "Ok", "length_and_charset_bounds");
        c[i++] = Case("al ice", "", "IllegalCharacter", "length_and_charset_bounds");
        c[i++] = Case("al_ice", "", "IllegalCharacter", "length_and_charset_bounds");
        c[i++] = Case("al.ice", "", "IllegalCharacter", "length_and_charset_bounds");

        // all_digit_handles_are_reserved
        c[i++] = Case("1234", "", "AllDigits", "all_digit_handles_are_reserved");
        c[i++] = Case("a1234", "a1234", "Ok", "all_digit_handles_are_reserved");
        c[i++] = Case("1234a", "1234a", "Ok", "all_digit_handles_are_reserved");

        // normalize_is_idempotent_and_agrees_with_is_canonical
        c[i++] = Case("x1", "x1", "Ok", "normalize_is_idempotent_and_agrees_with_is_canonical");
        c[i++] = Case(z32, z32, "Ok", "normalize_is_idempotent_and_agrees_with_is_canonical");
        c[i++] = Case("Alice", "alice", "Ok", "normalize_is_idempotent_and_agrees_with_is_canonical");
        c[i++] = Case("@alice", "alice", "Ok", "normalize_is_idempotent_and_agrees_with_is_canonical");
        c[i++] = Case(" alice", "alice", "Ok", "normalize_is_idempotent_and_agrees_with_is_canonical");

        // seed_bytes_only_accepts_canonical_input / distinct_handles_never_share_a_seed
        c[i++] = Case("alicee", "alicee", "Ok", "distinct_handles_never_share_a_seed");
        c[i++] = Case("alic", "alic", "Ok", "distinct_handles_never_share_a_seed");

        // error_reasons_are_specific_enough_for_ui
        c[i++] = Case("-a", "", "HyphenAtEdge", "error_reasons_are_specific_enough_for_ui");
        c[i++] = Case("99", "", "AllDigits", "error_reasons_are_specific_enough_for_ui");
        c[i++] = Case("@ALICE ", "alice", "Ok", "error_reasons_are_specific_enough_for_ui");

        // solidity — MIN_LEN, digit/hyphen shapes, precedence
        c[i++] = Case("a", "a", "Ok", "solidity");
        c[i++] = Case("0", "", "AllDigits", "solidity");
        c[i++] = Case("1-2", "1-2", "Ok", "solidity"); // no letter, but not all digits
        c[i++] = Case("-", "", "HyphenAtEdge", "solidity");
        c[i++] = Case("a-", "", "HyphenAtEdge", "solidity");
        c[i++] = Case("ab--", "", "HyphenAtEdge", "solidity"); // edge check precedes consecutive
        c[i++] = Case("a---b", "", "ConsecutiveHyphens", "solidity");
        c[i++] = Case("Alice-Bob", "alice-bob", "Ok", "solidity");
        c[i++] = Case("a b", "", "IllegalCharacter", "solidity");
        c[i++] = Case("a\tb", "", "IllegalCharacter", "solidity"); // inner whitespace is not trimmed
        c[i++] = Case("al\x00ice", "", "IllegalCharacter", "solidity");
        c[i++] = Case("Alice!", "", "IllegalCharacter", "solidity");
        c[i++] = Case("alice.arc", "", "IllegalCharacter", "solidity"); // labels only, never dotted

        // solidity — `@` handling: one prefix, stripped after trim, never re-trimmed
        c[i++] = Case("@@alice", "", "IllegalCharacter", "solidity");
        c[i++] = Case("@ alice", "", "IllegalCharacter", "solidity");
        c[i++] = Case("\t@alice\n", "alice", "Ok", "solidity");
        c[i++] = Case("alice@", "", "IllegalCharacter", "solidity");
        c[i++] = Case(string.concat("@", a32), a32, "Ok", "solidity"); // 32 after strip
        c[i++] = Case(string.concat("@", a33), "", "TooLong", "solidity");
        c[i++] = Case(string.concat("  ", a32, "  "), a32, "Ok", "solidity");

        // solidity — Rust `str::trim` strips Unicode White_Space, and only White_Space
        c[i++] = Case(unicode" alice ", "alice", "Ok", "solidity"); // NBSP
        c[i++] = Case(unicode"　alice", "alice", "Ok", "solidity"); // IDEOGRAPHIC SPACE
        c[i++] = Case(string(hex"616c696365c285"), "alice", "Ok", "solidity"); // "alice" + U+0085 NEL
        c[i++] = Case(string(hex"e280a840616c696365e280af"), "alice", "Ok", "solidity"); // U+2028 "@alice" U+202F
        c[i++] = Case(unicode" alice ", "alice", "Ok", "solidity");
        c[i++] = Case(unicode"  alice", "alice", "Ok", "solidity"); // two 3-byte spaces
        c[i++] = Case(unicode"​alice", "", "NonAscii", "solidity"); // ZWSP is not White_Space
        c[i++] = Case(unicode" ", "", "Empty", "solidity"); // trims to nothing
        c[i++] = Case(unicode"al ice", "", "NonAscii", "solidity"); // inner NBSP is not trimmed
        c[i++] = Case(unicode"@а", "", "NonAscii", "solidity");
        c[i++] = Case(unicode" @ ", "", "Empty", "solidity"); // "@" then nothing
        c[i++] = Case(unicode" 1234", "", "AllDigits", "solidity");
        require(i == c.length, "corpus size");
    }
}
