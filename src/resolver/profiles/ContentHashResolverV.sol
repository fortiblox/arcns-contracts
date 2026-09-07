// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Fork of @ensdomains/ens-contracts@v1.7.0 contracts/resolvers/profiles/ContentHashResolver.sol; sole change:
// version key = _versionOf(node) (bytes32) instead of recordVersions[node] (uint64).

import {IContentHashResolver} from "@ensdomains/ens-contracts/resolvers/profiles/IContentHashResolver.sol";
import {VersionedResolverBase} from "./VersionedResolverBase.sol";

abstract contract ContentHashResolverV is IContentHashResolver, VersionedResolverBase {
    mapping(bytes32 => mapping(bytes32 => bytes)) versionable_hashes;

    /// Sets the contenthash associated with an ENS node.
    /// May only be called by the owner of that node in the ENS registry.
    /// @param node The node to update.
    /// @param hash The contenthash to set
    function setContenthash(bytes32 node, bytes calldata hash) external virtual authorised(node) {
        versionable_hashes[_versionOf(node)][node] = hash;
        emit ContenthashChanged(node, hash);
    }

    /// Returns the contenthash associated with an ENS node.
    /// @param node The ENS node to query.
    /// @return The associated contenthash.
    function contenthash(bytes32 node) external view virtual override returns (bytes memory) {
        return versionable_hashes[_versionOf(node)][node];
    }

    function supportsInterface(bytes4 interfaceID) public view virtual override returns (bool) {
        return interfaceID == type(IContentHashResolver).interfaceId || super.supportsInterface(interfaceID);
    }
}
