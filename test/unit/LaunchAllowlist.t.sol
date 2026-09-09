// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {LaunchAllowlist} from "../../src/lib/LaunchAllowlist.sol";

/// @notice Unit tests for `LaunchAllowlist` (WP-144): leaf encoding matches OpenZeppelin's
///         `StandardMerkleTree` single-`address`-column layout, proof verification, and the
///         structural guarantee that an empty root never validates.
contract LaunchAllowlistTest is Test {
    function _pairHash(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function test_leaf_matches_standard_merkle_tree_double_hash() public pure {
        address who = address(0xBEEF);
        bytes32 expected = keccak256(bytes.concat(keccak256(abi.encode(who))));
        assertEq(LaunchAllowlist.leaf(who), expected);
    }

    function test_leaf_differs_per_address() public pure {
        assertTrue(LaunchAllowlist.leaf(address(1)) != LaunchAllowlist.leaf(address(2)));
    }

    function test_isAllowed_two_leaf_tree_both_sides() public pure {
        address a = address(0x1111);
        address b = address(0x2222);
        bytes32 leafA = LaunchAllowlist.leaf(a);
        bytes32 leafB = LaunchAllowlist.leaf(b);
        bytes32 root = _pairHash(leafA, leafB);

        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = leafB;
        assertTrue(LaunchAllowlist.isAllowed(root, proofA, a));

        bytes32[] memory proofB = new bytes32[](1);
        proofB[0] = leafA;
        assertTrue(LaunchAllowlist.isAllowed(root, proofB, b));
    }

    function test_isAllowed_four_leaf_tree() public pure {
        address[4] memory addrs = [address(0xA1), address(0xB2), address(0xC3), address(0xD4)];
        bytes32[4] memory leaves;
        for (uint256 i = 0; i < 4; i++) {
            leaves[i] = LaunchAllowlist.leaf(addrs[i]);
        }
        bytes32 node01 = _pairHash(leaves[0], leaves[1]);
        bytes32 node23 = _pairHash(leaves[2], leaves[3]);
        bytes32 root = _pairHash(node01, node23);

        bytes32[] memory proof0 = new bytes32[](2);
        proof0[0] = leaves[1];
        proof0[1] = node23;
        assertTrue(LaunchAllowlist.isAllowed(root, proof0, addrs[0]));

        bytes32[] memory proof3 = new bytes32[](2);
        proof3[0] = leaves[2];
        proof3[1] = node01;
        assertTrue(LaunchAllowlist.isAllowed(root, proof3, addrs[3]));
    }

    function test_isAllowed_rejects_wrong_owner_or_proof() public pure {
        address a = address(0x1111);
        address b = address(0x2222);
        address stranger = address(0x9999);
        bytes32 leafA = LaunchAllowlist.leaf(a);
        bytes32 leafB = LaunchAllowlist.leaf(b);
        bytes32 root = _pairHash(leafA, leafB);

        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = leafB;
        // right proof, wrong claimed owner
        assertFalse(LaunchAllowlist.isAllowed(root, proofA, stranger));
        // stranger not in the tree at all, empty proof
        bytes32[] memory empty = new bytes32[](0);
        assertFalse(LaunchAllowlist.isAllowed(root, empty, stranger));
    }

    /// @dev Structural guarantee: a zero root can only validate if `MerkleProof` computes a zero
    ///      hash, which requires a keccak256 preimage of zero — infeasible. `setAllowlist` also
    ///      never accepts a proof while the root is zero (allowlist is treated as inactive), but this
    ///      pins the library-level property independently of that call-site gate.
    function testFuzz_isAllowed_never_true_against_zero_root(address who, bytes32[] calldata proof) public pure {
        assertFalse(LaunchAllowlist.isAllowed(bytes32(0), proof, who));
    }

    function testFuzz_leaf_injective_on_distinct_addresses(address a, address b) public {
        vm.assume(a != b);
        assertTrue(LaunchAllowlist.leaf(a) != LaunchAllowlist.leaf(b));
    }
}
