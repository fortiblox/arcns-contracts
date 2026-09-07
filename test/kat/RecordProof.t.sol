// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ResolverFixture} from "../resolver/mocks/ResolverFixture.sol";

/// @notice SR-41 EIP-712 record proof KAT: the digest is recomputed by hand (domain separator + struct hash) so
///         the SDK can mirror it byte for byte.
contract RecordProofKatTest is ResolverFixture {
    bytes32 internal constant EIP712DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant TYPEHASH =
        keccak256("RecordProof(bytes32 node,uint256 coinType,bytes32 version,string nonce)");
    /// @dev `cast keccak "RecordProof(bytes32 node,uint256 coinType,bytes32 version,string nonce)"`
    bytes32 internal constant TYPEHASH_PINNED = 0x30fb6cc353c8809c956d0f4f37b5d2fd6b80de2c79b99c1d0b86f0e9f6d03b14;
    bytes32 internal constant DIGEST_PINNED = 0xdf7072b5c7c9c6b7aa67a933adfa813e43415ae4eb6f680a7c005cf18b0ebd4a;

    function test_typehash_string() public view {
        assertEq(resolver.RECORD_PROOF_TYPEHASH(), TYPEHASH);
        assertEq(TYPEHASH, TYPEHASH_PINNED);
    }

    function test_eip712Domain_fields() public view {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying,,) =
            resolver.eip712Domain();
        assertEq(fields, hex"0f", "name, version, chainId, verifyingContract");
        assertEq(name, "arcns");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(resolver));
    }

    function test_digest_recomputed_by_hand() public {
        vm.chainId(5042002);
        (, bytes32 node) = _handle("alice", alice);
        bytes32 version = resolver.versionOf(node);
        bytes32 domain = keccak256(
            abi.encode(EIP712DOMAIN_TYPEHASH, keccak256("arcns"), keccak256("1"), uint256(5042002), address(resolver))
        );
        bytes32 structHash = keccak256(abi.encode(TYPEHASH, node, uint256(60), version, keccak256("n1")));
        bytes32 expected = keccak256(abi.encodePacked(hex"1901", domain, structHash));
        assertEq(resolver.recordProofDigest(node, 60, "n1"), expected);
        // and the version is the same key the records live under
        assertEq(version, keccak256(abi.encode(uint64(0), bytes32(uint256(1)))), "epoch 1, recordVersions 0");
    }

    /// @dev Fixed-input vector for the SDK: every input pinned, including the verifying contract.
    function test_fixed_vector() public pure {
        bytes32 node = 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20;
        bytes32 version = 0xffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100;
        address verifying = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01;
        bytes32 domain = keccak256(
            abi.encode(EIP712DOMAIN_TYPEHASH, keccak256("arcns"), keccak256("1"), uint256(5042002), verifying)
        );
        bytes32 structHash = keccak256(abi.encode(TYPEHASH, node, uint256(60), version, keccak256("n1")));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domain, structHash));
        assertEq(digest, DIGEST_PINNED);
    }
}
