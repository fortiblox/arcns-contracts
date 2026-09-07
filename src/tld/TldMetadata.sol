// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ITldDirectory} from "../interfaces/ITldDirectory.sol";
import {ITldRegistrarController} from "../interfaces/ITldRegistrarController.sol";
import {NameMetadata} from "../lib/NameMetadata.sol";

/// @title ITldMetadata — the renderer a `TldRegistrar` delegates `tokenURI` / `contractURI` to
/// @dev Kept minimal so `TldRegistrar.sol` (OZ 4.9.3 inheritance graph) only imports this interface.
interface ITldMetadata {
    function tokenURI(address registrar, uint256 tokenId) external view returns (string memory);
    function contractURI(address registrar) external view returns (string memory);
}

/// @title TldMetadata — stateless on-chain metadata renderer shared by every TLD registrar (WP-143)
/// @notice Resolves `registrar → TLD row` through the directory, reads the human label back from the
///         TLD's controller (`labelOf(labelhash)`), and renders `<label>.<tld>` as JSON + SVG through
///         `NameMetadata`. The JSON `name` is always the display name, never a hex labelhash.
contract TldMetadata is ITldMetadata {
    /// @notice Thrown when no directory row lists `registrar`.
    error UnknownRegistrar(address registrar);
    /// @notice Thrown when the controller has no label for `tokenId` (never registered through it).
    error UnknownLabel(address registrar, uint256 tokenId);

    ITldDirectory public immutable directory;

    constructor(ITldDirectory directory_) {
        directory = directory_;
    }

    /// @inheritdoc ITldMetadata
    function tokenURI(address registrar, uint256 tokenId) external view returns (string memory) {
        ITldDirectory.Tld memory row = _rowOf(registrar);
        string memory label = ITldRegistrarController(row.controller).labelOf(bytes32(tokenId));
        if (bytes(label).length == 0) revert UnknownLabel(registrar, tokenId);
        string memory displayName = string.concat(label, ".", row.label);
        string memory attributes = string.concat(
            "[",
            NameMetadata.traitString("namespace", row.label),
            ",",
            NameMetadata.traitNumber("length", bytes(label).length),
            ",",
            NameMetadata.traitString("expires", "never"),
            "]"
        );
        return NameMetadata.tokenURI(displayName, _description(row.label), attributes, _accent(row.label));
    }

    /// @inheritdoc ITldMetadata
    function contractURI(address registrar) external view returns (string memory) {
        ITldDirectory.Tld memory row = _rowOf(registrar);
        return NameMetadata.contractURI(
            string.concat("arcns .", row.label, " names"), _description(row.label), _accent(row.label)
        );
    }

    /// @dev Linear scan over the directory: a handful of TLDs, view-only, called off-chain.
    function _rowOf(address registrar) private view returns (ITldDirectory.Tld memory row) {
        bytes32[] memory nodes = directory.tldNodes();
        for (uint256 i = 0; i < nodes.length; i++) {
            row = directory.get(nodes[i]);
            if (row.registrar == registrar) return row;
        }
        revert UnknownRegistrar(registrar);
    }

    function _description(string memory tld) private pure returns (string memory) {
        return string.concat("arcns .", tld, unicode" — a permanent ENS-compatible name on Arc.");
    }

    /// @dev Green for `.arc`, purple for `.circle`, blue for anything else.
    function _accent(string memory tld) private pure returns (string memory) {
        bytes32 h = keccak256(bytes(tld));
        if (h == keccak256("arc")) return "22c55e";
        if (h == keccak256("circle")) return "a855f7";
        return "3b82f6";
    }
}
