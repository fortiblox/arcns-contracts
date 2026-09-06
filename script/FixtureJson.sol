// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HandleNormalize} from "../src/lib/HandleNormalize.sol";
import {HandleCorpus} from "../test/fixtures/HandleCorpus.sol";

/// @title FixtureJson — renders the conformance corpus as deterministic JSON
/// @notice Shared by `script/GenFixtures.s.sol` (writes `sdk/test/fixtures.json`) and
///         `test/unit/HandleCorpus.t.sol` (asserts the committed file is current). The JSON is
///         built by hand — no `vm.serializeJson` — so the byte layout depends only on the corpus
///         and this file: two runs on any machine produce identical bytes.
///         Values are what the **library** returns; the corpus expectations are asserted separately.
library FixtureJson {
    function render() internal pure returns (string memory json) {
        HandleCorpus.Case[] memory c = HandleCorpus.cases();
        bytes memory out = "[\n";
        for (uint256 i = 0; i < c.length; i++) {
            (string memory canonical, HandleNormalize.Reason r) = HandleNormalize.tryNormalize(c[i].input);
            out = bytes.concat(
                out,
                '  {"input": "',
                bytes(escape(c[i].input)),
                '", "canonical": ',
                r == HandleNormalize.Reason.Ok ? bytes.concat('"', bytes(escape(canonical)), '"') : bytes("null"),
                ', "reason": "',
                bytes(HandleNormalize.reasonName(r)),
                '", "source": "',
                bytes(escape(c[i].source)),
                i + 1 == c.length ? bytes('"}\n') : bytes('"},\n')
            );
        }
        return string(bytes.concat(out, "]\n"));
    }

    /// @dev JSON string escaping per RFC 8259 §7: `"`, `\`, and control characters < 0x20.
    ///      Bytes ≥ 0x80 are passed through (the corpus only contains valid UTF-8).
    function escape(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out;
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c == 0x22) out = bytes.concat(out, '\\"');
            else if (c == 0x5C) out = bytes.concat(out, "\\\\");
            else if (c == 0x08) out = bytes.concat(out, "\\b");
            else if (c == 0x09) out = bytes.concat(out, "\\t");
            else if (c == 0x0A) out = bytes.concat(out, "\\n");
            else if (c == 0x0C) out = bytes.concat(out, "\\f");
            else if (c == 0x0D) out = bytes.concat(out, "\\r");
            else if (c < 0x20) out = bytes.concat(out, "\\u00", _hex(c >> 4), _hex(c & 0x0F));
            else out = bytes.concat(out, b[i]);
        }
        return string(out);
    }

    function _hex(uint8 nibble) private pure returns (bytes1) {
        return nibble < 10 ? bytes1(nibble + 0x30) : bytes1(nibble + 0x57);
    }
}
