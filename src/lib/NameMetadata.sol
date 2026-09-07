// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title NameMetadata — fully on-chain ERC-721 metadata (JSON + inline SVG) for arcns names
/// @notice Shared by `HandleRegistry` (`@alice`) and the TLD registrars (`alice.arc`, `bob.circle`)
///         so metadata never depends on a hosted API (T-NFT-5, WP-109, WP-143). The name is rendered
///         verbatim in the SVG; names are ASCII `a-z0-9-` plus the at-sign and dot separators, so no JSON or
///         XML escaping is required (asserted in tests). `attributes` is a caller-built JSON array.
library NameMetadata {
    using Strings for uint256;

    /// @dev Returns `data:application/json;base64,…` for one token.
    function tokenURI(
        string memory displayName,
        string memory description,
        string memory attributesJson,
        string memory accentHex
    ) internal pure returns (string memory) {
        bytes memory json = abi.encodePacked(
            '{"name":"',
            displayName,
            '","description":"',
            description,
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg(displayName, accentHex))),
            '","attributes":',
            attributesJson,
            "}"
        );
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }

    /// @dev Returns `data:application/json;base64,…` collection metadata (OpenSea `contractURI` shape).
    function contractURI(string memory collectionName, string memory description, string memory accentHex)
        internal
        pure
        returns (string memory)
    {
        bytes memory json = abi.encodePacked(
            '{"name":"',
            collectionName,
            '","description":"',
            description,
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg(collectionName, accentHex))),
            '"}'
        );
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }

    /// @dev 600×600 card: dark ground, accent bar, the name in a monospace face sized to fit.
    function svg(string memory displayName, string memory accentHex) internal pure returns (string memory) {
        uint256 len = bytes(displayName).length;
        // 600 px wide, 40 px margins each side ⇒ 520 px usable; monospace glyph ≈ 0.6 em.
        uint256 fontSize = len == 0 ? 64 : 520 * 10 / (6 * len);
        if (fontSize > 72) fontSize = 72;
        if (fontSize < 18) fontSize = 18;
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="600" viewBox="0 0 600 600">',
                '<rect width="600" height="600" fill="#0b0f19"/>',
                '<rect x="40" y="40" width="520" height="8" rx="4" fill="#',
                accentHex,
                '"/>',
                '<text x="40" y="118" font-family="Inter,Helvetica,Arial,sans-serif" font-size="22" fill="#9aa4b2">arcns</text>',
                '<text x="300" y="330" text-anchor="middle" font-family="ui-monospace,Menlo,Consolas,monospace" font-size="',
                fontSize.toString(),
                '" font-weight="700" fill="#f5f7fa">',
                displayName,
                "</text>",
                '<text x="40" y="540" font-family="Inter,Helvetica,Arial,sans-serif" font-size="18" fill="#9aa4b2">permanent name on Arc</text>',
                "</svg>"
            )
        );
    }

    /// @dev One `{"trait_type":…,"value":…}` entry with a string value.
    function traitString(string memory traitType, string memory value) internal pure returns (string memory) {
        return string(abi.encodePacked('{"trait_type":"', traitType, '","value":"', value, '"}'));
    }

    /// @dev One `{"trait_type":…,"value":N}` entry with a numeric value.
    function traitNumber(string memory traitType, uint256 value) internal pure returns (string memory) {
        return string(abi.encodePacked('{"trait_type":"', traitType, '","value":', value.toString(), "}"));
    }
}
