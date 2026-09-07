// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Fork of @ensdomains/ens-contracts@v1.7.0 contracts/resolvers/profiles/AddrResolver.sol; sole change: version
// key = _versionOf(node) (bytes32) instead of recordVersions[node] (uint64).

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAddrResolver} from "@ensdomains/ens-contracts/resolvers/profiles/IAddrResolver.sol";
import {IAddressResolver} from "@ensdomains/ens-contracts/resolvers/profiles/IAddressResolver.sol";
import {IHasAddressResolver} from "@ensdomains/ens-contracts/resolvers/profiles/IHasAddressResolver.sol";
import {ENSIP19, COIN_TYPE_ETH, COIN_TYPE_DEFAULT} from "@ensdomains/ens-contracts/utils/ENSIP19.sol";
import {VersionedResolverBase} from "./VersionedResolverBase.sol";

abstract contract AddrResolverV is IAddrResolver, IAddressResolver, IHasAddressResolver, VersionedResolverBase {
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => bytes))) versionable_addresses;

    /// @notice The supplied address could not be converted to `address`.
    /// @dev Error selector: `0x8d666f60`
    error InvalidEVMAddress(bytes addressBytes);

    /// @notice Set `addr(60)` of the associated ENS node.
    ///         `address(0)` is stored as `new bytes(20)`.
    /// @param node The node to update.
    /// @param _addr The address to set.
    function setAddr(bytes32 node, address _addr) external virtual authorised(node) {
        setAddr(node, COIN_TYPE_ETH, abi.encodePacked(_addr));
    }

    /// @notice Get `addr(60)` as `address` of the associated ENS node.
    /// @param node The node to query.
    /// @return The associated address.
    function addr(bytes32 node) public view virtual override returns (address payable) {
        return payable(address(bytes20(addr(node, COIN_TYPE_ETH))));
    }

    /// @notice Set the address for coin type of the associated ENS node.
    ///         Reverts `InvalidEVMAddress` if coin type is EVM and not 0 or 20 bytes.
    /// @param node The node to update.
    /// @param coinType The coin type.
    /// @param addressBytes The address to set.
    function setAddr(bytes32 node, uint256 coinType, bytes memory addressBytes) public virtual authorised(node) {
        if (addressBytes.length != 0 && addressBytes.length != 20 && ENSIP19.isEVMCoinType(coinType)) {
            revert InvalidEVMAddress(addressBytes);
        }
        emit AddressChanged(node, coinType, addressBytes);
        if (coinType == COIN_TYPE_ETH) {
            emit AddrChanged(node, address(bytes20(addressBytes)));
        }
        versionable_addresses[_versionOf(node)][node][coinType] = addressBytes;
    }

    /// @notice Get the address for coin type of the associated ENS node.
    ///         If coin type is EVM and empty, defaults to `addr(COIN_TYPE_DEFAULT)`.
    /// @param node The node to query.
    /// @param coinType The coin type.
    /// @return addressBytes The assocated address.
    function addr(bytes32 node, uint256 coinType) public view virtual override returns (bytes memory addressBytes) {
        mapping(uint256 => bytes) storage addrs = versionable_addresses[_versionOf(node)][node];
        addressBytes = addrs[coinType];
        if (addressBytes.length == 0 && ENSIP19.chainFromCoinType(coinType) > 0) {
            addressBytes = addrs[COIN_TYPE_DEFAULT];
        }
    }

    /// @inheritdoc IHasAddressResolver
    function hasAddr(bytes32 node, uint256 coinType) external view returns (bool) {
        return versionable_addresses[_versionOf(node)][node][coinType].length > 0;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return type(IAddrResolver).interfaceId == interfaceId || type(IAddressResolver).interfaceId == interfaceId
            || type(IHasAddressResolver).interfaceId == interfaceId || super.supportsInterface(interfaceId);
    }
}
