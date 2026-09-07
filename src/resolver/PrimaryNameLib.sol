// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ArcNSConstants} from "../lib/ArcNSConstants.sol";
import {HandleNormalize} from "../lib/HandleNormalize.sol";

/// @title PrimaryNameLib — parse a reverse `name()` string into the namespace it claims (onchain-design §3.4)
/// @notice One reverse node per address serves all three namespaces. The string is only a claim; the resolver
///         confirms it forward (at-sign handle ⇒ `HandleRegistry.ownerOf`, `alice.arc` ⇒ `addr(node, coinType)`),
///         SR-07 / SR-23. This library is the pure half: reverse-node derivation and strict parsing. Anything
///         that is not exactly an at-sign followed by one canonical label, or two / three canonical labels joined
///         by dots, parses as nothing.
library PrimaryNameLib {
    /// @dev Namespace tags returned by `parse` (mirror `IArcNSResolver.primaryOf`'s second return value).
    uint8 internal constant NS_NONE = 0;
    uint8 internal constant NS_HANDLE = 1;
    uint8 internal constant NS_TLD = 2;

    bytes32 private constant HEX_LOOKUP = 0x3031323334353637383961626364656600000000000000000000000000000000;

    struct Parsed {
        uint8 namespace; // NS_NONE / NS_HANDLE / NS_TLD
        string handle; // canonical handle without the at-sign (NS_HANDLE only)
        bytes32 node; // namehash of the name (NS_TLD only)
        bytes32 tldNode; // namehash of the last label (NS_TLD only)
    }

    /// @notice `<lowercase-hex-addr>.addr.reverse` node of `addr` (verbatim ReverseRegistrar derivation).
    function reverseNode(address addr) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(ArcNSConstants.ADDR_REVERSE_NODE, sha3HexAddress(addr)));
    }

    /// @dev sha3 of the lower-case hexadecimal representation of an address (copied from ReverseRegistrar.sol).
    function sha3HexAddress(address addr) internal pure returns (bytes32 ret) {
        assembly ("memory-safe") {
            let lookup := HEX_LOOKUP
            for { let i := 40 } gt(i, 0) {} {
                i := sub(i, 1)
                mstore8(i, byte(and(addr, 0xf), lookup))
                addr := div(addr, 0x10)
                i := sub(i, 1)
                mstore8(i, byte(and(addr, 0xf), lookup))
                addr := div(addr, 0x10)
            }
            ret := keccak256(0, 40)
        }
    }

    /// @notice Strict parse of a reverse string. Never reverts; `namespace == NS_NONE` for anything malformed.
    function parse(string memory s) public pure returns (Parsed memory p) {
        bytes memory b = bytes(s);
        if (b.length == 0) return p;
        if (b[0] == "@") {
            bytes memory rest = new bytes(b.length - 1);
            for (uint256 i = 1; i < b.length; i++) {
                rest[i - 1] = b[i];
            }
            if (!HandleNormalize.isCanonical(string(rest))) return p;
            p.namespace = NS_HANDLE;
            p.handle = string(rest);
            return p;
        }
        // split on '.': 2 or 3 labels, every label canonical
        uint256[4] memory starts;
        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ".") {
                if (count == 3) return p; // 4+ labels
                starts[count++] = i + 1;
            }
        }
        if (count < 2) return p;
        starts[count] = b.length + 1;
        bytes32 node = bytes32(0);
        for (uint256 l = count; l > 0; l--) {
            uint256 from = starts[l - 1];
            uint256 to = starts[l] - 1;
            if (to <= from) return p; // empty label
            bytes memory label = new bytes(to - from);
            for (uint256 i = from; i < to; i++) {
                label[i - from] = b[i];
            }
            if (!HandleNormalize.isCanonical(string(label))) return p;
            node = keccak256(abi.encodePacked(node, keccak256(label)));
            if (l == count) p.tldNode = node;
        }
        p.namespace = NS_TLD;
        p.node = node;
    }
}
