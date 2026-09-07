// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Fork of @ensdomains/ens-contracts@v1.7.0 contracts/resolvers/profiles/NameResolver.sol; sole change: version
// key = _versionOf(node) (bytes32) instead of recordVersions[node] (uint64).

import {INameResolver} from "@ensdomains/ens-contracts/resolvers/profiles/INameResolver.sol";
import {VersionedResolverBase} from "./VersionedResolverBase.sol";

abstract contract NameResolverV is INameResolver, VersionedResolverBase {
    mapping(bytes32 => mapping(bytes32 => string)) versionable_names;

    /// Sets the name associated with an ENS node, for reverse records.
    /// May only be called by the owner of that node in the ENS registry.
    /// @param node The node to update.
    function setName(bytes32 node, string calldata newName) external virtual authorised(node) {
        versionable_names[_versionOf(node)][node] = newName;
        emit NameChanged(node, newName);
    }

    /// Returns the name associated with an ENS node, for reverse records.
    /// Defined in EIP181.
    /// @param node The ENS node to query.
    /// @return The associated name.
    function name(bytes32 node) external view virtual override returns (string memory) {
        return versionable_names[_versionOf(node)][node];
    }

    function supportsInterface(bytes4 interfaceID) public view virtual override returns (bool) {
        return interfaceID == type(INameResolver).interfaceId || super.supportsInterface(interfaceID);
    }
}
