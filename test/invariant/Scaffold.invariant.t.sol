// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {HandleNormalize} from "../../src/lib/HandleNormalize.sol";

/// @dev Handler for the M0 placeholder: feeds arbitrary strings through the library and keeps
///      ghost counters. Replaced/joined by real handlers per test/invariant/README.md.
contract NormalizeHandler {
    uint256 public calls;
    uint256 public accepted;
    uint256 public canonicalOutputs;

    function feed(string calldata raw) external {
        calls++;
        (string memory n, bool ok) = HandleNormalize.normalize(raw);
        if (!ok) return;
        accepted++;
        if (HandleNormalize.isCanonical(n)) canonicalOutputs++;
    }
}

/// @notice M0 scaffold so `forge test --match-path 'test/invariant/*'` is wired end-to-end.
///         The only real property here is INV-10's local half: every accepted output is canonical.
contract ScaffoldInvariantTest is Test {
    NormalizeHandler internal handler;

    function setUp() public {
        handler = new NormalizeHandler();
        targetContract(address(handler));
    }

    function invariant_INV10_accepted_outputs_are_canonical() public view {
        assertEq(handler.accepted(), handler.canonicalOutputs());
        assertLe(handler.accepted(), handler.calls());
    }
}
