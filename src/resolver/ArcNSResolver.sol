// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {ENS} from "@ensdomains/ens-contracts/registry/ENS.sol";
import {Multicallable} from "@ensdomains/ens-contracts/resolvers/Multicallable.sol";
import {IMulticallable} from "@ensdomains/ens-contracts/resolvers/IMulticallable.sol";
import {IExtendedResolver} from "@ensdomains/ens-contracts/resolvers/profiles/IExtendedResolver.sol";
import {COIN_TYPE_ETH} from "@ensdomains/ens-contracts/utils/ENSIP19.sol";
import {IArcNSResolver} from "../interfaces/IArcNSResolver.sol";
import {IHandleRegistry} from "../interfaces/IHandleRegistry.sol";
import {ITldDirectory} from "../interfaces/ITldDirectory.sol";
import {ArcNSConstants} from "../lib/ArcNSConstants.sol";
import {AddrResolverV} from "./profiles/AddrResolverV.sol";
import {TextResolverV} from "./profiles/TextResolverV.sol";
import {ContentHashResolverV} from "./profiles/ContentHashResolverV.sol";
import {NameResolverV} from "./profiles/NameResolverV.sol";
import {ExtendedResolverV} from "./profiles/ExtendedResolverV.sol";
import {VerifiedAddrResolver} from "./VerifiedAddrResolver.sol";
import {PrimaryNameLib} from "./PrimaryNameLib.sol";

/// @title ArcNSResolver — C7, the one resolver shared by handles, `.arc` and `.circle` (onchain-design §3.3)
/// @notice ENS profiles in ABI terms (events verbatim: AddressChanged, AddrChanged, TextChanged,
///         ContenthashChanged, NameChanged, VersionChanged, Approved, ApprovalForAll) with record storage keyed by
///         `versionOf(node)`: handle nodes fold in `HandleRegistry.epochOf`, tagged TLD nodes the registrar's
///         current `ownerOf`, everything else the ENS registry owner (SR-12, INV-2). A Retired / past-sunset TLD
///         maps to the dead key `bytes32(0)` that nothing is ever written under, so its names go dark (SR-09).
///         Authority (§2.1): directory controllers and the reverse registrar are trusted (ENS pattern); handle
///         nodes ask C1 (`isOwnerOrOperator`, locked ⇒ never); tagged TLD nodes ask the registrar's `ownerOf`;
///         plain ENS nodes ask the registry. Per-name delegates (`approve`) and operators are the PublicResolver
///         pattern, keyed by owner so a transfer starts with none.
// `Multicallable` (verbatim ens-contracts, OZ 4.9.3 ERC165) is listed first so that it sits last in the C3
// linearization: the `super.supportsInterface` chain then runs through our OZ 5.6.1 mixins and stops in the OZ 5
// ERC165, while `IMulticallable` is reported explicitly below.
contract ArcNSResolver is
    Multicallable,
    VerifiedAddrResolver,
    TextResolverV,
    ContentHashResolverV,
    NameResolverV,
    ExtendedResolverV,
    AccessControl
{
    ENS public immutable ens;
    IHandleRegistry public immutable handles;
    ITldDirectory public immutable directory;
    address public immutable reverseRegistrar;

    /// @inheritdoc IArcNSResolver
    mapping(bytes32 => bytes32) public override tldOf;
    /// @inheritdoc IArcNSResolver
    mapping(bytes32 => uint256) public override tokenIdOfNode;

    /// A mapping of operators. An address that is authorised for an address
    /// may make any changes to the name that the owner could, but may not update
    /// the set of authorisations.
    /// (owner, operator) => approved
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    /// A mapping of delegates. A delegate that is authorised by an owner
    /// for a name may make changes to the name's resolver, but may not update
    /// the set of token approvals.
    /// (owner, name, delegate) => approved
    mapping(address => mapping(bytes32 => mapping(address => bool))) private _tokenApprovals;

    // Logged when an operator is added or removed.
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    // Logged when a delegate is approved or  an approval is revoked.
    event Approved(address owner, bytes32 indexed node, address indexed delegate, bool indexed approved);

    constructor(
        ENS _ens,
        IHandleRegistry _handles,
        ITldDirectory _directory,
        address _reverseRegistrar,
        address admin
    ) {
        ens = _ens;
        handles = _handles;
        directory = _directory;
        reverseRegistrar = _reverseRegistrar;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---------------------------------------------------------------------------------------------
    // approvals (verbatim PublicResolver v1.7.0 pattern)
    // ---------------------------------------------------------------------------------------------

    /// @dev See {IERC1155-setApprovalForAll}.
    function setApprovalForAll(address operator, bool approved) external {
        require(msg.sender != operator, "ERC1155: setting approval status for self");
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /// @dev See {IERC1155-isApprovedForAll}.
    function isApprovedForAll(address account, address operator) public view returns (bool) {
        return _operatorApprovals[account][operator];
    }

    /// @dev Approve a delegate to be able to updated records on a node.
    function approve(bytes32 node, address delegate, bool approved) external {
        require(msg.sender != delegate, "Setting delegate status for self");
        _tokenApprovals[msg.sender][node][delegate] = approved;
        emit Approved(msg.sender, node, delegate, approved);
    }

    /// @dev Check to see if the delegate has been approved by the owner for the node.
    function isApprovedFor(address owner, bytes32 node, address delegate) public view returns (bool) {
        return _tokenApprovals[owner][node][delegate];
    }

    // ---------------------------------------------------------------------------------------------
    // node tagging (onchain-design §3.5)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSResolver
    function tagNode(bytes32 node, bytes32 tldNode, uint256 tokenId) external override {
        if (tldNode == bytes32(0) || directory.tldNodeOfController(msg.sender) != tldNode) {
            revert NotTldController(tldNode, msg.sender);
        }
        bytes32 current = tldOf[node];
        // a node belongs to exactly one TLD; only that TLD's controller may re-tag it
        if (current != bytes32(0) && current != tldNode) revert NotTldController(current, msg.sender);
        tldOf[node] = tldNode;
        tokenIdOfNode[node] = tokenId;
        emit NodeTagged(node, tldNode, tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // version / authority
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSResolver
    function versionOf(bytes32 node) external view override returns (bytes32) {
        return _versionOf(node);
    }

    /// @inheritdoc IArcNSResolver
    function namespaceOf(bytes32 node) external view override returns (uint8) {
        (uint8 ns,,) = _classify(node);
        return ns;
    }

    /// @inheritdoc IArcNSResolver
    function isAuthorisedFor(bytes32 node, address who) public view override returns (bool) {
        if (directory.isController(who) || who == reverseRegistrar) return true;
        (uint8 ns, uint256 tokenId, bytes32 tld) = _classify(node);
        if (ns == 1) {
            if (handles.isLocked(tokenId) || !handles.exists(tokenId)) return false;
            if (handles.isOwnerOrOperator(tokenId, who)) return true;
            return isApprovedFor(handles.ownerOf(tokenId), node, who);
        }
        if (ns == 2) {
            if (!directory.resolvable(tld)) return false;
            address registrar = directory.registrarOf(tld);
            address owner = _tldOwner(registrar, tokenId);
            if (owner == address(0)) return false;
            return owner == who || IERC721(registrar).isApprovedForAll(owner, who) || isApprovedForAll(owner, who)
                || isApprovedFor(owner, node, who);
        }
        address ensOwner = ens.owner(node);
        if (ensOwner == address(0)) return false;
        return ensOwner == who || ens.isApprovedForAll(ensOwner, who) || isApprovedForAll(ensOwner, who)
            || isApprovedFor(ensOwner, node, who);
    }

    function isAuthorised(bytes32 node) internal view override returns (bool) {
        return isAuthorisedFor(node, msg.sender);
    }

    /// @dev Writes under a retired / past-sunset TLD revert `TldNotResolvable` before the authority check.
    function _checkAuthorised(bytes32 node) internal view override {
        _checkResolvableNode(node);
        super._checkAuthorised(node);
    }

    function _checkResolvableNode(bytes32 node) internal view override {
        bytes32 tld = tldOf[node];
        if (tld != bytes32(0) && !directory.resolvable(tld)) revert TldNotResolvable(tld);
    }

    /// @dev ENSIP-10: a name whose TLD row exists but is no longer resolvable must not resolve (SR-09).
    function _checkResolvable(bytes32 tldNode) internal view override {
        if (
            tldNode != bytes32(0) && directory.statusOf(tldNode) != ITldDirectory.TldStatus.Unknown
                && !directory.resolvable(tldNode)
        ) revert TldNotResolvable(tldNode);
    }

    /// @dev keccak256(recordVersions[node] ‖ ownerSalt(node)); bytes32(0) (the dead key) for a dark TLD node.
    function _versionOf(bytes32 node) internal view override returns (bytes32) {
        (uint8 ns, uint256 tokenId, bytes32 tld) = _classify(node);
        bytes32 salt;
        if (ns == 1) {
            salt = bytes32(uint256(handles.epochOf(tokenId)));
        } else if (ns == 2) {
            if (!directory.resolvable(tld)) return bytes32(0);
            salt = bytes32(uint256(uint160(_tldOwner(directory.registrarOf(tld), tokenId))));
        } else {
            salt = bytes32(uint256(uint160(ens.owner(node))));
        }
        return keccak256(abi.encode(recordVersions[node], salt));
    }

    /// @dev (namespace, tokenId, tldNode): 1 = handle or sub-handle (tokenId of the handle), 2 = tagged TLD name,
    ///      0 = plain ENS node. Structural lookup order: C1 first, then the tag (onchain-design §2.1).
    function _classify(bytes32 node) internal view returns (uint8 ns, uint256 tokenId, bytes32 tld) {
        tokenId = handles.nodeToToken(node);
        if (tokenId != 0) return (1, tokenId, bytes32(0));
        tokenId = handles.subnodeToToken(node);
        if (tokenId != 0) return (1, tokenId, bytes32(0));
        tld = tldOf[node];
        if (tld != bytes32(0)) return (2, tokenIdOfNode[node], tld);
        return (0, 0, bytes32(0));
    }

    /// @dev Registrar `ownerOf`, `address(0)` when burned / unknown (T-NFT-1: a burned token has no records).
    function _tldOwner(address registrar, uint256 tokenId) internal view returns (address) {
        if (registrar == address(0)) return address(0);
        try IERC721(registrar).ownerOf(tokenId) returns (address owner) {
            return owner;
        } catch {
            return address(0);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // primary name (onchain-design §3.4, SR-07 / SR-23)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSResolver
    function primaryOf(address addr_) external view override returns (string memory, uint8) {
        bytes32 rnode = PrimaryNameLib.reverseNode(addr_);
        string memory s = versionable_names[_versionOf(rnode)][rnode];
        PrimaryNameLib.Parsed memory p = PrimaryNameLib.parse(s);
        if (p.namespace == PrimaryNameLib.NS_HANDLE) {
            uint256 tokenId = handles.tokenIdOf(p.handle);
            if (handles.exists(tokenId) && handles.ownerOf(tokenId) == addr_) return (s, PrimaryNameLib.NS_HANDLE);
            return ("", 0);
        }
        if (p.namespace == PrimaryNameLib.NS_TLD) {
            if (directory.statusOf(p.tldNode) == ITldDirectory.TldStatus.Unknown || !directory.resolvable(p.tldNode)) {
                return ("", 0);
            }
            if (_addrIs(p.node, ArcNSConstants.evmCoinType(), addr_) || _addrIs(p.node, COIN_TYPE_ETH, addr_)) {
                return (s, PrimaryNameLib.NS_TLD);
            }
        }
        return ("", 0);
    }

    function _addrIs(bytes32 node, uint256 coinType, address who) internal view returns (bool) {
        bytes memory a = addr(node, coinType);
        return a.length == 20 && address(bytes20(a)) == who;
    }

    // ---------------------------------------------------------------------------------------------
    // governance
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSResolver
    function setEd25519Enabled(uint256 coinType, bool enabled) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _setEd25519Enabled(coinType, enabled);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-165
    // ---------------------------------------------------------------------------------------------

    function supportsInterface(bytes4 interfaceID)
        public
        view
        override(AddrResolverV, TextResolverV, ContentHashResolverV, NameResolverV, AccessControl, Multicallable)
        returns (bool)
    {
        return interfaceID == type(IExtendedResolver).interfaceId || interfaceID == type(IArcNSResolver).interfaceId
            || interfaceID == type(IMulticallable).interfaceId || interfaceID == type(IERC5267).interfaceId
            || super.supportsInterface(interfaceID);
    }
}
