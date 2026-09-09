// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title LaunchAllowlist — WP-144, Merkle launch allowlist shared by every registration controller
/// @notice One leaf format for `HandleController` and every `TldRegistrarController` instance, so the
///         CEO's wallet list is built once (`sdk/src/allowlist.ts`, OpenZeppelin `StandardMerkleTree`
///         layout with a single `address` column) and the same root can be installed on all three
///         controllers. The leaf binds the registration's **`owner`** (the wallet that receives the
///         name), never `msg.sender`: registrations may be relayed (registration-as-a-service,
///         `docs/architecture/registration-as-a-service.md` §3.1 — `msg.sender` is a Circle SCA and
///         `owner` is the agent), so gating the caller would either lock relayed users out or let a
///         relayer on the list mint to anyone.
///
/// @dev Leaf = `keccak256(bytes.concat(keccak256(abi.encode(owner))))` — the OpenZeppelin
///      "standard" double-hashed leaf (second preimage resistant: an internal node can never be
///      presented as a leaf because leaves are 64-byte preimages and nodes are 64-byte pairs of
///      32-byte hashes, and the outer hash of a 32-byte value can never equal the hash of a 64-byte
///      pair). Proofs are verified with `MerkleProof.verifyCalldata` (commutative pair hashing).
///      An empty root means "no allowlist" and is never a valid root for any proof: `verifyCalldata`
///      against `bytes32(0)` can only succeed if the computed hash is zero, which is infeasible.
library LaunchAllowlist {
    /// @notice The allowlist leaf for `owner` (OpenZeppelin `StandardMerkleTree` `["address"]` encoding).
    function leaf(address owner) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(owner))));
    }

    /// @notice True iff `proof` proves `owner` is a leaf of the tree with root `root`.
    function isAllowed(bytes32 root, bytes32[] calldata proof, address owner) internal pure returns (bool) {
        return MerkleProof.verifyCalldata(proof, root, leaf(owner));
    }
}
