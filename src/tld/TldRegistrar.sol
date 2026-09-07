// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Verbatim ens-contracts v1.7.0 registrar (OZ 4.9.3 through the `lib/ens-contracts/:` context
// remapping). This file deliberately imports nothing from OZ 5.x so the inheritance graph stays
// byte-for-byte the ENS one; `ITldMetadata` is a plain interface.
import {BaseRegistrarImplementation} from "@ensdomains/ens-contracts/ethregistrar/BaseRegistrarImplementation.sol";
import {ENS} from "@ensdomains/ens-contracts/registry/ENS.sol";

import {ITldMetadata} from "./TldMetadata.sol";

/// @title TldRegistrar — C4, one instance per TLD (`.arc`, `.circle`, …), tokenId = labelhash
/// @notice `BaseRegistrarImplementation` verbatim (register / available / reclaim / ownerOf /
///         expiries / controllers / GRACE_PERIOD are inherited untouched) plus the metadata surface
///         ENS leaves empty: `name()` / `symbol()` per TLD, `tokenURI` / `contractURI` delegated to
///         the shared `TldMetadata` renderer, and ERC-4906 `MetadataUpdate` that a controller may
///         emit after it stores the human label (WP-143). Ownable (OZ 4) owner = deployer; the deploy
///         script transfers ownership to the timelock.
contract TldRegistrar is BaseRegistrarImplementation {
    /// @notice ERC-4906: metadata of `_tokenId` changed (indexers refetch `tokenURI`). The upstream
    ///         `supportsInterface` is not virtual, so `0x49064906` cannot be advertised without editing
    ///         the verbatim registrar; the event signature is what indexers key on.
    event MetadataUpdate(uint256 _tokenId);

    /// @notice The shared on-chain metadata renderer.
    address public immutable metadata;

    string private _tldLabel;
    string private _symbol;

    /// @param ens_ the shared ENS registry (C3).
    /// @param baseNode_ `namehash(tldLabel_)`, the node this registrar owns.
    /// @param tldLabel_ the TLD label, e.g. `"arc"`.
    /// @param metadata_ the `TldMetadata` renderer.
    /// @param initialOwner Ownable owner (controller allow-list, resolver pointer). The verbatim base sets
    ///        `msg.sender`, which under the CREATE2 factory would be the factory itself; the deploy script
    ///        passes the deployer EOA and transfers ownership to the timelock once the controller is wired.
    constructor(ENS ens_, bytes32 baseNode_, string memory tldLabel_, address metadata_, address initialOwner)
        BaseRegistrarImplementation(ens_, baseNode_)
    {
        require(initialOwner != address(0), "TldRegistrar: owner=0");
        metadata = metadata_;
        _tldLabel = tldLabel_;
        _symbol = _upper(tldLabel_);
        if (initialOwner != msg.sender) _transferOwnership(initialOwner);
    }

    /// @notice The TLD label this registrar serves (`"arc"`, `"circle"`).
    function tldLabel() external view returns (string memory) {
        return _tldLabel;
    }

    /// @notice ERC-721 collection name: `arcns .arc names`.
    function name() public view override returns (string memory) {
        return string.concat("arcns .", _tldLabel, " names");
    }

    /// @notice ERC-721 symbol: the upper-cased label (`ARC`, `CIRCLE`).
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice Fully on-chain JSON + SVG for a registered name; reverts for unknown ids.
    function tokenURI(uint256 id) public view override returns (string memory) {
        require(_exists(id), "TldRegistrar: unknown token");
        return ITldMetadata(metadata).tokenURI(address(this), id);
    }

    /// @notice OpenSea-style collection metadata.
    function contractURI() external view returns (string memory) {
        return ITldMetadata(metadata).contractURI(address(this));
    }

    /// @notice Emit ERC-4906 `MetadataUpdate` for `id`; controllers only (they store the label).
    function emitMetadataUpdate(uint256 id) external onlyController {
        emit MetadataUpdate(id);
    }

    /// @dev ASCII upper-case; TLD labels are canonical `a-z0-9-` so nothing else needs mapping.
    function _upper(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 0x61 && c <= 0x7A) b[i] = bytes1(c - 0x20);
        }
        return string(b);
    }
}
