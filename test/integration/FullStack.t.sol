// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {ArcNSDeployLib} from "../../script/lib/ArcNSDeployLib.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";
import {ITldRegistrarController} from "../../src/interfaces/ITldRegistrarController.sol";
import {ITldDirectory} from "../../src/interfaces/ITldDirectory.sol";
import {Base64Decoder} from "../handle/mocks/TestHelpers.sol";

interface IAddrView {
    function addr(bytes32 node, uint256 coinType) external view returns (bytes memory);
    function setAddr(bytes32 node, uint256 coinType, bytes memory a) external;
    function resolve(bytes memory name, bytes memory data) external view returns (bytes memory);
}

/// @title FullStack — WP-113 in-process proof of the deploy library: every M1 contract wired exactly as
///        `script/DeployAll.s.sol` wires it (minus the Safe proxy, which needs the canonical factory), then the
///        cross-contract flows the unit suites can only mock: handle + `.arc` + `.circle` registration through
///        the real oracle/resolver/reverse registrar, reserved genesis in all three namespaces, one primary
///        across namespaces, epoch invalidation through a real transfer, on-chain metadata, and INV-8 hand-off.
contract FullStackTest is Test {
    using Base64Decoder for string;

    address internal constant TREASURY = address(0x7EA5);
    address internal constant SAFE = address(0x5AFE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    ArcNSDeployLib.Book internal b;
    ArcNSDeployLib.Params internal p;
    TimelockController internal timelock;
    uint256 internal constant DELAY = 1 hours;

    function setUp() public {
        vm.warp(1_757_000_000);
        vm.chainId(ArcNSConstants.ARC_TESTNET_CHAIN_ID);
        address[] memory proposers = new address[](1);
        proposers[0] = SAFE;
        timelock = new TimelockController(DELAY, proposers, proposers, address(0));

        p.deployer = address(this);
        p.pauser = SAFE;
        p.treasury = TREASURY;
        p.timelock = address(timelock);
        p.launchTs = uint64(block.timestamp);
        p.minCommitmentAge = 60;
        p.maxCommitmentAge = 24 hours;
        p.recoveryTimelock = 7 days;
        uint256[10] memory h = [uint256(100000e18), 10000e18, 1000e18, 200e18, 40e18, 20e18, 20e18, 20e18, 20e18, 10e18];
        uint256[10] memory t = [uint256(80e18), 60e18, 40e18, 12e18, 4e18, 3e18, 3e18, 3e18, 3e18, 2e18];
        uint256[10] memory a = [uint256(50000e18), 5000e18, 500e18, 100e18, 20e18, 10e18, 10e18, 10e18, 10e18, 5e18];
        p.handleTiersWei = h;
        p.tokenizeTiersWei = t;
        p.tldTiersWei = a;

        ArcNSDeployLib.Params memory pm = p;
        ArcNSDeployLib.Book memory bm = ArcNSDeployLib.deployShared(pm);
        bm.tlds = new ArcNSDeployLib.Tld[](2);
        bm.tlds[0] = ArcNSDeployLib.addTld(bm, pm, "arc");
        bm.tlds[1] = ArcNSDeployLib.addTld(bm, pm, "circle");
        ArcNSDeployLib.handoff(bm, pm);
        _store(bm);

        // genesis: the same list in all three namespaces, then seal (revokes GENESIS_ROLE)
        string[] memory names = new string[](3);
        names[0] = "nike";
        names[1] = "usdc";
        names[2] = "circle";
        uint8[] memory types = new uint8[](3);
        b.handleController.registerReservedBatch(names, types);
        b.handleController.sealGenesis(keccak256("handle-root"));
        for (uint256 i = 0; i < 2; i++) {
            b.tlds[i].controller.registerReservedBatch(names);
            b.tlds[i].controller.sealGenesis(keccak256(bytes(b.tlds[i].label)));
        }
        vm.deal(alice, 1_000_000e18);
        vm.deal(bob, 1_000_000e18);
    }

    function _store(ArcNSDeployLib.Book memory bm) internal {
        b.bootstrap = bm.bootstrap;
        b.registry = bm.registry;
        b.root = bm.root;
        b.reverseRegistrar = bm.reverseRegistrar;
        b.gatewayProvider = bm.gatewayProvider;
        b.universalResolver = bm.universalResolver;
        b.oracle = bm.oracle;
        b.directory = bm.directory;
        b.handles = bm.handles;
        b.resolver = bm.resolver;
        b.handleController = bm.handleController;
        b.tldMetadata = bm.tldMetadata;
        for (uint256 i = 0; i < bm.tlds.length; i++) {
            b.tlds.push(bm.tlds[i]);
        }
    }

    // ---- INV-8: deployer holds no admin; timelock is admin everywhere; genesis sealed ⇒ role gone
    function test_INV8_handoff_leaves_deployer_without_roles() public view {
        bytes32 admin = 0x00;
        assertFalse(b.oracle.hasRole(admin, address(this)));
        assertTrue(b.oracle.hasRole(admin, address(timelock)));
        assertFalse(b.handles.hasRole(admin, address(this)));
        assertTrue(b.handles.hasRole(admin, address(timelock)));
        assertFalse(b.resolver.hasRole(admin, address(this)));
        assertFalse(b.directory.hasRole(admin, address(this)));
        assertFalse(b.handleController.hasRole(admin, address(this)));
        assertFalse(b.handleController.hasRole(ArcNSConstants.GENESIS_ROLE, address(this)));
        assertEq(b.root.owner(), address(timelock));
        assertEq(b.reverseRegistrar.owner(), address(timelock));
        assertEq(b.registry.owner(bytes32(0)), address(b.root));
        for (uint256 i = 0; i < 2; i++) {
            assertEq(b.tlds[i].registrar.owner(), address(timelock));
            assertFalse(b.tlds[i].controller.hasRole(admin, address(this)));
            assertFalse(b.tlds[i].controller.hasRole(ArcNSConstants.GENESIS_ROLE, address(this)));
            assertEq(b.registry.owner(b.tlds[i].node), address(b.tlds[i].registrar));
        }
        assertEq(timelock.getMinDelay(), DELAY);
    }

    // ---- genesis in every namespace, never counted as a sale
    function test_genesis_reserved_in_all_three_namespaces_and_totalSold_untouched() public view {
        assertEq(b.handles.ownerOf(ArcNSConstants.handleTokenId("nike")), TREASURY);
        for (uint256 i = 0; i < 2; i++) {
            assertEq(b.tlds[i].registrar.ownerOf(uint256(keccak256("nike"))), TREASURY);
            assertFalse(b.tlds[i].controller.available("nike"));
            assertEq(b.oracle.namespaceInfo(b.tlds[i].node).totalSold, 0);
        }
        assertFalse(b.handleController.available("nike"));
        assertEq(b.oracle.namespaceInfo(ArcNSConstants.HANDLE_ROOT).totalSold, 0);
    }

    function _registerHandle(address who, string memory name) internal returns (uint256 tokenId) {
        bytes32 secret = keccak256(abi.encode(who, name));
        vm.prank(who);
        b.handleController.commit(b.handleController.makeCommitment(name, who, secret, 0));
        vm.warp(block.timestamp + 61);
        uint256 price = b.handleController.quote(name);
        vm.prank(who);
        b.handleController.register{value: price}(name, who, secret, 0, price);
        tokenId = ArcNSConstants.handleTokenId(name);
    }

    function _registerTld(uint256 i, address who, string memory label, bool reverse) internal returns (bytes32 node) {
        ITldRegistrarController.Registration memory r = ITldRegistrarController.Registration({
            label: label,
            owner: who,
            secret: keccak256(abi.encode(who, label, i)),
            resolver: address(b.resolver),
            data: new bytes[](0),
            reverseRecord: reverse
        });
        vm.prank(who);
        b.tlds[i].controller.commit(b.tlds[i].controller.makeCommitment(r));
        vm.warp(block.timestamp + 61);
        uint256 price = b.tlds[i].controller.quote(label);
        vm.prank(who);
        b.tlds[i].controller.register{value: price}(r, price);
        node = keccak256(abi.encodePacked(b.tlds[i].node, keccak256(bytes(label))));
    }

    // ---- paid registrations across the real stack: price, treasury, counters, records, reverse
    function test_register_in_three_namespaces_prices_and_records() public {
        uint256 t0 = TREASURY.balance;
        uint256 id = _registerHandle(alice, "alice");
        assertEq(b.handles.ownerOf(id), alice);
        // 5-char handle at launch: 40 × 25 % = 10 USDC
        assertEq(TREASURY.balance - t0, 10e18);
        assertEq(b.oracle.namespaceInfo(ArcNSConstants.HANDLE_ROOT).totalSold, 1);

        bytes32 arcNode = _registerTld(0, alice, "alice", true);
        // 5-char .arc at launch: 20 × 25 % = 5 USDC; Arc coinType record set by the controller (WP-145)
        assertEq(TREASURY.balance - t0, 15e18);
        assertEq(
            IAddrView(address(b.resolver)).addr(arcNode, ArcNSConstants.ARC_TESTNET_COIN_TYPE), abi.encodePacked(alice)
        );
        assertEq(b.registry.owner(arcNode), alice);
        assertEq(b.registry.resolver(arcNode), address(b.resolver));
        assertEq(b.tlds[0].registrar.ownerOf(uint256(keccak256("alice"))), alice);
        assertEq(b.oracle.namespaceInfo(b.tlds[0].node).totalSold, 1);
        assertEq(b.oracle.namespaceInfo(b.tlds[1].node).totalSold, 0);

        // reverse record set at registration ⇒ primary is alice.arc (forward-confirmed through the Arc record)
        (string memory primary, uint8 ns) = b.resolver.primaryOf(alice);
        assertEq(primary, "alice.arc");
        assertEq(ns, 2);

        // then .circle with reverse ⇒ exactly one primary, the newest (SR-07)
        _registerTld(1, alice, "alice", true);
        (primary, ns) = b.resolver.primaryOf(alice);
        assertEq(primary, "alice.circle");
        assertEq(ns, 2);

        // and the handle namespace replaces it too
        vm.prank(alice);
        b.reverseRegistrar.setName("@alice");
        (primary, ns) = b.resolver.primaryOf(alice);
        assertEq(primary, "@alice");
        assertEq(ns, 1);

        // ENSIP-10 resolve for alice.arc round-trips the Arc record
        bytes memory dns = abi.encodePacked(bytes1(0x05), "alice", bytes1(0x03), "arc", bytes1(0x00));
        bytes memory data =
            abi.encodeWithSelector(IAddrView.addr.selector, arcNode, ArcNSConstants.ARC_TESTNET_COIN_TYPE);
        bytes memory out = IAddrView(address(b.resolver)).resolve(dns, data);
        assertEq(abi.decode(out, (bytes)), abi.encodePacked(alice));
    }

    // ---- SR-12 through the real registry: a transfer makes the old records unreadable
    function test_handle_transfer_invalidates_records_and_stale_primary() public {
        uint256 id = _registerHandle(alice, "alice");
        bytes32 node = ArcNSConstants.handleNode("alice");
        vm.prank(alice);
        IAddrView(address(b.resolver)).setAddr(node, 60, abi.encodePacked(alice));
        assertEq(IAddrView(address(b.resolver)).addr(node, 60), abi.encodePacked(alice));
        vm.prank(alice);
        b.reverseRegistrar.setName("@alice");
        (string memory primary,) = b.resolver.primaryOf(alice);
        assertEq(primary, "@alice");

        uint64 e0 = b.handles.epochOf(id);
        vm.prank(alice);
        b.handles.transfer(id, bob);
        assertEq(b.handles.epochOf(id), e0 + 1);
        assertEq(IAddrView(address(b.resolver)).addr(node, 60).length, 0);
        (primary,) = b.resolver.primaryOf(alice);
        assertEq(primary, "");
        // bob (new owner) writes fresh; alice can no longer write
        vm.prank(bob);
        IAddrView(address(b.resolver)).setAddr(node, 60, abi.encodePacked(bob));
        assertEq(IAddrView(address(b.resolver)).addr(node, 60), abi.encodePacked(bob));
        vm.prank(alice);
        vm.expectRevert();
        IAddrView(address(b.resolver)).setAddr(node, 60, abi.encodePacked(alice));
    }

    // ---- tokenize through the real oracle: 5-char tokenize ceiling 4 USDC × 25 % = 1 USDC
    function test_tokenize_pays_oracle_price_and_enables_erc721_transfer() public {
        uint256 id = _registerHandle(alice, "alice");
        vm.prank(alice);
        vm.expectRevert();
        IERC721(address(b.handles)).transferFrom(alice, bob, id);
        uint256 fee = b.oracle.quoteTokenize(ArcNSConstants.HANDLE_ROOT, "alice");
        assertEq(fee, 1e18);
        uint256 t0 = TREASURY.balance;
        vm.prank(alice);
        b.handles.tokenize{value: fee}(id, fee);
        assertEq(TREASURY.balance - t0, fee);
        assertEq(b.oracle.namespaceInfo(ArcNSConstants.HANDLE_ROOT).tokenized, 1);
        vm.prank(alice);
        IERC721(address(b.handles)).transferFrom(alice, bob, id);
        assertEq(b.handles.ownerOf(id), bob);
    }

    // ---- WP-143 / WP-109: metadata names are the real names, never hashes
    function test_metadata_renders_names() public {
        _registerHandle(alice, "alice");
        _registerTld(0, alice, "alice", false);
        _registerTld(1, bob, "alice", false);
        string memory h = string(b.handles.tokenURI(ArcNSConstants.handleTokenId("alice")).decodeDataUri());
        assertTrue(_contains(h, '"name":"@alice"'));
        string memory a = string(b.tlds[0].registrar.tokenURI(uint256(keccak256("alice"))).decodeDataUri());
        assertTrue(_contains(a, '"name":"alice.arc"'));
        string memory c = string(b.tlds[1].registrar.tokenURI(uint256(keccak256("alice"))).decodeDataUri());
        assertTrue(_contains(c, '"name":"alice.circle"'));
        assertEq(b.tlds[0].registrar.symbol(), "ARC");
        assertEq(b.tlds[1].registrar.symbol(), "CIRCLE");
    }

    // ---- SR-09: sunsetting .circle through the timelock leaves .arc and handles untouched
    function test_circle_sunset_via_timelock_isolated() public {
        _registerHandle(alice, "alice");
        bytes32 arcNode = _registerTld(0, alice, "alice", true);
        bytes32 circleNode = _registerTld(1, bob, "alice", true);
        bytes32 arcRowBefore = keccak256(abi.encode(b.directory.get(b.tlds[0].node)));

        uint64 sunsetAt = uint64(block.timestamp + 200 days);
        bytes memory call = abi.encodeCall(ITldDirectory.sunset, (b.tlds[1].node, sunsetAt, address(0), address(0)));
        vm.prank(SAFE);
        timelock.schedule(address(b.directory), 0, call, bytes32(0), keccak256("circle-sunset"), DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(SAFE);
        timelock.execute(address(b.directory), 0, call, bytes32(0), keccak256("circle-sunset"));

        assertEq(uint8(b.directory.statusOf(b.tlds[1].node)), uint8(ITldDirectory.TldStatus.Sunset));
        assertEq(keccak256(abi.encode(b.directory.get(b.tlds[0].node))), arcRowBefore);
        // still resolves until sunsetAt, then dark; .arc unaffected throughout
        assertEq(
            IAddrView(address(b.resolver)).addr(circleNode, ArcNSConstants.ARC_TESTNET_COIN_TYPE), abi.encodePacked(bob)
        );
        vm.warp(sunsetAt);
        assertEq(IAddrView(address(b.resolver)).addr(circleNode, ArcNSConstants.ARC_TESTNET_COIN_TYPE).length, 0);
        assertEq(
            IAddrView(address(b.resolver)).addr(arcNode, ArcNSConstants.ARC_TESTNET_COIN_TYPE), abi.encodePacked(alice)
        );
        (string memory primary,) = b.resolver.primaryOf(bob);
        assertEq(primary, "");
        assertTrue(b.tlds[0].controller.available("zed"));
        assertFalse(b.directory.registrationsOpen(b.tlds[1].node));
        // handle registration keeps working
        _registerHandle(bob, "bobby");
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
