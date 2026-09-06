// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {HandleNormalize} from "../../src/lib/HandleNormalize.sol";
import {HandleCorpus} from "../fixtures/HandleCorpus.sol";
import {FixtureJson} from "../../script/FixtureJson.sol";

/// @notice Conformance (SR-01 / INV-10 target): the library agrees with every corpus expectation,
///         and the committed `sdk/test/fixtures.json` is exactly what the library renders today.
contract HandleCorpusTest is Test {
    string internal constant FIXTURES = "../sdk/test/fixtures.json";

    function test_corpus_expectations_hold() public pure {
        HandleCorpus.Case[] memory c = HandleCorpus.cases();
        assertGt(c.length, 0);
        for (uint256 i = 0; i < c.length; i++) {
            (string memory got, HandleNormalize.Reason r) = HandleNormalize.tryNormalize(c[i].input);
            string memory ctx = string.concat("case #", vm.toString(i), " (", c[i].source, ")");
            assertEq(HandleNormalize.reasonName(r), c[i].reason, string.concat(ctx, " reason"));
            assertEq(got, c[i].canonical, string.concat(ctx, " canonical"));
            if (r == HandleNormalize.Reason.Ok) {
                assertTrue(HandleNormalize.isCanonical(got), string.concat(ctx, " canonical output"));
            } else {
                assertEq(bytes(got).length, 0, string.concat(ctx, " empty on error"));
            }
        }
    }

    /// Every `NormalizeError` variant is exercised at least once (SR-01: "all variants included").
    function test_corpus_covers_every_reason() public pure {
        HandleCorpus.Case[] memory c = HandleCorpus.cases();
        bool[8] memory seen;
        for (uint256 i = 0; i < c.length; i++) {
            (, HandleNormalize.Reason r) = HandleNormalize.tryNormalize(c[i].input);
            seen[uint256(r)] = true;
        }
        for (uint256 k = 0; k < seen.length; k++) {
            assertTrue(seen[k], HandleNormalize.reasonName(HandleNormalize.Reason(k)));
        }
    }

    /// The committed fixture file must match a fresh render byte-for-byte.
    /// Regenerate with `forge script script/GenFixtures.s.sol`.
    function test_fixtures_json_is_current() public view {
        string memory onDisk = vm.readFile(FIXTURES);
        string memory fresh = FixtureJson.render();
        assertEq(keccak256(bytes(onDisk)), keccak256(bytes(fresh)), "sdk/test/fixtures.json is stale");
    }

    /// The rendered JSON parses, has one entry per corpus case, and round-trips the expectations.
    function test_fixtures_json_parses_and_round_trips() public view {
        string memory json = FixtureJson.render();
        HandleCorpus.Case[] memory c = HandleCorpus.cases();
        // one past the end must not exist
        assertEq(vm.parseJson(json, string.concat("$[", vm.toString(c.length), "]")).length, 0);
        for (uint256 i = 0; i < c.length; i++) {
            string memory idx = string.concat("$[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(json, string.concat(idx, ".input")), c[i].input);
            assertEq(vm.parseJsonString(json, string.concat(idx, ".reason")), c[i].reason);
            assertEq(vm.parseJsonString(json, string.concat(idx, ".source")), c[i].source);
            string memory key = string.concat(idx, ".canonical");
            if (keccak256(bytes(c[i].reason)) == keccak256("Ok")) {
                assertEq(vm.parseJsonString(json, key), c[i].canonical);
            } else {
                // JSON `null` decodes to a zero word (a *missing* key would be 0 bytes — asserted above)
                bytes memory raw = vm.parseJson(json, key);
                assertEq(raw.length, 32, "null canonical");
                assertEq(abi.decode(raw, (uint256)), 0, "null canonical");
            }
        }
    }

    function test_escape_solidity() public pure {
        assertEq(FixtureJson.escape("a\"b\\c"), "a\\\"b\\\\c");
        assertEq(FixtureJson.escape("\t\n\r\x08\x0c"), "\\t\\n\\r\\b\\f");
        assertEq(FixtureJson.escape("\x00\x1f"), "\\u0000\\u001f");
        assertEq(FixtureJson.escape(unicode"аlice"), unicode"аlice");
    }
}
