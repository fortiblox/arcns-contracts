// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ENSRegistry} from "@ensdomains/ens-contracts/registry/ENSRegistry.sol";
import {ReverseRegistrar} from "@ensdomains/ens-contracts/reverseRegistrar/ReverseRegistrar.sol";
import {Test} from "forge-std/Test.sol";
import {ArcNSResolver} from "../../src/resolver/ArcNSResolver.sol";
import {PrimaryNameLib} from "../../src/resolver/PrimaryNameLib.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {HandleNormalize} from "../../src/lib/HandleNormalize.sol";
import {MockHandleRegistry} from "../resolver/mocks/MockHandleRegistry.sol";
import {MockTldDirectory} from "../resolver/mocks/MockTldDirectory.sol";
import {MockTldRegistrar} from "../resolver/mocks/MockTldRegistrar.sol";

/// @notice WP-108 reverse part: the verbatim ENS ReverseRegistrar (C8) + our NameResolverV is the single primary
///         store across namespaces (onchain-design §3.4); `primaryOf` forward-confirms and never returns a stale
///         string (SR-07, SR-23).
contract PrimaryNameTest is Test {
    ENSRegistry internal registry;
    ReverseRegistrar internal reverse;
    MockHandleRegistry internal handles;
    MockTldDirectory internal directory;
    MockTldRegistrar internal arcRegistrar;
    MockTldRegistrar internal circleRegistrar;
    ArcNSResolver internal resolver;

    address internal admin = makeAddr("admin");
    address internal arcController = makeAddr("arcController");
    address internal circleController = makeAddr("circleController");
    address internal user = makeAddr("user");
    address internal other = makeAddr("other");

    bytes32 internal constant ARC = ArcNSConstants.ARC_NODE;
    bytes32 internal constant CIRCLE = ArcNSConstants.CIRCLE_NODE;
    uint256 internal constant ARC_COIN = 0x804cef52;

    uint256 internal aliceToken;
    bytes32 internal aliceArc;
    bytes32 internal aliceCircle;

    function setUp() public {
        vm.warp(1_757_000_000);
        vm.chainId(5042002);
        registry = new ENSRegistry();
        reverse = new ReverseRegistrar(registry);
        // real ENS deploy order: `addr.reverse` owned by the ReverseRegistrar
        registry.setSubnodeOwner(bytes32(0), keccak256("reverse"), address(this));
        registry.setSubnodeOwner(HandleNormalize.tldNode("reverse"), keccak256("addr"), address(reverse));
        handles = new MockHandleRegistry();
        directory = new MockTldDirectory();
        arcRegistrar = new MockTldRegistrar("arc");
        circleRegistrar = new MockTldRegistrar("circle");
        directory.add(ARC, "arc", address(arcRegistrar), arcController, ARC);
        directory.add(CIRCLE, "circle", address(circleRegistrar), circleController, CIRCLE);
        resolver = new ArcNSResolver(registry, IHandleRegistry(address(handles)), directory, address(reverse), admin);
        reverse.setDefaultResolver(address(resolver));

        // names the user controls: a handle (mock C1), alice.arc and alice.circle (plain ENS-registry nodes)
        (aliceToken,) = handles.register("alice", user);
        registry.setSubnodeOwner(bytes32(0), keccak256("arc"), address(this));
        registry.setSubnodeOwner(bytes32(0), keccak256("circle"), address(this));
        registry.setSubnodeOwner(ARC, keccak256("alice"), user);
        registry.setSubnodeOwner(CIRCLE, keccak256("alice"), user);
        aliceArc = HandleNormalize.labelNode("alice", ARC);
        aliceCircle = HandleNormalize.labelNode("alice", CIRCLE);
    }

    function _primary(address a) internal view returns (string memory n, uint8 ns) {
        (n, ns) = resolver.primaryOf(a);
    }

    function test_reverse_node_derivation_matches_ReverseRegistrar() public view {
        assertEq(PrimaryNameLib.reverseNode(user), reverse.node(user));
        assertEq(PrimaryNameLib.reverseNode(address(0)), reverse.node(address(0)));
    }

    function test_no_primary_when_nothing_set() public view {
        (string memory n, uint8 ns) = _primary(user);
        assertEq(n, "");
        assertEq(ns, 0);
    }

    function test_handle_primary_confirms_via_ownerOf() public {
        vm.prank(user);
        reverse.setName("@alice");
        assertEq(resolver.name(reverse.node(user)), "@alice");
        (string memory n, uint8 ns) = _primary(user);
        assertEq(n, "@alice");
        assertEq(ns, 1);
        // someone else claiming @alice gets nothing
        vm.prank(other);
        reverse.setName("@alice");
        (n, ns) = _primary(other);
        assertEq(n, "");
        assertEq(ns, 0);
    }

    function test_one_primary_per_address_across_namespaces() public {
        vm.startPrank(user);
        resolver.setAddr(aliceArc, ARC_COIN, abi.encodePacked(user));
        resolver.setAddr(aliceCircle, ARC_COIN, abi.encodePacked(user));
        reverse.setName("@alice");
        vm.stopPrank();
        (string memory n, uint8 ns) = _primary(user);
        assertEq(n, "@alice");
        assertEq(ns, 1);

        vm.prank(user);
        reverse.setName("alice.arc");
        (n, ns) = _primary(user);
        assertEq(n, "alice.arc", "exactly one primary: the latest write");
        assertEq(ns, 2);

        // SR-07: set .arc then .circle ⇒ only .circle
        vm.prank(user);
        reverse.setName("alice.circle");
        (n, ns) = _primary(user);
        assertEq(n, "alice.circle");
        assertEq(ns, 2);
        assertEq(resolver.name(reverse.node(user)), "alice.circle");

        // clearing = X1 clear_primary
        vm.prank(user);
        reverse.setName("");
        (n, ns) = _primary(user);
        assertEq(n, "");
        assertEq(ns, 0);
    }

    function test_tld_primary_confirms_via_arc_coin_type_with_eth_fallback() public {
        vm.prank(user);
        reverse.setName("alice.arc");
        (string memory n, uint8 ns) = _primary(user);
        assertEq(n, "", "no forward record yet");
        assertEq(ns, 0);
        // coinType 60 fallback
        vm.prank(user);
        resolver.setAddr(aliceArc, user);
        (n, ns) = _primary(user);
        assertEq(n, "alice.arc");
        assertEq(ns, 2);
        // Arc record pointing elsewhere wins over the 60 fallback? No: either match confirms (§3.4 order is
        // Arc first, then 60), so a mismatching Arc record with a matching 60 record still confirms.
        vm.prank(user);
        resolver.setAddr(aliceArc, ARC_COIN, abi.encodePacked(other));
        (n, ns) = _primary(user);
        assertEq(n, "alice.arc");
        // both mismatch ⇒ nothing
        vm.prank(user);
        resolver.setAddr(aliceArc, other);
        (n, ns) = _primary(user);
        assertEq(n, "");
        assertEq(ns, 0);
        // .circle via the Arc coin type only
        vm.prank(user);
        resolver.setAddr(aliceCircle, ARC_COIN, abi.encodePacked(user));
        vm.prank(user);
        reverse.setName("alice.circle");
        (n, ns) = _primary(user);
        assertEq(n, "alice.circle");
        assertEq(ns, 2);
    }

    function test_stale_handle_primary_after_transfer_returns_nothing_without_a_write() public {
        vm.prank(user);
        reverse.setName("@alice");
        handles.transfer(aliceToken, other);
        vm.record();
        (string memory n, uint8 ns) = _primary(user);
        (, bytes32[] memory writes) = vm.accesses(address(resolver));
        assertEq(writes.length, 0, "view path never writes");
        assertEq(n, "");
        assertEq(ns, 0);
        // the raw reverse string is still there (display hint only), the primary is not
        assertEq(resolver.name(reverse.node(user)), "@alice");
        // and the new owner does not inherit it either
        (n, ns) = _primary(other);
        assertEq(n, "");
    }

    function test_stale_tld_primary_after_forward_record_changes() public {
        vm.startPrank(user);
        resolver.setAddr(aliceArc, ARC_COIN, abi.encodePacked(user));
        reverse.setName("alice.arc");
        vm.stopPrank();
        (string memory n,) = _primary(user);
        assertEq(n, "alice.arc");
        // registry owner changes ⇒ records vanish ⇒ forward-confirm fails
        vm.prank(user);
        registry.setOwner(aliceArc, other);
        (n,) = _primary(user);
        assertEq(n, "");
    }

    function test_retired_tld_primary_returns_nothing() public {
        vm.startPrank(user);
        resolver.setAddr(aliceCircle, ARC_COIN, abi.encodePacked(user));
        reverse.setName("alice.circle");
        vm.stopPrank();
        (string memory n,) = _primary(user);
        assertEq(n, "alice.circle");
        directory.retire(CIRCLE);
        (n,) = _primary(user);
        assertEq(n, "");
        // sunset: fine until sunsetAt, nothing after
        vm.prank(user);
        resolver.setAddr(aliceArc, ARC_COIN, abi.encodePacked(user));
        vm.prank(user);
        reverse.setName("alice.arc");
        directory.sunset(ARC, uint64(block.timestamp + 1 days), address(0), address(0));
        (n,) = _primary(user);
        assertEq(n, "alice.arc");
        vm.warp(block.timestamp + 1 days);
        (n,) = _primary(user);
        assertEq(n, "");
    }

    function test_unknown_tld_primary_returns_nothing() public {
        // a name under a TLD the directory does not know is never a primary, even if forward-confirmable
        registry.setSubnodeOwner(bytes32(0), keccak256("eth"), address(this));
        bytes32 aliceEth = HandleNormalize.labelNode("alice", HandleNormalize.tldNode("eth"));
        registry.setSubnodeOwner(HandleNormalize.tldNode("eth"), keccak256("alice"), user);
        vm.startPrank(user);
        resolver.setAddr(aliceEth, ARC_COIN, abi.encodePacked(user));
        reverse.setName("alice.eth");
        vm.stopPrank();
        (string memory n, uint8 ns) = _primary(user);
        assertEq(n, "");
        assertEq(ns, 0);
    }

    function test_malformed_strings_are_never_primaries() public {
        vm.startPrank(user);
        resolver.setAddr(aliceArc, ARC_COIN, abi.encodePacked(user));
        string[8] memory bad =
            ["@Alice", "alice.arc.arc.arc", "@alice.arc", "alice", "@", ".arc", "alice..arc", "Alice.arc"];
        for (uint256 i = 0; i < bad.length; i++) {
            reverse.setName(bad[i]);
            (string memory n, uint8 ns) = _primary(user);
            assertEq(n, "", bad[i]);
            assertEq(ns, 0, bad[i]);
        }
        // three labels are allowed when every label is canonical and the node confirms
        registry.setSubnodeOwner(aliceArc, keccak256("pay"), user);
        bytes32 payNode = HandleNormalize.labelNode("pay", aliceArc);
        resolver.setAddr(payNode, ARC_COIN, abi.encodePacked(user));
        reverse.setName("pay.alice.arc");
        (string memory n3, uint8 ns3) = _primary(user);
        assertEq(n3, "pay.alice.arc");
        assertEq(ns3, 2);
        vm.stopPrank();
    }

    function test_reverse_registrar_only_lets_the_address_itself_claim() public {
        // `authorised(addr)` ends in `ownsContract(addr)`: `Ownable(user).owner()` on an EOA returns no data,
        // and the decode failure escapes the try/catch as an empty revert — still a revert (SR-23)
        vm.prank(other);
        vm.expectRevert();
        reverse.setNameForAddr(user, other, address(resolver), "@alice");
        assertEq(resolver.name(reverse.node(user)), "");
        // a contract the caller owns may be claimed for (ERC-173 path, verbatim ENS)
        vm.prank(user);
        reverse.setNameForAddr(user, user, address(resolver), "@alice");
        (string memory n,) = resolver.primaryOf(user);
        assertEq(n, "@alice");
    }

    function test_parse_library_edge_cases() public pure {
        PrimaryNameLib.Parsed memory p = PrimaryNameLib.parse("bob.circle");
        assertEq(p.namespace, 2);
        assertEq(p.tldNode, CIRCLE);
        assertEq(p.node, HandleNormalize.labelNode("bob", CIRCLE));
        p = PrimaryNameLib.parse("@bob");
        assertEq(p.namespace, 1);
        assertEq(p.handle, "bob");
        assertEq(PrimaryNameLib.parse("").namespace, 0);
        assertEq(PrimaryNameLib.parse("a.b.c.d").namespace, 0);
        assertEq(PrimaryNameLib.parse("a.").namespace, 0);
        assertEq(PrimaryNameLib.parse(".a").namespace, 0);
        assertEq(PrimaryNameLib.parse("a-.b").namespace, 0);
        assertEq(PrimaryNameLib.parse("123.arc").namespace, 0, "all-digit label is not canonical");
    }
}
