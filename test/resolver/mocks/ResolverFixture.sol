// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ENSRegistry} from "@ensdomains/ens-contracts/registry/ENSRegistry.sol";
import {ArcNSResolver} from "../../../src/resolver/ArcNSResolver.sol";
import {IHandleRegistry} from "../../../src/interfaces/IHandleRegistry.sol";
import {ArcNSConstants} from "../../../src/lib/ArcNSConstants.sol";
import {HandleNormalize} from "../../../src/lib/HandleNormalize.sol";
import {MockHandleRegistry} from "./MockHandleRegistry.sol";
import {MockTldDirectory} from "./MockTldDirectory.sol";
import {MockTldRegistrar} from "./MockTldRegistrar.sol";

/// @dev Shared deployment: real ENSRegistry, mock C1 / C3a / C4s, the resolver, and named actors.
abstract contract ResolverFixture is Test {
    ENSRegistry internal registry;
    MockHandleRegistry internal handles;
    MockTldDirectory internal directory;
    MockTldRegistrar internal arcRegistrar;
    MockTldRegistrar internal circleRegistrar;
    ArcNSResolver internal resolver;

    address internal admin = makeAddr("admin");
    address internal reverseAddr = makeAddr("reverseRegistrar");
    address internal arcController = makeAddr("arcController");
    address internal circleController = makeAddr("circleController");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal delegate = makeAddr("delegate");

    bytes32 internal constant ARC = ArcNSConstants.ARC_NODE;
    bytes32 internal constant CIRCLE = ArcNSConstants.CIRCLE_NODE;

    function setUp() public virtual {
        vm.warp(1_757_000_000);
        registry = new ENSRegistry();
        handles = new MockHandleRegistry();
        directory = new MockTldDirectory();
        arcRegistrar = new MockTldRegistrar("arc");
        circleRegistrar = new MockTldRegistrar("circle");
        directory.add(ARC, "arc", address(arcRegistrar), arcController, ARC);
        directory.add(CIRCLE, "circle", address(circleRegistrar), circleController, CIRCLE);
        resolver = new ArcNSResolver(registry, IHandleRegistry(address(handles)), directory, reverseAddr, admin);
    }

    /// @dev Register a handle in the mock C1.
    function _handle(string memory name, address owner) internal returns (uint256 tokenId, bytes32 node) {
        return handles.register(name, owner);
    }

    /// @dev Mint `label.<tld>` in the mock registrar and tag the node the way C5 does at registration.
    function _tldName(string memory label, bytes32 tld, address owner)
        internal
        returns (bytes32 node, uint256 tokenId)
    {
        tokenId = uint256(HandleNormalize.labelhash(label));
        node = HandleNormalize.labelNode(label, tld);
        (MockTldRegistrar reg, address controller) =
            tld == ARC ? (arcRegistrar, arcController) : (circleRegistrar, circleController);
        reg.mint(owner, tokenId);
        vm.prank(controller);
        resolver.tagNode(node, tld, tokenId);
    }

    /// @dev A plain ENS node (no tag, no handle) owned by `owner` in the registry.
    function _ensName(string memory label, bytes32 parent, address owner) internal returns (bytes32 node) {
        if (registry.owner(parent) == address(0)) {
            // create the parent under the root we own (label of the parent is the TLD)
            registry.setSubnodeOwner(bytes32(0), parent == ARC ? keccak256("arc") : keccak256("circle"), address(this));
        }
        registry.setSubnodeOwner(parent, HandleNormalize.labelhash(label), owner);
        node = HandleNormalize.labelNode(label, parent);
    }
}
