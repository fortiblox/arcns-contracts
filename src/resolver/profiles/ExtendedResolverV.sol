// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Fork of @ensdomains/ens-contracts@v1.7.0 contracts/resolvers/profiles/ExtendedResolver.sol; sole change: the
// DNS-encoded `name` is no longer ignored — its namehash must equal the node inside `data` (the
// `multicallWithNodeCheck` rule) and the TLD label is handed to the virtual `_checkResolvable` hook so a retired
// TLD can refuse resolution (SR-09). No CCIP-Read, no OffchainLookup, no wildcard (SR-24).

import {IExtendedResolver} from "@ensdomains/ens-contracts/resolvers/profiles/IExtendedResolver.sol";
import {NameCoder} from "@ensdomains/ens-contracts/utils/NameCoder.sol";

abstract contract ExtendedResolverV is IExtendedResolver {
    /// @notice `data` addresses a node other than `namehash(name)`.
    error ResolveNodeMismatch(bytes32 nameNode, bytes32 dataNode);

    function resolve(bytes calldata name, bytes calldata data) external view virtual returns (bytes memory) {
        (bytes32 node, bytes32 tldNode) = _decodeName(name);
        _checkResolvable(tldNode);
        bytes32 dataNode = data.length >= 36 ? bytes32(data[4:36]) : bytes32(0);
        if (data.length < 36 || dataNode != node) revert ResolveNodeMismatch(node, dataNode);
        (bool success, bytes memory result) = address(this).staticcall(data);
        if (success) {
            return result;
        } else {
            // Revert with the reason provided by the call
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    /// @dev Hook: revert when names under `tldNode` must not resolve. `tldNode == 0` for the root name.
    function _checkResolvable(bytes32 tldNode) internal view virtual {}

    /// @dev namehash of the whole DNS-encoded name and the node of its last (TLD) label.
    function _decodeName(bytes memory name) internal pure returns (bytes32 node, bytes32 tldNode) {
        node = NameCoder.namehash(name, 0);
        uint256 offset = 0;
        bytes32 last;
        while (true) {
            (bytes32 labelHash, uint256 next) = NameCoder.readLabel(name, offset);
            if (labelHash == bytes32(0)) break;
            last = labelHash;
            offset = next;
        }
        if (last != bytes32(0)) tldNode = NameCoder.namehash(bytes32(0), last);
    }
}
