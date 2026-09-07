// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {IVersionableResolver} from "@ensdomains/ens-contracts/resolvers/profiles/IVersionableResolver.sol";
import {IHasAddressResolver} from "@ensdomains/ens-contracts/resolvers/profiles/IHasAddressResolver.sol";
import {IMulticallable} from "@ensdomains/ens-contracts/resolvers/IMulticallable.sol";
import {NameCoder} from "@ensdomains/ens-contracts/utils/NameCoder.sol";
import {ITldDirectory} from "../../src/interfaces/ITldDirectory.sol";
import {IArcNSResolver} from "../../src/interfaces/IArcNSResolver.sol";
import {ArcNSResolver} from "../../src/resolver/ArcNSResolver.sol";
import {ExtendedResolverV} from "../../src/resolver/profiles/ExtendedResolverV.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {HandleNormalize} from "../../src/lib/HandleNormalize.sol";
import {ResolverFixture} from "./mocks/ResolverFixture.sol";

/// @notice C7 behaviour: version-keyed records per namespace (INV-2 acceptance for WP-112), authority, tagging,
///         retirement, ENSIP-10, delegates, multicall and verbatim ENS events.
contract ArcNSResolverTest is ResolverFixture {
    event AddressChanged(bytes32 indexed node, uint256 coinType, bytes newAddress);
    event AddrChanged(bytes32 indexed node, address a);
    event TextChanged(bytes32 indexed node, string indexed indexedKey, string key, string value);
    event ContenthashChanged(bytes32 indexed node, bytes hash);
    event VersionChanged(bytes32 indexed node, uint64 newVersion);
    event Approved(address owner, bytes32 indexed node, address indexed delegate, bool indexed approved);
    event NodeTagged(bytes32 indexed node, bytes32 indexed tldNode, uint256 tokenId);
    event Ed25519Enabled(uint256 indexed coinType, bool enabled);

    // ---------------------------------------------------------------------------------------------
    // interface ids
    // ---------------------------------------------------------------------------------------------

    function test_supportsInterface_reports_every_required_id() public view {
        assertTrue(resolver.supportsInterface(0x3b3b57de), "IAddrResolver addr(bytes32)");
        assertTrue(resolver.supportsInterface(0xf1cb7e06), "IAddressResolver addr(bytes32,uint256)");
        assertTrue(resolver.supportsInterface(0x9061b923), "IExtendedResolver resolve(bytes,bytes)");
        assertTrue(resolver.supportsInterface(0x59d1d43c), "ITextResolver");
        assertTrue(resolver.supportsInterface(0xbc1c58d1), "IContentHashResolver");
        assertTrue(resolver.supportsInterface(0x691f3431), "INameResolver");
        assertTrue(resolver.supportsInterface(type(IVersionableResolver).interfaceId), "IVersionableResolver");
        assertTrue(resolver.supportsInterface(type(IHasAddressResolver).interfaceId), "IHasAddressResolver");
        assertTrue(resolver.supportsInterface(type(IMulticallable).interfaceId), "IMulticallable");
        assertTrue(resolver.supportsInterface(type(IArcNSResolver).interfaceId), "IArcNSResolver");
        assertTrue(resolver.supportsInterface(type(IERC165).interfaceId), "ERC165");
        assertTrue(resolver.supportsInterface(type(IAccessControl).interfaceId), "IAccessControl");
        assertTrue(resolver.supportsInterface(type(IERC5267).interfaceId), "IERC5267 eip712Domain");
        assertFalse(resolver.supportsInterface(0xffffffff));
        assertFalse(resolver.supportsInterface(0x12345678));
    }

    // ---------------------------------------------------------------------------------------------
    // handle namespace
    // ---------------------------------------------------------------------------------------------

    function test_handle_write_read_addr_text_contenthash() public {
        (, bytes32 node) = _handle("alice", alice);
        assertEq(resolver.namespaceOf(node), 1);
        vm.startPrank(alice);
        resolver.setAddr(node, alice);
        resolver.setAddr(node, 0, hex"0014751e76e8199196d454941c45d1b3a323f1433bd6");
        resolver.setText(node, "com.twitter", "alice");
        resolver.setContenthash(node, hex"e30101701220aabbcc");
        vm.stopPrank();
        assertEq(resolver.addr(node), alice);
        assertEq(resolver.addr(node, 60), abi.encodePacked(alice));
        assertEq(resolver.addr(node, 0), hex"0014751e76e8199196d454941c45d1b3a323f1433bd6");
        assertTrue(resolver.hasAddr(node, 0));
        assertEq(resolver.text(node, "com.twitter"), "alice");
        assertEq(resolver.contenthash(node), hex"e30101701220aabbcc");
    }

    function test_handle_transfer_makes_every_old_record_unreachable() public {
        (uint256 tokenId, bytes32 node) = _handle("alice", alice);
        vm.startPrank(alice);
        resolver.setAddr(node, alice);
        resolver.setAddr(node, ArcNSConstants.evmCoinType(), abi.encodePacked(alice));
        resolver.setText(node, "url", "https://alice.example");
        resolver.setContenthash(node, hex"01");
        resolver.verifyAddrSelf(node, ArcNSConstants.evmCoinType());
        vm.stopPrank();
        assertTrue(resolver.verified(node, ArcNSConstants.evmCoinType()));
        bytes32 keyBefore = resolver.versionOf(node);

        handles.transfer(tokenId, bob); // C1 `_update`: epoch + 1

        assertNotEq(resolver.versionOf(node), keyBefore);
        assertEq(resolver.addr(node), address(0));
        assertEq(resolver.addr(node, 60).length, 0);
        assertEq(resolver.addr(node, ArcNSConstants.evmCoinType()).length, 0);
        assertFalse(resolver.hasAddr(node, 60));
        assertFalse(resolver.hasAddr(node, ArcNSConstants.evmCoinType()));
        assertFalse(resolver.verified(node, ArcNSConstants.evmCoinType()));
        assertEq(resolver.verifiedAt(node, ArcNSConstants.evmCoinType()), 0);
        assertEq(resolver.text(node, "url"), "");
        assertEq(resolver.contenthash(node).length, 0);

        // the previous owner cannot write any more; the new owner starts fresh
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotAuthorised.selector, node, alice));
        resolver.setAddr(node, alice);
        vm.prank(bob);
        resolver.setAddr(node, bob);
        assertEq(resolver.addr(node), bob);
        assertFalse(resolver.verified(node, 60));
    }

    function test_locked_handle_refuses_every_write() public {
        (uint256 tokenId, bytes32 node) = _handle("alice", alice);
        vm.prank(alice);
        resolver.setAddr(node, alice);
        handles.setLocked(tokenId, true);
        assertFalse(resolver.isAuthorisedFor(node, alice));
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotAuthorised.selector, node, alice));
        resolver.setAddr(node, bob);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotAuthorised.selector, node, alice));
        resolver.setText(node, "k", "v");
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotAuthorised.selector, node, alice));
        resolver.clearRecords(node);
        vm.stopPrank();
        // reads still work while locked (records frozen, not hidden)
        assertEq(resolver.addr(node), alice);
        handles.setLocked(tokenId, false);
        vm.prank(alice);
        resolver.setAddr(node, bob);
        assertEq(resolver.addr(node), bob);
    }

    function test_handle_operator_and_delegate_can_write_but_stranger_cannot() public {
        (uint256 tokenId, bytes32 node) = _handle("alice", alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotAuthorised.selector, node, bob));
        resolver.setAddr(node, bob);
        handles.setOperator(tokenId, bob, true);
        vm.prank(bob);
        resolver.setAddr(node, bob);
        assertEq(resolver.addr(node), bob);
        handles.setOperator(tokenId, bob, false);
        assertFalse(resolver.isAuthorisedFor(node, bob));
    }

    function test_subhandle_records_follow_parent_epoch() public {
        (uint256 tokenId, bytes32 node) = _handle("alice", alice);
        bytes32 sub = handles.createSubname(tokenId, "pay");
        assertEq(resolver.namespaceOf(sub), 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotAuthorised.selector, sub, bob));
        resolver.setAddr(sub, bob);
        vm.prank(alice);
        resolver.setAddr(sub, carol);
        assertEq(resolver.addr(sub), carol);
        assertEq(resolver.addr(node), address(0), "parent untouched");

        handles.transfer(tokenId, bob); // parent transferred ⇒ sub-handle records invalidated
        assertEq(resolver.addr(sub), address(0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotAuthorised.selector, sub, alice));
        resolver.setAddr(sub, alice);
        vm.prank(bob);
        resolver.setAddr(sub, bob);
        assertEq(resolver.addr(sub), bob);
    }

    function test_burned_handle_has_no_records_and_no_writer() public {
        (uint256 tokenId, bytes32 node) = _handle("alice", alice);
        vm.prank(alice);
        resolver.setAddr(node, alice);
        handles.burn(tokenId);
        assertEq(resolver.addr(node), address(0));
        assertEq(resolver.namespaceOf(node), 0, "no longer a handle node");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotAuthorised.selector, node, alice));
        resolver.setAddr(node, alice);
    }

    // ---------------------------------------------------------------------------------------------
    // tagged TLD namespace (owner-keyed)
    // ---------------------------------------------------------------------------------------------

    /// @dev TLD records are keyed by the registrar's *current owner*, not by a counter. A -> B hides A's
    ///      records; B -> A makes A's original records visible again. That is intended: the key is
    ///      "who owns it now", and A's records were A's. Records B wrote stay B's and are hidden once B
    ///      no longer owns the name. `clearRecords` remains available to anyone wanting a hard reset.
    function test_tld_records_are_keyed_by_current_owner() public {
        (bytes32 node, uint256 tokenId) = _tldName("alice", ARC, alice);
        assertEq(resolver.namespaceOf(node), 2);
        assertEq(resolver.tldOf(node), ARC);
        assertEq(resolver.tokenIdOfNode(node), tokenId);
        vm.prank(alice);
        resolver.setAddr(node, alice);
        vm.prank(alice);
        resolver.setText(node, "k", "alice-v");
        assertEq(resolver.addr(node), alice);

        vm.prank(alice);
        arcRegistrar.transferFrom(alice, bob, tokenId);
        assertEq(resolver.addr(node), address(0));
        assertEq(resolver.text(node, "k"), "");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotAuthorised.selector, node, alice));
        resolver.setAddr(node, alice);
        vm.prank(bob);
        resolver.setAddr(node, bob);
        assertEq(resolver.addr(node), bob);

        vm.prank(bob);
        arcRegistrar.transferFrom(bob, alice, tokenId);
        assertEq(resolver.addr(node), alice, "A's records are visible again once A owns the name again");
        assertEq(resolver.text(node, "k"), "alice-v");
        vm.prank(alice);
        resolver.clearRecords(node);
        assertEq(resolver.addr(node), address(0));
    }

    function test_tld_burn_makes_records_empty_and_refuses_writes() public {
        (bytes32 node, uint256 tokenId) = _tldName("alice", ARC, alice);
        vm.prank(alice);
        resolver.setAddr(node, alice);
        arcRegistrar.burn(tokenId);
        assertEq(resolver.addr(node), address(0));
        assertFalse(resolver.isAuthorisedFor(node, alice));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotAuthorised.selector, node, alice));
        resolver.setAddr(node, alice);
    }

    function test_tld_registrar_operator_can_write() public {
        (bytes32 node,) = _tldName("alice", ARC, alice);
        vm.prank(alice);
        arcRegistrar.setApprovalForAll(bob, true);
        vm.prank(bob);
        resolver.setAddr(node, bob);
        assertEq(resolver.addr(node), bob);
    }

    function test_clearRecords_bumps_version_and_emits_VersionChanged() public {
        (, bytes32 node) = _handle("alice", alice);
        vm.prank(alice);
        resolver.setAddr(node, alice);
        bytes32 before = resolver.versionOf(node);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(resolver));
        emit VersionChanged(node, 1);
        resolver.clearRecords(node);
        assertEq(resolver.recordVersions(node), 1);
        assertNotEq(resolver.versionOf(node), before);
        assertEq(resolver.addr(node), address(0));
    }

    // ---------------------------------------------------------------------------------------------
    // tagging
    // ---------------------------------------------------------------------------------------------

    function test_tagNode_only_by_the_tlds_controller() public {
        bytes32 node = HandleNormalize.labelNode("alice", ARC);
        uint256 tokenId = uint256(HandleNormalize.labelhash("alice"));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotTldController.selector, ARC, alice));
        resolver.tagNode(node, ARC, tokenId);
        vm.prank(circleController);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotTldController.selector, ARC, circleController));
        resolver.tagNode(node, ARC, tokenId);
        vm.prank(arcController);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotTldController.selector, bytes32(0), arcController));
        resolver.tagNode(node, bytes32(0), tokenId);

        vm.prank(arcController);
        vm.expectEmit(true, true, false, true, address(resolver));
        emit NodeTagged(node, ARC, tokenId);
        resolver.tagNode(node, ARC, tokenId);
        // idempotent re-tag with the same values
        vm.prank(arcController);
        resolver.tagNode(node, ARC, tokenId);
        assertEq(resolver.tldOf(node), ARC);
        // a node belongs to one TLD: another TLD's controller cannot re-tag it
        vm.prank(circleController);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotTldController.selector, ARC, circleController));
        resolver.tagNode(node, CIRCLE, tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // TLD lifecycle: Retired / Sunset (SR-09)
    // ---------------------------------------------------------------------------------------------

    function test_retired_tld_goes_dark() public {
        (bytes32 node,) = _tldName("alice", CIRCLE, alice);
        vm.prank(alice);
        resolver.setAddr(node, alice);
        vm.prank(alice);
        resolver.setText(node, "k", "v");
        directory.retire(CIRCLE);

        assertEq(resolver.versionOf(node), bytes32(0), "dead key");
        assertEq(resolver.addr(node), address(0));
        assertEq(resolver.addr(node, 60).length, 0);
        assertEq(resolver.text(node, "k"), "");
        assertFalse(resolver.isAuthorisedFor(node, alice));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.TldNotResolvable.selector, CIRCLE));
        resolver.setAddr(node, alice);
        // even the trusted controller cannot write under a retired TLD
        vm.prank(circleController);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.TldNotResolvable.selector, CIRCLE));
        resolver.setAddr(node, alice);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.TldNotResolvable.selector, CIRCLE));
        resolver.resolve(NameCoder.encode("alice.circle"), abi.encodeWithSelector(0xf1cb7e06, node, uint256(60)));
        // .arc is untouched
        (bytes32 arcNode,) = _tldName("alice", ARC, alice);
        vm.prank(alice);
        resolver.setAddr(arcNode, alice);
        assertEq(resolver.addr(arcNode), alice);
    }

    function test_sunset_tld_resolves_until_sunsetAt_then_goes_dark() public {
        (bytes32 node,) = _tldName("alice", CIRCLE, alice);
        vm.prank(alice);
        resolver.setAddr(node, alice);
        uint64 sunsetAt = uint64(block.timestamp + 30 days);
        directory.sunset(CIRCLE, sunsetAt, address(0), address(0));
        assertEq(resolver.addr(node), alice, "still resolves during the window");
        bytes memory out =
            resolver.resolve(NameCoder.encode("alice.circle"), abi.encodeWithSelector(0xf1cb7e06, node, uint256(60)));
        assertEq(abi.decode(out, (bytes)), abi.encodePacked(alice));
        vm.warp(sunsetAt);
        assertEq(resolver.addr(node), address(0));
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.TldNotResolvable.selector, CIRCLE));
        resolver.resolve(NameCoder.encode("alice.circle"), abi.encodeWithSelector(0xf1cb7e06, node, uint256(60)));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.TldNotResolvable.selector, CIRCLE));
        resolver.setAddr(node, alice);
    }

    function test_resolve_refuses_untagged_subname_under_retired_tld() public {
        // a subname created straight in the registry carries no tag, but ENSIP-10 still sees the TLD label
        bytes32 node = _ensName("alice", CIRCLE, alice);
        vm.prank(alice);
        resolver.setAddr(node, alice);
        directory.retire(CIRCLE);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.TldNotResolvable.selector, CIRCLE));
        resolver.resolve(NameCoder.encode("alice.circle"), abi.encodeWithSelector(0xf1cb7e06, node, uint256(60)));
    }

    // ---------------------------------------------------------------------------------------------
    // ENSIP-10
    // ---------------------------------------------------------------------------------------------

    function test_resolve_round_trips_addr_for_alice_arc() public {
        (bytes32 node,) = _tldName("alice", ARC, alice);
        vm.prank(alice);
        resolver.setAddr(node, 60, abi.encodePacked(bob));
        bytes memory name = NameCoder.encode("alice.arc");
        bytes memory out = resolver.resolve(name, abi.encodeWithSelector(0xf1cb7e06, node, uint256(60)));
        assertEq(abi.decode(out, (bytes)), abi.encodePacked(bob));
        out = resolver.resolve(name, abi.encodeWithSelector(0x3b3b57de, node));
        assertEq(abi.decode(out, (address)), bob);
        out = resolver.resolve(name, abi.encodeWithSelector(0x59d1d43c, node, "missing"));
        assertEq(abi.decode(out, (string)), "");
    }

    function test_resolve_rejects_data_whose_node_differs_from_the_name() public {
        (bytes32 node,) = _tldName("alice", ARC, alice);
        (bytes32 other,) = _tldName("bob", ARC, bob);
        bytes memory name = NameCoder.encode("alice.arc");
        vm.expectRevert(abi.encodeWithSelector(ExtendedResolverV.ResolveNodeMismatch.selector, node, other));
        resolver.resolve(name, abi.encodeWithSelector(0xf1cb7e06, other, uint256(60)));
        vm.expectRevert(abi.encodeWithSelector(ExtendedResolverV.ResolveNodeMismatch.selector, node, bytes32(0)));
        resolver.resolve(name, hex"f1cb7e06");
    }

    function test_resolve_unassigned_subname_has_empty_records_no_wildcard() public {
        _tldName("alice", ARC, alice);
        bytes32 sub = HandleNormalize.labelNode("pay", HandleNormalize.labelNode("alice", ARC));
        bytes memory out =
            resolver.resolve(NameCoder.encode("pay.alice.arc"), abi.encodeWithSelector(0xf1cb7e06, sub, uint256(60)));
        assertEq(abi.decode(out, (bytes)).length, 0);
    }

    function test_resolve_bubbles_reverts_from_the_inner_call() public {
        (bytes32 node,) = _tldName("alice", ARC, alice);
        // setAddr through resolve() is a staticcall into a state-changing function: it reverts, and the
        // revert reason is bubbled verbatim
        vm.expectRevert();
        resolver.resolve(NameCoder.encode("alice.arc"), abi.encodeWithSelector(0xd5fa2b00, node, alice));
    }

    // ---------------------------------------------------------------------------------------------
    // trusted controllers, delegates, operators
    // ---------------------------------------------------------------------------------------------

    function test_directory_controller_is_trusted_on_a_fresh_node() public {
        bytes32 node = HandleNormalize.labelNode("fresh", ARC);
        assertEq(resolver.namespaceOf(node), 0);
        assertTrue(resolver.isAuthorisedFor(node, arcController));
        vm.prank(arcController);
        resolver.setAddr(node, alice);
        // owner-keyed by the ENS registry owner (address(0) until someone owns it)
        assertEq(resolver.addr(node), alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NotAuthorised.selector, node, alice));
        resolver.setAddr(node, alice);
    }

    function test_reverse_registrar_is_trusted() public {
        bytes32 node = keccak256("some.reverse.node");
        vm.prank(reverseAddr);
        resolver.setName(node, "alice.arc");
        assertEq(resolver.name(node), "alice.arc");
    }

    function test_approve_lets_the_delegate_edit_records_but_nothing_else() public {
        (uint256 tokenId, bytes32 node) = _handle("alice", alice);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(resolver));
        emit Approved(alice, node, delegate, true);
        resolver.approve(node, delegate, true);
        assertTrue(resolver.isApprovedFor(alice, node, delegate));
        assertTrue(resolver.isAuthorisedFor(node, delegate));

        vm.startPrank(delegate);
        resolver.setAddr(node, carol);
        resolver.setText(node, "k", "v");
        vm.stopPrank();
        assertEq(resolver.addr(node), carol);
        assertEq(resolver.text(node, "k"), "v");

        // a delegate cannot delegate further on the owner's behalf: its own approvals are keyed by itself
        vm.prank(delegate);
        resolver.approve(node, bob, true);
        assertFalse(resolver.isAuthorisedFor(node, bob));
        // nor touch another name of the same owner
        (, bytes32 other) = _handle("alice2", alice);
        assertFalse(resolver.isAuthorisedFor(other, delegate));

        // approvals are keyed by owner: a transfer leaves the new owner with none
        handles.transfer(tokenId, bob);
        assertFalse(resolver.isAuthorisedFor(node, delegate));
        vm.prank(alice);
        vm.expectRevert("Setting delegate status for self");
        resolver.approve(node, alice, true);
    }

    function test_setApprovalForAll_operator_pattern() public {
        (, bytes32 node) = _handle("alice", alice);
        (bytes32 arcNode,) = _tldName("alice", ARC, alice);
        bytes32 ensNode = _ensName("plain", CIRCLE, alice);
        vm.prank(alice);
        resolver.setApprovalForAll(bob, true);
        assertTrue(resolver.isApprovedForAll(alice, bob));
        // resolver-level operators apply to TLD and plain ENS nodes (PublicResolver pattern); handle
        // authority is C1's `isOwnerOrOperator` plus per-node delegates only
        assertTrue(resolver.isAuthorisedFor(arcNode, bob));
        assertTrue(resolver.isAuthorisedFor(ensNode, bob));
        assertFalse(resolver.isAuthorisedFor(node, bob));
        vm.prank(alice);
        vm.expectRevert("ERC1155: setting approval status for self");
        resolver.setApprovalForAll(alice, true);
    }

    function test_plain_ens_node_is_keyed_by_registry_owner() public {
        bytes32 node = _ensName("plain", ARC, alice);
        assertEq(resolver.namespaceOf(node), 0);
        vm.prank(alice);
        resolver.setAddr(node, alice);
        // registry operator is authorised too
        vm.prank(alice);
        registry.setApprovalForAll(bob, true);
        vm.prank(bob);
        resolver.setText(node, "k", "v");
        vm.prank(alice);
        registry.setOwner(node, carol);
        assertEq(resolver.addr(node), address(0));
        assertEq(resolver.text(node, "k"), "");
        vm.prank(carol);
        resolver.setAddr(node, carol);
        assertEq(resolver.addr(node), carol);
    }

    // ---------------------------------------------------------------------------------------------
    // multicall
    // ---------------------------------------------------------------------------------------------

    function test_multicallWithNodeCheck_writes_and_rejects_foreign_nodes() public {
        (, bytes32 node) = _handle("alice", alice);
        (, bytes32 other) = _handle("bob", alice);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(0xd5fa2b00, node, alice); // setAddr(bytes32,address)
        calls[1] = abi.encodeWithSignature("setText(bytes32,string,string)", node, "k", "v");
        vm.prank(alice);
        resolver.multicallWithNodeCheck(node, calls);
        assertEq(resolver.addr(node), alice);
        assertEq(resolver.text(node, "k"), "v");

        calls[1] = abi.encodeWithSignature("setText(bytes32,string,string)", other, "k", "v");
        vm.prank(alice);
        vm.expectRevert("multicall: All records must have a matching namehash");
        resolver.multicallWithNodeCheck(node, calls);

        // plain multicall keeps msg.sender: an unauthorised caller still fails inside
        vm.prank(bob);
        vm.expectRevert();
        resolver.multicall(calls);
    }

    // ---------------------------------------------------------------------------------------------
    // events (verbatim ENS)
    // ---------------------------------------------------------------------------------------------

    function test_events_are_verbatim_ens() public {
        (, bytes32 node) = _handle("alice", alice);
        vm.startPrank(alice);
        vm.expectEmit(true, false, false, true, address(resolver));
        emit AddressChanged(node, 60, abi.encodePacked(bob));
        vm.expectEmit(true, false, false, true, address(resolver));
        emit AddrChanged(node, bob);
        resolver.setAddr(node, bob);

        vm.expectEmit(true, false, false, true, address(resolver));
        emit AddressChanged(node, 0, hex"0014751e76e8199196d454941c45d1b3a323f1433bd6");
        resolver.setAddr(node, 0, hex"0014751e76e8199196d454941c45d1b3a323f1433bd6");

        vm.expectEmit(true, true, false, true, address(resolver));
        emit TextChanged(node, "k", "k", "v");
        resolver.setText(node, "k", "v");

        vm.expectEmit(true, false, false, true, address(resolver));
        emit ContenthashChanged(node, hex"01");
        resolver.setContenthash(node, hex"01");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // governance
    // ---------------------------------------------------------------------------------------------

    function test_setEd25519Enabled_is_admin_only() public {
        assertFalse(resolver.ed25519Enabled(501));
        vm.prank(alice);
        vm.expectRevert();
        resolver.setEd25519Enabled(501, true);
        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(resolver));
        emit Ed25519Enabled(501, true);
        resolver.setEd25519Enabled(501, true);
        assertTrue(resolver.ed25519Enabled(501));
        assertFalse(resolver.ed25519Enabled(5010000));
    }

    function test_constructor_wiring() public view {
        assertEq(address(resolver.ens()), address(registry));
        assertEq(address(resolver.handles()), address(handles));
        assertEq(address(resolver.directory()), address(directory));
        assertEq(resolver.reverseRegistrar(), reverseAddr);
        assertTrue(resolver.hasRole(resolver.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(resolver.hasRole(resolver.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_gas_setAddr_20_and_32_bytes() public {
        (, bytes32 node) = _handle("alice", alice);
        vm.startPrank(alice);
        uint256 g = gasleft();
        resolver.setAddr(node, alice);
        uint256 used20 = g - gasleft();
        g = gasleft();
        resolver.setAddr(node, 501, abi.encodePacked(bytes32(uint256(1))));
        uint256 used32 = g - gasleft();
        vm.stopPrank();
        emit log_named_uint("gas setAddr(bytes32,address) 20 B fresh slot", used20);
        emit log_named_uint("gas setAddr(bytes32,uint256,bytes) 32 B fresh slot", used32);
        assertLt(used20, 150_000);
        assertLt(used32, 150_000);
    }
}
