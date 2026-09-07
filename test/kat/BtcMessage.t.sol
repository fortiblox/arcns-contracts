// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BtcMessage} from "../../src/lib/BtcMessage.sol";

/// @notice Port of the `btc.rs` unit tests: compact_size vectors, digest domain separation, and the
///         "private key = 1" pubkey -> hash160 -> scriptPubKey vector.
contract BtcMessageKatTest is Test {
    function test_compact_size_matches_bitcoin_varint_rules() public pure {
        assertEq(BtcMessage.compactSize(0), hex"00");
        assertEq(BtcMessage.compactSize(24), hex"18"); // the magic's own length
        assertEq(BtcMessage.compactSize(0xfc), hex"fc");
        assertEq(BtcMessage.compactSize(0xfd), hex"fdfd00");
        assertEq(BtcMessage.compactSize(0xffff), hex"fdffff");
        assertEq(BtcMessage.compactSize(0x1_0000), hex"fe00000100");
        assertEq(BtcMessage.compactSize(0xffffffff), hex"feffffffff");
        assertEq(BtcMessage.compactSize(0x1_0000_0000), hex"ff0000000001000000");
    }

    function test_message_digest_is_deterministic_and_domain_separated_from_raw_sha256() public pure {
        bytes32 a = BtcMessage.digest("x1-handles:v1:alice:0:n1");
        bytes32 b = BtcMessage.digest("x1-handles:v1:alice:0:n1");
        assertEq(a, b);
        assertNotEq(a, sha256("x1-handles:v1:alice:0:n1"), "must NOT equal a bare single sha256 of the message");
        assertNotEq(a, BtcMessage.digest("x1-handles:v1:alice:0:n2"), "distinct messages must not collide");
    }

    /// @dev Independent recomputation of the framing: 0x18 || magic || len || msg, double sha256.
    function test_message_digest_matches_explicit_framing() public pure {
        bytes memory msg_ = "hello";
        bytes memory framed = abi.encodePacked(hex"18", "Bitcoin Signed Message:\n", hex"05", msg_);
        assertEq(BtcMessage.digest(msg_), sha256(abi.encodePacked(sha256(framed))));
    }

    function test_compress_pubkey_picks_the_correct_parity_prefix() public pure {
        bytes memory even = new bytes(64);
        even[63] = 0x02;
        assertEq(uint8(BtcMessage.compress(even)[0]), 0x02);
        bytes memory odd = new bytes(64);
        odd[63] = 0x03;
        assertEq(uint8(BtcMessage.compress(odd)[0]), 0x03);
        assertEq(BtcMessage.compress(odd).length, 33);
    }

    function test_private_key_1_vector_hash160_and_scripts() public pure {
        bytes memory pubkey64 = abi.encodePacked(
            bytes32(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798),
            bytes32(0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)
        );
        bytes memory compressed = BtcMessage.compress(pubkey64);
        assertEq(compressed, hex"0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798");
        bytes20 h160 = BtcMessage.hash160(compressed);
        assertEq(h160, bytes20(hex"751e76e8199196d454941c45d1b3a323f1433bd6"));
        assertEq(BtcMessage.p2pkhScript(h160), hex"76a914751e76e8199196d454941c45d1b3a323f1433bd688ac");
        assertEq(BtcMessage.p2wpkhScript(h160), hex"0014751e76e8199196d454941c45d1b3a323f1433bd6");
    }
}
