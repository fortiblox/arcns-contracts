// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Challenge} from "../../src/lib/Challenge.sol";
import {IArcNSResolver} from "../../src/interfaces/IArcNSResolver.sol";

/// @notice Exact-string KAT for the SR-41 record challenge; the SDK mirrors these bytes.
contract ChallengeKatTest is Test {
    bytes32 internal constant NODE = 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20;
    bytes32 internal constant KEY = 0xffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100;
    address internal constant RESOLVER = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01;

    function test_exact_string() public pure {
        string memory c = Challenge.build(NODE, 60, KEY, 5042002, RESOLVER, "n1");
        assertEq(
            c,
            "arcns:v1:rec:0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20:60:0xffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100:5042002:0xabcdef0123456789abcdef0123456789abcdef01:n1"
        );
    }

    function test_zero_fields_are_zero_padded() public pure {
        string memory c = Challenge.build(bytes32(0), 0, bytes32(0), 1, address(0), "Z");
        assertEq(
            c,
            "arcns:v1:rec:0x0000000000000000000000000000000000000000000000000000000000000000:0:0x0000000000000000000000000000000000000000000000000000000000000000:1:0x0000000000000000000000000000000000000000:Z"
        );
    }

    function test_every_field_binds() public pure {
        string memory base = Challenge.build(NODE, 60, KEY, 5042002, RESOLVER, "n1");
        assertNotEq(base, Challenge.build(bytes32(uint256(NODE) + 1), 60, KEY, 5042002, RESOLVER, "n1"));
        assertNotEq(base, Challenge.build(NODE, 0, KEY, 5042002, RESOLVER, "n1"));
        assertNotEq(base, Challenge.build(NODE, 60, bytes32(uint256(KEY) - 1), 5042002, RESOLVER, "n1"));
        assertNotEq(base, Challenge.build(NODE, 60, KEY, 1, RESOLVER, "n1"));
        assertNotEq(base, Challenge.build(NODE, 60, KEY, 5042002, address(1), "n1"));
        assertNotEq(base, Challenge.build(NODE, 60, KEY, 5042002, RESOLVER, "n2"));
    }

    function test_nonce_64_alphanumeric_accepted() public pure {
        bytes memory n = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            n[i] = i % 3 == 0 ? bytes1("a") : (i % 3 == 1 ? bytes1("Z") : bytes1("9"));
        }
        assertTrue(Challenge.isValidNonce(string(n)));
        Challenge.build(NODE, 60, KEY, 5042002, RESOLVER, string(n));
    }

    function test_bad_nonce_empty() public {
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.BadNonce.selector, ""));
        this.build("");
    }

    function test_bad_nonce_65_chars() public {
        bytes memory n = new bytes(65);
        for (uint256 i = 0; i < 65; i++) {
            n[i] = "x";
        }
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.BadNonce.selector, string(n)));
        this.build(string(n));
    }

    function test_bad_nonce_hyphen() public {
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.BadNonce.selector, "a-b"));
        this.build("a-b");
    }

    function test_bad_nonce_colon() public {
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.BadNonce.selector, "has:colon"));
        this.build("has:colon");
    }

    function test_bad_nonce_space_and_non_ascii() public {
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.BadNonce.selector, "has space"));
        this.build("has space");
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.BadNonce.selector, unicode"nö"));
        this.build(unicode"nö");
    }

    function build(string calldata nonce) external pure returns (string memory) {
        return Challenge.build(NODE, 60, KEY, 5042002, RESOLVER, nonce);
    }
}
