// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {FixtureJson} from "./FixtureJson.sol";

/// @title GenFixtures — WP-103
/// @notice Regenerates `sdk/test/fixtures.json` from `test/fixtures/HandleCorpus.sol` through the
///         production `HandleNormalize` library. Local, no broadcast, no RPC:
///
///             forge script script/GenFixtures.s.sol
///
///         CI runs it twice and `git diff --exit-code sdk/test/fixtures.json` proves determinism;
///         `test/unit/HandleCorpus.t.sol::test_fixtures_json_is_current` fails whenever the corpus
///         or the library changes without the file being regenerated.
///         `fs_permissions` in `foundry.toml` grants `read-write` on `../sdk/test` only.
contract GenFixtures is Script {
    string internal constant OUT = "../sdk/test/fixtures.json";

    function run() external {
        string memory json = FixtureJson.render();
        vm.writeFile(OUT, json);
    }
}
