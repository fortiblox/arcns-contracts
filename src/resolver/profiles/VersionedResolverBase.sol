// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Fork of @ensdomains/ens-contracts@v1.7.0 contracts/resolvers/ResolverBase.sol; sole change: version key =
// _versionOf(node). `recordVersions` and `clearRecords` are kept verbatim (the counter is folded into
// `_versionOf`); the `authorised` modifier reverts `IArcNSResolver.NotAuthorised` instead of a bare require and
// runs the virtual `_checkAuthorised` hook so the resolver can refuse writes under a retired TLD.

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IVersionableResolver} from "@ensdomains/ens-contracts/resolvers/profiles/IVersionableResolver.sol";
import {IArcNSResolver} from "../../interfaces/IArcNSResolver.sol";

abstract contract VersionedResolverBase is ERC165, IVersionableResolver {
    mapping(bytes32 => uint64) public recordVersions;

    function isAuthorised(bytes32 node) internal view virtual returns (bool);

    /// @dev The key every record of `node` is stored under. Folds `recordVersions[node]` with the
    ///      current ownership epoch of the name so a transfer makes old records unreachable (SR-12).
    function _versionOf(bytes32 node) internal view virtual returns (bytes32);

    /// @dev Reverts unless `msg.sender` may write records of `node`.
    function _checkAuthorised(bytes32 node) internal view virtual {
        if (!isAuthorised(node)) revert IArcNSResolver.NotAuthorised(node, msg.sender);
    }

    modifier authorised(bytes32 node) {
        _checkAuthorised(node);
        _;
    }

    /// Increments the record version associated with an ENS node.
    /// May only be called by the owner of that node in the ENS registry.
    /// @param node The node to update.
    function clearRecords(bytes32 node) public virtual authorised(node) {
        recordVersions[node]++;
        emit VersionChanged(node, recordVersions[node]);
    }

    function supportsInterface(bytes4 interfaceID) public view virtual override returns (bool) {
        return interfaceID == type(IVersionableResolver).interfaceId || super.supportsInterface(interfaceID);
    }
}
