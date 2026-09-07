// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ENS} from "@ensdomains/ens-contracts/registry/ENS.sol";

import {ITldDirectory} from "../../../src/interfaces/ITldDirectory.sol";

/// @notice Test double for the arcns resolver (C7) exposing exactly what the TLD controller and the
///         verbatim `ReverseRegistrar` call: `tagNode` / `tldOf` / `tokenIdOfNode`, the ENS
///         `setAddr(bytes32,uint256,bytes)` / `addr(bytes32,uint256)`, `setText` / `text`,
///         `setName(bytes32,string)` / `name(bytes32)` and `multicallWithNodeCheck`.
///
///         The trusted-caller rule mirrors the real resolver: any address the directory reports as a
///         TLD controller, the reverse registrar, or the ENS owner of the node may write. `tagNode`
///         additionally requires the caller to be the controller of that very `tldNode`. Reads of a
///         tagged node whose TLD is no longer `resolvable` return empty (onchain-design §3.5).
contract MockResolver {
    event AddressChanged(bytes32 indexed node, uint256 coinType, bytes newAddress);
    event NameChanged(bytes32 indexed node, string name);
    event TextChanged(bytes32 indexed node, string indexed indexedKey, string key, string value);
    event NodeTagged(bytes32 indexed node, bytes32 indexed tldNode, uint256 tokenId);

    error NotAuthorised(bytes32 node, address caller);
    error NotTldController(bytes32 tldNode, address caller);

    ENS public immutable ens;
    ITldDirectory public immutable directory;
    address public immutable reverseRegistrar;

    mapping(bytes32 node => bytes32 tldNode) public tldOf;
    mapping(bytes32 node => uint256 tokenId) public tokenIdOfNode;

    mapping(bytes32 node => mapping(uint256 coinType => bytes)) private _addrs;
    mapping(bytes32 node => mapping(string key => string)) private _texts;
    mapping(bytes32 node => string) private _names;

    constructor(ENS ens_, ITldDirectory directory_, address reverseRegistrar_) {
        ens = ens_;
        directory = directory_;
        reverseRegistrar = reverseRegistrar_;
    }

    modifier authorised(bytes32 node) {
        if (!isAuthorised(node, msg.sender)) revert NotAuthorised(node, msg.sender);
        _;
    }

    function isAuthorised(bytes32 node, address who) public view returns (bool) {
        return who == reverseRegistrar || directory.isController(who) || ens.owner(node) == who;
    }

    // ---- node tagging -----------------------------------------------------------------------------

    function tagNode(bytes32 node, bytes32 tldNode, uint256 tokenId) external {
        if (directory.tldNodeOfController(msg.sender) != tldNode || tldNode == bytes32(0)) {
            revert NotTldController(tldNode, msg.sender);
        }
        tldOf[node] = tldNode;
        tokenIdOfNode[node] = tokenId;
        emit NodeTagged(node, tldNode, tokenId);
    }

    // ---- ENSIP-9 addr -----------------------------------------------------------------------------

    function setAddr(bytes32 node, uint256 coinType, bytes calldata a) external authorised(node) {
        _addrs[node][coinType] = a;
        emit AddressChanged(node, coinType, a);
    }

    function addr(bytes32 node, uint256 coinType) external view returns (bytes memory) {
        if (!_readable(node)) return "";
        return _addrs[node][coinType];
    }

    // ---- text -------------------------------------------------------------------------------------

    function setText(bytes32 node, string calldata key, string calldata value) external authorised(node) {
        _texts[node][key] = value;
        emit TextChanged(node, key, key, value);
    }

    function text(bytes32 node, string calldata key) external view returns (string memory) {
        if (!_readable(node)) return "";
        return _texts[node][key];
    }

    // ---- name (reverse) ---------------------------------------------------------------------------

    function setName(bytes32 node, string calldata newName) external authorised(node) {
        _names[node] = newName;
        emit NameChanged(node, newName);
    }

    function name(bytes32 node) external view returns (string memory) {
        return _names[node];
    }

    // ---- multicall (verbatim `Multicallable._multicall` semantics) ---------------------------------

    function multicallWithNodeCheck(bytes32 nodehash, bytes[] calldata data) external returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            require(bytes32(data[i][4:36]) == nodehash, "multicall: All records must have a matching namehash");
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);
            require(success, "multicall: call failed");
            results[i] = result;
        }
    }

    function _readable(bytes32 node) private view returns (bool) {
        bytes32 t = tldOf[node];
        return t == bytes32(0) || directory.resolvable(t);
    }
}
