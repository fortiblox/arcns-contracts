// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ArcNSConstants} from "../../../src/lib/ArcNSConstants.sol";

/// @dev The slice of IHandleRegistry the resolver reads, with setters that simulate C1's `_update` hook
///      (transfer / burn bump `epoch` by exactly 1) and the hard lock. Not an ERC-721.
contract MockHandleRegistry {
    struct H {
        address owner;
        uint64 epoch;
        bool locked;
        bool exists;
        string name;
    }

    mapping(uint256 => H) internal _h;
    mapping(bytes32 => uint256) public nodeToToken;
    mapping(bytes32 => uint256) public subnodeToToken;
    mapping(uint256 => mapping(address => bool)) internal _operators;

    error MockNoToken(uint256 tokenId);

    // ---- setters (simulate C1)

    function register(string memory name, address owner) external returns (uint256 tokenId, bytes32 node) {
        tokenId = ArcNSConstants.handleTokenId(name);
        node = ArcNSConstants.handleNode(name);
        _h[tokenId] = H({owner: owner, epoch: 1, locked: false, exists: true, name: name});
        nodeToToken[node] = tokenId;
    }

    function createSubname(uint256 tokenId, string memory label) external returns (bytes32 subnode) {
        subnode = ArcNSConstants.subHandleNode(ArcNSConstants.handleNode(_h[tokenId].name), label);
        subnodeToToken[subnode] = tokenId;
    }

    function transfer(uint256 tokenId, address to) external {
        _h[tokenId].owner = to;
        _h[tokenId].epoch += 1;
    }

    function burn(uint256 tokenId) external {
        delete nodeToToken[ArcNSConstants.handleNode(_h[tokenId].name)];
        _h[tokenId].owner = address(0);
        _h[tokenId].exists = false;
        _h[tokenId].epoch += 1;
    }

    function setLocked(uint256 tokenId, bool locked) external {
        _h[tokenId].locked = locked;
    }

    function setOperator(uint256 tokenId, address who, bool approved) external {
        _operators[tokenId][who] = approved;
    }

    // ---- views (IHandleRegistry subset)

    function tokenIdOf(string calldata name) external pure returns (uint256) {
        return ArcNSConstants.handleTokenId(name);
    }

    function nodeOf(string calldata name) external pure returns (bytes32) {
        return ArcNSConstants.handleNode(name);
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return _h[tokenId].exists;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        if (!_h[tokenId].exists) revert MockNoToken(tokenId);
        return _h[tokenId].owner;
    }

    function epochOf(uint256 tokenId) external view returns (uint64) {
        return _h[tokenId].epoch;
    }

    function isLocked(uint256 tokenId) external view returns (bool) {
        return _h[tokenId].locked;
    }

    function nameOf(uint256 tokenId) external view returns (string memory) {
        return _h[tokenId].name;
    }

    function isOwnerOrOperator(uint256 tokenId, address who) external view returns (bool) {
        H storage h = _h[tokenId];
        return h.exists && (h.owner == who || _operators[tokenId][who]);
    }
}
