// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {TldStackFixture} from "./mocks/TldStackFixture.sol";
import {MockResolver} from "./mocks/MockResolver.sol";
import {TldRegistrar} from "../../src/tld/TldRegistrar.sol";
import {TldRegistrarController} from "../../src/tld/TldRegistrarController.sol";
import {TldMetadata} from "../../src/tld/TldMetadata.sol";
import {ITldDirectory} from "../../src/interfaces/ITldDirectory.sol";
import {ITldRegistrarController} from "../../src/interfaces/ITldRegistrarController.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";

/// @dev A payer contract whose `receive` can be switched off (pull-ledger failure path).
contract Payer {
    bool public accept = true;

    function setAccept(bool v) external {
        accept = v;
    }

    function commit(TldRegistrarController c, bytes32 commitment) external {
        c.commit(commitment);
    }

    function register(TldRegistrarController c, ITldRegistrarController.Registration calldata r, uint256 maxPrice)
        external
        payable
    {
        c.register{value: msg.value}(r, maxPrice);
    }

    function withdraw(TldRegistrarController c) external {
        c.withdraw();
    }

    receive() external payable {
        require(accept, "Payer: refusing value");
    }
}

/// @dev Treasury stand-in that refuses value (our Safe reverting must surface, never be swallowed).
contract RevertingTreasury {
    receive() external payable {
        revert("treasury down");
    }
}

/// @notice C5 against the real ENSRegistry / Root / ReverseRegistrar / TldRegistrar ×2 / TldDirectory /
///         ArcNSPriceOracle and the MockResolver (WP-111, WP-139, WP-143, WP-145).
contract TldRegistrarControllerTest is TldStackFixture {
    bytes32 internal constant NAME_REGISTERED_TOPIC =
        keccak256("NameRegistered(string,bytes32,address,uint256,uint256,uint256,bytes32)");
    bytes32 internal constant GENESIS_ROOT = keccak256("genesis-root");
    uint256 internal constant ARC_COIN = ArcNSConstants.ARC_TESTNET_COIN_TYPE;

    string[] internal reserved;

    function setUp() public {
        vm.chainId(ArcNSConstants.ARC_TESTNET_CHAIN_ID);
        _deployShared();
        arc = _addTld("arc");
        circle = _addTld("circle");
        reserved.push("nike");
        reserved.push("a");
        reserved.push("ab");
        reserved.push("circle");
    }

    function _sealBoth() internal {
        _genesis(arc, reserved, GENESIS_ROOT);
        _genesis(circle, reserved, GENESIS_ROOT);
    }

    function _unauthorised(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
    }

    function _setText(bytes32 node, string memory key, string memory value) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(MockResolver.setText.selector, node, key, value);
    }

    function _decodeDataUri(string memory uri) internal pure returns (string memory) {
        bytes memory b = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        require(b.length > prefix.length, "no prefix");
        for (uint256 i = 0; i < prefix.length; i++) {
            require(b[i] == prefix[i], "bad prefix");
        }
        bytes memory payload = new bytes(b.length - prefix.length);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = b[prefix.length + i];
        }
        return string(Base64.decode(string(payload)));
    }

    function _decodeSvg(string memory json) internal pure returns (string memory) {
        bytes memory b = bytes(json);
        bytes memory marker = bytes('"image":"data:image/svg+xml;base64,');
        uint256 start = _indexOf(b, marker) + marker.length;
        uint256 end = start;
        while (b[end] != '"') {
            end++;
        }
        bytes memory payload = new bytes(end - start);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = b[start + i];
        }
        return string(Base64.decode(string(payload)));
    }

    function _indexOf(bytes memory hay, bytes memory needle) internal pure returns (uint256) {
        for (uint256 i = 0; i + needle.length <= hay.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return i;
        }
        revert("needle not found");
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
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

    /// @dev Hash of everything `.arc` owns: directory row, registrar totals, ENS node owners, resolver reads.
    function _arcStateHash(string memory label) internal view returns (bytes32) {
        bytes32 node = _node(arc, label);
        uint256 id = uint256(_labelhash(label));
        bytes32 h1 = keccak256(
            abi.encode(
                directory.get(arc.node),
                registry.owner(arc.node),
                registry.owner(node),
                registry.resolver(node),
                arc.registrar.ownerOf(id),
                arc.registrar.nameExpires(id),
                arc.registrar.balanceOf(alice)
            )
        );
        bytes32 h2 = keccak256(
            abi.encode(
                resolver.addr(node, ARC_COIN),
                resolver.tldOf(node),
                oracle.namespaceInfo(arc.node).totalSold,
                arc.controller.paidWei(_labelhash(label)),
                arc.controller.reservedCount(),
                directory.registrationsOpen(arc.node),
                directory.resolvable(arc.node)
            )
        );
        return keccak256(abi.encode(h1, h2));
    }

    // =============================================================================================
    // Happy path
    // =============================================================================================

    function test_happy_path_register_with_resolver_data_and_reverse() public {
        _sealBoth();
        bytes32 node = _node(arc, "alice");
        uint256 id = uint256(_labelhash("alice"));
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), true);
        r.data = new bytes[](1);
        r.data[0] = _setText(node, "url", "https://alice.example");

        bytes32 commitment = _commitAndWait(arc, r, alice);
        assertGt(arc.controller.commitments(commitment), 0);
        uint256 price = arc.controller.quote("alice");
        assertEq(price, 5 * USDC, "5-char .arc launch price");
        vm.deal(alice, price);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit ITldRegistrarController.NameRegistered(
            "alice", _labelhash("alice"), alice, price, 0, type(uint64).max, bytes32(0)
        );
        arc.controller.register{value: price}(r, price);

        // ENS registry semantics of namehash("alice.arc")
        assertEq(registry.owner(node), alice);
        assertEq(registry.resolver(node), address(resolver));
        assertEq(registry.ttl(node), 0);
        // ERC-721 + permanence
        assertEq(arc.registrar.ownerOf(id), alice);
        assertEq(arc.registrar.nameExpires(id), type(uint64).max);
        assertFalse(arc.controller.available("alice"));
        assertFalse(arc.registrar.available(id));
        // records: Arc coin-type first, then the user's data
        assertEq(resolver.addr(node, ARC_COIN), abi.encodePacked(alice));
        assertEq(resolver.text(node, "url"), "https://alice.example");
        assertEq(resolver.tldOf(node), arc.node);
        assertEq(resolver.tokenIdOfNode(node), id);
        // reverse record
        bytes32 rnode = reverse.node(alice);
        assertEq(resolver.name(rnode), "alice.arc");
        assertEq(registry.owner(rnode), alice);
        assertEq(registry.resolver(rnode), address(resolver));
        // ledgers
        assertEq(arc.controller.paidWei(_labelhash("alice")), price);
        assertEq(arc.controller.labelOf(_labelhash("alice")), "alice");
        assertEq(arc.controller.commitments(commitment), 0, "commitment consumed");
        assertEq(arc.controller.withdrawable(alice), 0);
        assertEq(treasury.balance, price);
        assertEq(address(arc.controller).balance, 0);
        assertEq(oracle.namespaceInfo(arc.node).totalSold, 1);
        assertEq(oracle.namespaceInfo(circle.node).totalSold, 0);
    }

    function test_register_without_resolver_hands_node_to_owner_directly() public {
        _sealBoth();
        bytes32 node = _node(arc, "bob");
        uint256 id = uint256(_labelhash("bob"));
        ITldRegistrarController.Registration memory r = _registration("bob", bob, keccak256("s"), address(0), false);
        uint256 price = _register(arc, r, bob);
        assertEq(price, 125 * USDC);
        assertEq(registry.owner(node), bob);
        assertEq(registry.resolver(node), address(0));
        assertEq(arc.registrar.ownerOf(id), bob);
        assertEq(arc.registrar.nameExpires(id), type(uint64).max);
        assertEq(resolver.tldOf(node), bytes32(0), "no tag without our resolver");
        assertEq(resolver.addr(node, ARC_COIN), "");
        assertEq(arc.controller.paidWei(_labelhash("bob")), price);
        assertEq(treasury.balance, price);
    }

    function test_register_with_foreign_resolver_sets_addr_but_does_not_tag() public {
        _sealBoth();
        MockResolver foreign = new MockResolver(registry, directory, address(reverse));
        bytes32 node = _node(arc, "alice");
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(foreign), false);
        _register(arc, r, alice);
        assertEq(registry.resolver(node), address(foreign));
        assertEq(foreign.addr(node, ARC_COIN), abi.encodePacked(alice));
        assertEq(foreign.tldOf(node), bytes32(0));
        assertEq(resolver.tldOf(node), bytes32(0));
    }

    function test_topic0_of_NameRegistered_is_the_v170_signature() public {
        _sealBoth();
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        vm.recordLogs();
        vm.prank(alice);
        arc.controller.register{value: price}(r, price);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(arc.controller) || logs[i].topics[0] != NAME_REGISTERED_TOPIC) continue;
            found = true;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[1], _labelhash("alice"));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(alice))));
            (string memory label, uint256 baseCost, uint256 premium, uint256 expires, bytes32 referrer) =
                abi.decode(logs[i].data, (string, uint256, uint256, uint256, bytes32));
            assertEq(label, "alice");
            assertEq(baseCost, price);
            assertEq(premium, 0);
            assertEq(expires, type(uint64).max);
            assertEq(referrer, bytes32(0));
        }
        assertTrue(found, "NameRegistered(7-arg) not emitted");
    }

    function test_AddressChanged_emitted_with_arc_coin_type_0x804cef52() public {
        _sealBoth();
        assertEq(block.chainid, 5042002);
        assertEq(ArcNSConstants.evmCoinType(), 0x804cef52);
        bytes32 node = _node(arc, "alice");
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(resolver));
        emit MockResolver.AddressChanged(node, 0x804cef52, abi.encodePacked(alice));
        arc.controller.register{value: price}(r, price);
    }

    function test_MetadataUpdate_emitted_by_registrar_on_register() public {
        _sealBoth();
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        vm.prank(alice);
        vm.expectEmit(false, false, false, true, address(arc.registrar));
        emit TldRegistrar.MetadataUpdate(uint256(_labelhash("alice")));
        arc.controller.register{value: price}(r, price);
        // only controllers may emit it
        vm.prank(stranger);
        vm.expectRevert();
        arc.registrar.emitMetadataUpdate(1);
    }

    function test_user_data_can_override_the_arc_coin_type_record() public {
        _sealBoth();
        bytes32 node = _node(arc, "alice");
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        r.data = new bytes[](1);
        r.data[0] = abi.encodeWithSelector(MockResolver.setAddr.selector, node, ARC_COIN, abi.encodePacked(bob));
        _register(arc, r, alice);
        assertEq(resolver.addr(node, ARC_COIN), abi.encodePacked(bob));
    }

    function test_multicall_data_for_a_different_node_reverts() public {
        _sealBoth();
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        r.data = new bytes[](1);
        r.data[0] = _setText(_node(arc, "other"), "url", "x");
        _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        vm.prank(alice);
        vm.expectRevert(bytes("multicall: All records must have a matching namehash"));
        arc.controller.register{value: price}(r, price);
    }

    // =============================================================================================
    // Commit / reveal (T-REG-1, SR-10, INV-9)
    // =============================================================================================

    function test_makeCommitment_requires_resolver_for_data_and_reverse() public {
        ITldRegistrarController.Registration memory r = _registration("alice", alice, keccak256("s"), address(0), true);
        vm.expectRevert(ITldRegistrarController.ResolverRequiredForReverseRecord.selector);
        arc.controller.makeCommitment(r);
        r.reverseRecord = false;
        r.data = new bytes[](1);
        r.data[0] = hex"00";
        vm.expectRevert(ITldRegistrarController.ResolverRequiredWhenDataSupplied.selector);
        arc.controller.makeCommitment(r);
    }

    function test_commitment_binds_tld_chain_and_controller() public {
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        bytes32 c1 = arc.controller.makeCommitment(r);
        assertTrue(c1 != circle.controller.makeCommitment(r), "tld / controller bound");
        vm.chainId(1);
        assertTrue(c1 != arc.controller.makeCommitment(r), "chainid bound");
        vm.chainId(5042002);
        assertEq(c1, _expectedCommitment(r, address(arc.controller)));
    }

    /// @dev SR-10 shape + payload, computed independently of the contract.
    function _expectedCommitment(ITldRegistrarController.Registration memory r, address ctl)
        internal
        view
        returns (bytes32)
    {
        string memory tag = "arc";
        return
            keccak256(
                abi.encode(tag, r.label, r.owner, r.secret, block.chainid, ctl, r.resolver, r.data, r.reverseRecord)
            );
    }

    function test_commit_emits_and_rejects_unexpired_duplicate() public {
        bytes32 c = keccak256("c");
        vm.expectEmit(true, false, false, true);
        emit ITldRegistrarController.CommitmentMade(c, block.timestamp);
        arc.controller.commit(c);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.UnexpiredCommitmentExists.selector, c));
        arc.controller.commit(c);
        vm.warp(block.timestamp + MAX_AGE);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.UnexpiredCommitmentExists.selector, c));
        arc.controller.commit(c);
        vm.warp(block.timestamp + 1);
        arc.controller.commit(c);
        assertEq(arc.controller.commitments(c), block.timestamp);
    }

    function test_reveal_too_new() public {
        _sealBoth();
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        bytes32 c = arc.controller.makeCommitment(r);
        vm.prank(alice);
        arc.controller.commit(c);
        uint256 committed = block.timestamp;
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        vm.warp(committed + MIN_AGE - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITldRegistrarController.CommitmentTooNew.selector, c, committed + MIN_AGE, block.timestamp
            )
        );
        arc.controller.register{value: price}(r, price);
        // exactly minCommitmentAge is allowed (`>` comparison)
        vm.warp(committed + MIN_AGE);
        vm.prank(alice);
        arc.controller.register{value: price}(r, price);
        assertEq(arc.registrar.ownerOf(uint256(_labelhash("alice"))), alice);
    }

    function test_reveal_too_old() public {
        _sealBoth();
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        bytes32 c = arc.controller.makeCommitment(r);
        vm.prank(alice);
        arc.controller.commit(c);
        uint256 committed = block.timestamp;
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        // exactly maxCommitmentAge is too old (`<=` comparison)
        vm.warp(committed + MAX_AGE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITldRegistrarController.CommitmentTooOld.selector, c, committed + MAX_AGE, block.timestamp
            )
        );
        arc.controller.register{value: price}(r, price);
    }

    function test_reveal_not_found_and_wrong_owner() public {
        _sealBoth();
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        bytes32 c = arc.controller.makeCommitment(r);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.CommitmentNotFound.selector, c));
        arc.controller.register{value: price}(r, price);

        // commit for alice, reveal with bob as owner: a different commitment, hence not found
        _commitAndWait(arc, r, alice);
        ITldRegistrarController.Registration memory wrong = r;
        wrong.owner = bob;
        bytes32 cw = arc.controller.makeCommitment(wrong);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.CommitmentNotFound.selector, cw));
        arc.controller.register{value: price}(wrong, price);
    }

    function test_replayed_reveal_mints_to_the_committed_owner() public {
        _sealBoth();
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), true);
        _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("alice");
        // A front-runner copies alice's reveal calldata and lands first: alice gets the name,
        // the attacker pays. The reverse record (msg.sender-based) points at the attacker's address.
        vm.deal(bob, price);
        vm.prank(bob);
        arc.controller.register{value: price}(r, price);
        assertEq(arc.registrar.ownerOf(uint256(_labelhash("alice"))), alice);
        assertEq(registry.owner(_node(arc, "alice")), alice);
        assertEq(resolver.name(reverse.node(bob)), "alice.arc");
        assertEq(resolver.name(reverse.node(alice)), "");
        // alice's own reveal now finds nothing (consumed) and the name is taken
        vm.deal(alice, price);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.NameNotAvailable.selector, "alice"));
        arc.controller.register{value: price}(r, price);
    }

    function test_second_reveal_of_same_commitment_is_consumed() public {
        _sealBoth();
        ITldRegistrarController.Registration memory r = _registration("zed", alice, keccak256("s"), address(0), false);
        bytes32 c = _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("zed");
        vm.deal(alice, 2 * price);
        vm.prank(alice);
        arc.controller.register{value: price}(r, price);
        assertEq(arc.controller.commitments(c), 0);
        // re-commit and try to register the taken name: NameNotAvailable precedes commitment checks
        vm.prank(alice);
        arc.controller.commit(c);
        vm.warp(block.timestamp + MIN_AGE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.NameNotAvailable.selector, "zed"));
        arc.controller.register{value: price}(r, price);
    }

    function test_PriceChanged_when_quote_exceeds_maxPrice() public {
        _sealBoth();
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.PriceChanged.selector, price, price - 1));
        arc.controller.register{value: price}(r, price - 1);
        // a step boundary between quote and reveal: the buyer's cap protects them
        vm.warp(block.timestamp + 91 days);
        _commitAndWait(arc, r, alice);
        uint256 stepped = arc.controller.quote("alice");
        assertEq(stepped, 6.25e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.PriceChanged.selector, stepped, price));
        arc.controller.register{value: price}(r, price);
        vm.deal(alice, stepped);
        vm.prank(alice);
        arc.controller.register{value: stepped}(r, stepped);
        assertEq(arc.controller.paidWei(_labelhash("alice")), stepped);
    }

    function test_InsufficientValue() public {
        _sealBoth();
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.InsufficientValue.selector, price, price - 1));
        arc.controller.register{value: price - 1}(r, price);
    }

    function test_overpayment_is_credited_then_withdrawn() public {
        _sealBoth();
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price + 1 ether);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit ITldRegistrarController.TreasuryFee(_labelhash("alice"), price);
        vm.expectEmit(true, false, false, true);
        emit ITldRegistrarController.Credited(alice, 1 ether);
        arc.controller.register{value: price + 1 ether}(r, type(uint256).max);
        assertEq(arc.controller.withdrawable(alice), 1 ether);
        assertEq(address(arc.controller).balance, 1 ether);
        assertEq(treasury.balance, price);
        assertEq(alice.balance, 0);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit ITldRegistrarController.Withdrawn(alice, 1 ether);
        arc.controller.withdraw();
        assertEq(alice.balance, 1 ether);
        assertEq(arc.controller.withdrawable(alice), 0);
        assertEq(address(arc.controller).balance, 0);

        vm.prank(alice);
        vm.expectRevert(ITldRegistrarController.NothingToWithdraw.selector);
        arc.controller.withdraw();
    }

    function test_withdraw_failure_keeps_the_credit() public {
        _sealBoth();
        Payer payer = new Payer();
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        bytes32 c = arc.controller.makeCommitment(r);
        payer.commit(arc.controller, c);
        vm.warp(block.timestamp + MIN_AGE);
        uint256 price = arc.controller.quote("alice");
        vm.deal(address(this), price + 1 ether);
        payer.register{value: price + 1 ether}(arc.controller, r, price);
        assertEq(arc.controller.withdrawable(address(payer)), 1 ether);
        payer.setAccept(false);
        vm.expectRevert(
            abi.encodeWithSelector(ITldRegistrarController.WithdrawFailed.selector, address(payer), 1 ether)
        );
        payer.withdraw(arc.controller);
        assertEq(arc.controller.withdrawable(address(payer)), 1 ether, "credit intact");
        payer.setAccept(true);
        payer.withdraw(arc.controller);
        assertEq(address(payer).balance, 1 ether);
    }

    function test_treasury_revert_surfaces() public {
        _sealBoth();
        RevertingTreasury rt = new RevertingTreasury();
        vm.etch(treasury, address(rt).code);
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.TreasuryPaymentFailed.selector, treasury, price));
        arc.controller.register{value: price}(r, price);
    }

    function test_receive_and_fallback_reject_value() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(arc.controller).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(ret), ITldRegistrarController.ValueNotAccepted.selector);
        vm.prank(alice);
        (ok, ret) = address(arc.controller).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok);
        assertEq(bytes4(ret), ITldRegistrarController.ValueNotAccepted.selector);
        vm.prank(alice);
        (ok, ret) = address(arc.controller).call(hex"deadbeef");
        assertFalse(ok);
    }

    // =============================================================================================
    // Registration gates (SR-16, SR-09, SR-62)
    // =============================================================================================

    function test_register_refused_before_seal() public {
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        vm.prank(alice);
        vm.expectRevert(ITldRegistrarController.RegistrationsClosed.selector);
        arc.controller.register{value: price}(r, price);
        // `.circle` sealed, `.arc` not: independent
        _genesis(circle, reserved, GENESIS_ROOT);
        vm.prank(alice);
        vm.expectRevert(ITldRegistrarController.RegistrationsClosed.selector);
        arc.controller.register{value: price}(r, price);
        _genesis(arc, reserved, GENESIS_ROOT);
        vm.prank(alice);
        arc.controller.register{value: price}(r, price);
    }

    function test_register_refused_while_directory_paused_then_allowed_after_unpause() public {
        _sealBoth();
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        vm.prank(pauser);
        directory.pause(arc.node);
        vm.prank(alice);
        vm.expectRevert(ITldRegistrarController.RegistrationsClosed.selector);
        arc.controller.register{value: price}(r, price);
        vm.prank(admin);
        directory.unpause(arc.node);
        vm.prank(alice);
        arc.controller.register{value: price}(r, price);
    }

    function test_register_refused_while_sunset_and_retired() public {
        _sealBoth();
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        uint64 at = uint64(block.timestamp + 30 days);
        vm.prank(admin);
        directory.sunset(arc.node, at, address(0), address(0));
        vm.prank(alice);
        vm.expectRevert(ITldRegistrarController.RegistrationsClosed.selector);
        arc.controller.register{value: price}(r, price);
        vm.warp(at);
        vm.prank(admin);
        directory.retire(arc.node);
        assertFalse(directory.resolvable(arc.node));
        // re-commit inside the window and try again: still closed
        vm.prank(alice);
        arc.controller.commit(arc.controller.makeCommitment(r));
        vm.warp(block.timestamp + MIN_AGE);
        vm.prank(alice);
        vm.expectRevert(ITldRegistrarController.RegistrationsClosed.selector);
        arc.controller.register{value: price}(r, price);
    }

    function test_register_refused_while_controller_paused_only_register() public {
        _sealBoth();
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), false);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);

        vm.prank(stranger);
        vm.expectRevert(_unauthorised(stranger, ArcNSConstants.PAUSER_ROLE));
        arc.controller.pause();
        vm.prank(pauser);
        arc.controller.pause();
        assertTrue(arc.controller.paused());
        assertFalse(circle.controller.paused(), "per-TLD pause");

        // commit still works while paused (SR-62: only register is pausable)
        _commitAndWait(arc, r, alice);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        arc.controller.register{value: price}(r, price);

        vm.prank(pauser);
        vm.expectRevert(_unauthorised(pauser, bytes32(0)));
        arc.controller.unpause();
        vm.prank(admin);
        arc.controller.unpause();
        vm.prank(alice);
        arc.controller.register{value: price}(r, price);
        // admin may also pause
        vm.prank(admin);
        arc.controller.pause();
        assertTrue(arc.controller.paused());
    }

    // =============================================================================================
    // Genesis (WP-139, SR-16, T-REG-6, T-GEN-2)
    // =============================================================================================

    function test_reservedBatch_registers_to_treasury_in_both_tlds() public {
        vm.prank(genesis);
        vm.expectEmit(true, false, false, true);
        emit ITldRegistrarController.ReservedRegistered(_labelhash("nike"), "nike");
        vm.expectEmit(true, true, false, true);
        emit ITldRegistrarController.NameRegistered(
            "nike", _labelhash("nike"), treasury, 0, 0, type(uint64).max, bytes32(0)
        );
        arc.controller.registerReservedBatch(reserved);
        vm.prank(genesis);
        circle.controller.registerReservedBatch(reserved);

        Pair[2] memory pairs = [arc, circle];
        for (uint256 p = 0; p < 2; p++) {
            assertEq(pairs[p].controller.reservedCount(), reserved.length);
            for (uint256 i = 0; i < reserved.length; i++) {
                uint256 id = uint256(_labelhash(reserved[i]));
                bytes32 node = _node(pairs[p], reserved[i]);
                assertFalse(pairs[p].controller.available(reserved[i]));
                assertEq(pairs[p].registrar.ownerOf(id), treasury);
                assertEq(pairs[p].registrar.nameExpires(id), type(uint64).max);
                assertEq(registry.owner(node), treasury);
                assertEq(registry.resolver(node), address(0));
                assertEq(pairs[p].controller.labelOf(_labelhash(reserved[i])), reserved[i]);
                assertEq(pairs[p].controller.paidWei(_labelhash(reserved[i])), 0);
                assertEq(resolver.tldOf(node), pairs[p].node);
                assertEq(resolver.tokenIdOfNode(node), id);
            }
        }
        assertEq(arc.registrar.balanceOf(treasury), reserved.length);
        assertEq(circle.registrar.balanceOf(treasury), reserved.length);
    }

    function test_reservedBatch_is_idempotent() public {
        vm.startPrank(genesis);
        arc.controller.registerReservedBatch(reserved);
        uint256 before = arc.controller.reservedCount();
        arc.controller.registerReservedBatch(reserved);
        assertEq(arc.controller.reservedCount(), before);
        // a partial re-run with one new label counts exactly one
        string[] memory more = new string[](2);
        more[0] = "nike";
        more[1] = "adidas";
        arc.controller.registerReservedBatch(more);
        assertEq(arc.controller.reservedCount(), before + 1);
        vm.stopPrank();
        assertEq(arc.registrar.ownerOf(uint256(_labelhash("adidas"))), treasury);
    }

    function test_reservedBatch_does_not_touch_totalSold() public {
        assertEq(oracle.namespaceInfo(arc.node).totalSold, 0);
        uint256 quoteBefore = arc.controller.quote("alice");
        string[] memory big = new string[](600);
        for (uint256 i = 0; i < big.length; i++) {
            big[i] = string.concat("brand", vm.toString(i));
        }
        vm.prank(genesis);
        arc.controller.registerReservedBatch(big);
        assertEq(arc.controller.reservedCount(), 600);
        assertEq(oracle.namespaceInfo(arc.node).totalSold, 0, "genesis is not a sale");
        assertEq(oracle.volumeBps(arc.node), 5000, "volume early-bird intact");
        assertEq(arc.controller.quote("alice"), quoteBefore);
    }

    function test_reservedBatch_non_canonical_reverts_loudly() public {
        string[] memory bad = new string[](2);
        bad[0] = "nike";
        bad[1] = "Nike";
        vm.prank(genesis);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.NotCanonical.selector, "Nike"));
        arc.controller.registerReservedBatch(bad);
        assertEq(arc.controller.reservedCount(), 0, "whole batch reverted");
    }

    function test_reservedBatch_role_gated_and_closed_after_seal() public {
        vm.prank(stranger);
        vm.expectRevert(_unauthorised(stranger, ArcNSConstants.GENESIS_ROLE));
        arc.controller.registerReservedBatch(reserved);
        vm.prank(admin);
        vm.expectRevert(_unauthorised(admin, ArcNSConstants.GENESIS_ROLE));
        arc.controller.registerReservedBatch(reserved);
        _genesis(arc, reserved, GENESIS_ROOT);
        vm.prank(genesis);
        vm.expectRevert(ITldRegistrarController.GenesisAlreadySealed.selector);
        arc.controller.registerReservedBatch(reserved);
    }

    function test_sealGenesis_revokes_role_and_is_final() public {
        vm.prank(genesis);
        arc.controller.registerReservedBatch(reserved);
        assertTrue(arc.controller.hasRole(ArcNSConstants.GENESIS_ROLE, genesis));
        vm.prank(genesis);
        vm.expectEmit(true, false, false, true);
        emit ITldRegistrarController.GenesisSealed(arc.node, GENESIS_ROOT, reserved.length);
        arc.controller.sealGenesis(GENESIS_ROOT);
        assertTrue(arc.controller.genesisSealed());
        assertEq(arc.controller.genesisRoot(), GENESIS_ROOT);
        assertFalse(arc.controller.hasRole(ArcNSConstants.GENESIS_ROLE, genesis), "role renounced in the same tx");
        vm.prank(genesis);
        vm.expectRevert(ITldRegistrarController.GenesisAlreadySealed.selector);
        arc.controller.sealGenesis(GENESIS_ROOT);
        // nobody can be re-granted the role afterwards, not even by the admin
        vm.prank(admin);
        vm.expectRevert(ITldRegistrarController.GenesisAlreadySealed.selector);
        arc.controller.grantRole(ArcNSConstants.GENESIS_ROLE, genesis);
        // `.circle` genesis is independent
        assertFalse(circle.controller.genesisSealed());
        assertTrue(circle.controller.hasRole(ArcNSConstants.GENESIS_ROLE, genesis));
        vm.prank(stranger);
        vm.expectRevert(_unauthorised(stranger, ArcNSConstants.GENESIS_ROLE));
        circle.controller.sealGenesis(GENESIS_ROOT);
    }

    // =============================================================================================
    // Grammar (SR-02) and price
    // =============================================================================================

    function test_label_grammar_rejects_non_canonical() public {
        _sealBoth();
        string[5] memory bad = ["Nike", "nik-", "a--b", "123", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"];
        for (uint256 i = 0; i < bad.length; i++) {
            assertFalse(arc.controller.valid(bad[i]), bad[i]);
            assertFalse(arc.controller.available(bad[i]), bad[i]);
            ITldRegistrarController.Registration memory r =
                _registration(bad[i], alice, keccak256("s"), address(0), false);
            vm.deal(alice, 1 ether);
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.NotCanonical.selector, bad[i]));
            arc.controller.register{value: 1 ether}(r, type(uint256).max);
        }
        assertTrue(arc.controller.valid("nike"));
        assertTrue(arc.controller.valid("a-b1"));
        assertTrue(arc.controller.valid("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    }

    function test_one_and_two_char_labels_are_registrable_when_not_reserved() public {
        _sealBoth();
        // "a" and "ab" are reserved by the genesis list; "z" and "zz" are not.
        assertFalse(arc.controller.available("a"));
        assertFalse(arc.controller.available("ab"));
        assertTrue(arc.controller.available("z"));
        assertTrue(arc.controller.available("zz"));
        uint256 p1 = _register(arc, _registration("z", alice, keccak256("s"), address(0), false), alice);
        uint256 p2 = _register(arc, _registration("zz", alice, keccak256("s"), address(0), false), alice);
        assertEq(p1, 12_500 * USDC);
        assertEq(p2, 1250 * USDC);
        assertEq(arc.registrar.ownerOf(uint256(_labelhash("z"))), alice);
        assertEq(arc.registrar.ownerOf(uint256(_labelhash("zz"))), alice);
    }

    function test_quote_matches_the_tld_table_at_launch() public view {
        assertEq(arc.controller.quote("nike"), 25e18);
        assertEq(circle.controller.quote("nike"), 25e18);
        assertEq(arc.controller.quote("abc"), 125e18);
        assertEq(arc.controller.quote("alice"), 5e18);
        assertEq(arc.controller.quote("abcdef"), 2.5e18);
        assertEq(arc.controller.quote("abcdefghij"), 1.25e18);
        assertEq(arc.controller.quote("nike"), oracle.quote(arc.node, "nike"));
        assertEq(arc.controller.namespaceId(), arc.node);
        assertEq(arc.controller.tldNode(), ArcNSConstants.ARC_NODE);
        assertEq(circle.controller.tldNode(), ArcNSConstants.CIRCLE_NODE);
        assertEq(arc.controller.tld(), "arc");
        assertEq(circle.controller.tld(), "circle");
    }

    // =============================================================================================
    // `.circle` and a third TLD behave identically ("TLD is data")
    // =============================================================================================

    function test_circle_registers_resolves_and_reverses() public {
        _sealBoth();
        bytes32 node = _node(circle, "alice");
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), true);
        uint256 price = _register(circle, r, alice);
        assertEq(price, 5 * USDC);
        assertEq(registry.owner(node), alice);
        assertEq(registry.resolver(node), address(resolver));
        assertEq(circle.registrar.ownerOf(uint256(_labelhash("alice"))), alice);
        assertEq(resolver.addr(node, ARC_COIN), abi.encodePacked(alice));
        assertEq(resolver.tldOf(node), circle.node);
        assertEq(resolver.name(reverse.node(alice)), "alice.circle");
        assertEq(oracle.namespaceInfo(circle.node).totalSold, 1);
        assertEq(oracle.namespaceInfo(arc.node).totalSold, 0);
        // the same label is independently available in `.arc`
        assertTrue(arc.controller.available("alice"));
        assertEq(arc.registrar.balanceOf(alice), 0);
    }

    function test_third_tld_added_at_runtime_works_with_no_code_change() public {
        Pair memory t = _addTld("test");
        assertEq(directory.count(), 3);
        assertEq(t.registrar.name(), "arcns .test names");
        assertEq(t.registrar.symbol(), "TEST");
        _genesis(t, reserved, GENESIS_ROOT);
        assertFalse(t.controller.available("nike"));
        bytes32 node = _node(t, "alice");
        _register(t, _registration("alice", alice, keccak256("s"), address(resolver), true), alice);
        assertEq(registry.owner(node), alice);
        assertEq(t.registrar.ownerOf(uint256(_labelhash("alice"))), alice);
        assertEq(resolver.name(reverse.node(alice)), "alice.test");
        assertEq(resolver.tldOf(node), t.node);
        string memory json = _decodeDataUri(t.registrar.tokenURI(uint256(_labelhash("alice"))));
        assertTrue(_contains(json, '"name":"alice.test"'));
        assertTrue(_contains(_decodeSvg(json), 'fill="#3b82f6"'), "default accent");
        // the shared contracts were not touched
        assertEq(address(t.controller.ens()), address(registry));
        assertEq(address(t.controller.oracle()), address(oracle));
        assertEq(address(t.controller.directory()), address(directory));
    }

    function test_arc_and_circle_controllers_share_one_bytecode() public view {
        assertEq(address(arc.controller).code.length, address(circle.controller).code.length);
        assertEq(address(arc.registrar).code.length, address(circle.registrar).code.length);
    }

    // =============================================================================================
    // Metadata (WP-143)
    // =============================================================================================

    function test_tokenURI_renders_the_display_name_for_both_tlds() public {
        _sealBoth();
        uint256 id = uint256(_labelhash("nike"));
        string memory arcJson = _decodeDataUri(arc.registrar.tokenURI(id));
        assertTrue(_contains(arcJson, '"name":"nike.arc"'), arcJson);
        assertTrue(_contains(arcJson, '{"trait_type":"namespace","value":"arc"}'));
        assertTrue(_contains(arcJson, '{"trait_type":"length","value":4}'));
        assertTrue(_contains(arcJson, '{"trait_type":"expires","value":"never"}'));
        assertFalse(_contains(arcJson, "0x"), "no hex labelhash in the JSON");
        string memory arcSvg = _decodeSvg(arcJson);
        assertTrue(_contains(arcSvg, ">nike.arc</text>"), arcSvg);
        assertTrue(_contains(arcSvg, 'fill="#22c55e"'));

        string memory circleJson = _decodeDataUri(circle.registrar.tokenURI(id));
        assertTrue(_contains(circleJson, '"name":"nike.circle"'), circleJson);
        string memory circleSvg = _decodeSvg(circleJson);
        assertTrue(_contains(circleSvg, ">nike.circle</text>"));
        assertTrue(_contains(circleSvg, 'fill="#a855f7"'));

        // paid registrations render the same way
        _register(arc, _registration("alice", alice, keccak256("s"), address(0), false), alice);
        string memory aliceJson = _decodeDataUri(arc.registrar.tokenURI(uint256(_labelhash("alice"))));
        assertTrue(_contains(aliceJson, '"name":"alice.arc"'));
    }

    function test_tokenURI_reverts_for_unknown_ids() public {
        _sealBoth();
        vm.expectRevert(bytes("TldRegistrar: unknown token"));
        arc.registrar.tokenURI(uint256(_labelhash("nobody")));
        vm.expectRevert(abi.encodeWithSelector(TldMetadata.UnknownRegistrar.selector, address(this)));
        metadata.tokenURI(address(this), 1);
        vm.expectRevert(abi.encodeWithSelector(TldMetadata.UnknownLabel.selector, address(arc.registrar), uint256(1)));
        metadata.tokenURI(address(arc.registrar), 1);
    }

    function test_contractURI_name_and_symbol() public view {
        string memory json = _decodeDataUri(arc.registrar.contractURI());
        assertTrue(_contains(json, '"name":"arcns .arc names"'), json);
        string memory cjson = _decodeDataUri(circle.registrar.contractURI());
        assertTrue(_contains(cjson, '"name":"arcns .circle names"'), cjson);
        assertEq(arc.registrar.name(), "arcns .arc names");
        assertEq(arc.registrar.symbol(), "ARC");
        assertEq(circle.registrar.name(), "arcns .circle names");
        assertEq(circle.registrar.symbol(), "CIRCLE");
        assertEq(arc.registrar.tldLabel(), "arc");
        assertEq(arc.registrar.metadata(), address(metadata));
        assertEq(arc.registrar.baseNode(), ArcNSConstants.ARC_NODE);
        assertEq(arc.registrar.owner(), admin, "ownership handed to the timelock");
        assertTrue(arc.registrar.controllers(address(arc.controller)));
        assertFalse(arc.registrar.controllers(address(circle.controller)));
    }

    // =============================================================================================
    // Per-TLD isolation (SR-09) and lifecycle
    // =============================================================================================

    function test_circle_lifecycle_leaves_arc_untouched() public {
        _sealBoth();
        bytes32 aliceNode = _node(arc, "alice");
        _register(arc, _registration("alice", alice, keccak256("s"), address(resolver), true), alice);
        _register(circle, _registration("alice", alice, keccak256("s"), address(resolver), false), alice);
        bytes32 arcBefore = _arcStateHash("alice");
        bytes32 circleNode = _node(circle, "alice");
        assertEq(resolver.addr(circleNode, ARC_COIN), abi.encodePacked(alice));

        // pause `.circle`
        vm.prank(pauser);
        directory.pause(circle.node);
        assertEq(_arcStateHash("alice"), arcBefore);
        assertTrue(directory.registrationsOpen(arc.node));

        // sunset `.circle`
        uint64 at = uint64(block.timestamp + 30 days);
        vm.prank(admin);
        directory.sunset(circle.node, at, address(0), address(0));
        assertEq(_arcStateHash("alice"), arcBefore);
        assertEq(resolver.addr(circleNode, ARC_COIN), abi.encodePacked(alice), "still resolves before sunsetAt");
        assertEq(resolver.addr(aliceNode, ARC_COIN), abi.encodePacked(alice));

        // `.arc` keeps registering while `.circle` is closed
        _register(arc, _registration("bob", bob, keccak256("s"), address(resolver), false), bob);
        assertEq(arc.registrar.ownerOf(uint256(_labelhash("bob"))), bob);
        arcBefore = _arcStateHash("alice");
        ITldRegistrarController.Registration memory rc = _registration("bob", bob, keccak256("s"), address(0), false);
        _commitAndWait(circle, rc, bob);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(ITldRegistrarController.RegistrationsClosed.selector);
        circle.controller.register{value: 1 ether}(rc, type(uint256).max);

        // retire `.circle` after sunsetAt
        vm.warp(at);
        assertFalse(directory.resolvable(circle.node));
        assertEq(resolver.addr(circleNode, ARC_COIN), "", "tagged circle node goes dark");
        vm.prank(admin);
        directory.retire(circle.node);
        assertEq(uint8(directory.statusOf(circle.node)), uint8(ITldDirectory.TldStatus.Retired));
        assertFalse(directory.resolvable(circle.node));
        assertEq(resolver.addr(circleNode, ARC_COIN), "");
        assertEq(resolver.addr(aliceNode, ARC_COIN), abi.encodePacked(alice), "arc still resolves");
        assertEq(_arcStateHash("alice"), arcBefore, "arc row and state unchanged after circle retire");
        // the circle token remains as an inert ERC-721 (never burned)
        assertEq(circle.registrar.ownerOf(uint256(_labelhash("alice"))), alice);
        assertEq(registry.owner(circleNode), alice);
        // register in the retired TLD is refused
        vm.prank(bob);
        circle.controller.commit(circle.controller.makeCommitment(rc));
        vm.warp(block.timestamp + MIN_AGE);
        vm.prank(bob);
        vm.expectRevert(ITldRegistrarController.RegistrationsClosed.selector);
        circle.controller.register{value: 1 ether}(rc, type(uint256).max);
    }

    function test_directory_controller_swap_gates_the_resolver_writes() public {
        _sealBoth();
        // A controller removed from the directory can no longer write to the resolver (mirrors C7).
        address v2 = makeAddr("controllerV2");
        vm.prank(admin);
        directory.setController(arc.node, v2);
        assertFalse(resolver.isAuthorised(_node(arc, "x"), address(arc.controller)));
        assertTrue(resolver.isAuthorised(_node(arc, "x"), v2));
    }

    // =============================================================================================
    // Constructor / ERC-165
    // =============================================================================================

    function _init() internal view returns (TldRegistrarController.Init memory i) {
        i = TldRegistrarController.Init({
            admin: admin,
            genesisAdmin: genesis,
            pauser: pauser,
            registrar: address(arc.registrar),
            ens: address(registry),
            oracle: address(oracle),
            resolver: address(resolver),
            reverseRegistrar: address(reverse),
            directory: address(directory),
            treasury: treasury,
            minCommitmentAge: MIN_AGE,
            maxCommitmentAge: MAX_AGE,
            tld: "arc"
        });
    }

    function test_constructor_validates_ages_addresses_and_tld() public {
        TldRegistrarController.Init memory i = _init();
        i.minCommitmentAge = 29;
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.MinCommitmentAgeBelowFloor.selector, 29, 30));
        new TldRegistrarController(i);
        i = _init();
        i.maxCommitmentAge = MIN_AGE;
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.MaxCommitmentAgeInvalid.selector, MIN_AGE));
        new TldRegistrarController(i);
        i = _init();
        i.maxCommitmentAge = 24 hours + 1;
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.MaxCommitmentAgeInvalid.selector, 24 hours + 1));
        new TldRegistrarController(i);
        i = _init();
        i.treasury = address(0);
        vm.expectRevert(TldRegistrarController.ZeroAddress.selector);
        new TldRegistrarController(i);
        i = _init();
        i.tld = "Arc";
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.NotCanonical.selector, "Arc"));
        new TldRegistrarController(i);
        // floor values are accepted
        i = _init();
        i.minCommitmentAge = 30;
        i.maxCommitmentAge = 31;
        TldRegistrarController c = new TldRegistrarController(i);
        assertEq(c.MIN_COMMITMENT_AGE_FLOOR(), 30);
        assertEq(c.minCommitmentAge(), 30);
        assertEq(c.maxCommitmentAge(), 31);
        assertEq(c.treasury(), treasury);
        assertTrue(c.hasRole(bytes32(0), admin));
        assertTrue(c.hasRole(ArcNSConstants.GENESIS_ROLE, genesis));
        assertTrue(c.hasRole(ArcNSConstants.PAUSER_ROLE, pauser));
    }

    function test_supportsInterface() public view {
        assertTrue(arc.controller.supportsInterface(type(IERC165).interfaceId));
        assertTrue(arc.controller.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(arc.controller.supportsInterface(type(ITldRegistrarController).interfaceId));
        assertFalse(arc.controller.supportsInterface(0xffffffff));
        assertTrue(arc.registrar.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(arc.registrar.supportsInterface(0x28ed4f6c), "reclaim");
    }

    // =============================================================================================
    // Launch allowlist (WP-144)
    // =============================================================================================

    function _pairHash(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Two-leaf tree over `alice` and `bob`; returns the root and each one's single-hash proof.
    function _twoLeafTree() internal view returns (bytes32 root, bytes32[] memory proofAlice, bytes32[] memory proofBob) {
        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob))));
        root = _pairHash(leafAlice, leafBob);
        proofAlice = new bytes32[](1);
        proofAlice[0] = leafBob;
        proofBob = new bytes32[](1);
        proofBob[0] = leafAlice;
    }

    function test_setAllowlist_reverts_not_admin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        arc.controller.setAllowlist(keccak256("root"), uint64(block.timestamp + 1 days));
    }

    function test_setAllowlist_reverts_bad_sunset_bounds() public {
        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ITldRegistrarController.AllowlistSunsetInvalid.selector, uint64(block.timestamp))
        );
        arc.controller.setAllowlist(keccak256("root"), uint64(block.timestamp));

        uint64 tooFar = uint64(block.timestamp + arc.controller.MAX_ALLOWLIST_WINDOW() + 1);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.AllowlistSunsetInvalid.selector, tooFar));
        arc.controller.setAllowlist(keccak256("root"), tooFar);

        uint64 atCeiling = uint64(block.timestamp + arc.controller.MAX_ALLOWLIST_WINDOW());
        arc.controller.setAllowlist(keccak256("root"), atCeiling);
        assertEq(arc.controller.allowlistRoot(), keccak256("root"));
        assertEq(arc.controller.allowlistSunset(), atCeiling);

        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.AllowlistSunsetInvalid.selector, uint64(1)));
        arc.controller.setAllowlist(bytes32(0), uint64(1));
        vm.stopPrank();
    }

    function test_setAllowlist_clears_and_emits() public {
        uint64 sunset = uint64(block.timestamp + 1 days);
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(arc.controller));
        emit ITldRegistrarController.AllowlistSet(keccak256("root"), sunset);
        arc.controller.setAllowlist(keccak256("root"), sunset);
        assertTrue(arc.controller.allowlistActive());

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(arc.controller));
        emit ITldRegistrarController.AllowlistSet(bytes32(0), 0);
        arc.controller.setAllowlist(bytes32(0), 0);
        assertFalse(arc.controller.allowlistActive());
    }

    /// @dev Each `TldRegistrarController` instance is independently gated: setting `.arc`'s allowlist
    ///      must not touch `.circle`'s (per-TLD control, mirroring the retirement/sunset independence
    ///      already required of every other per-TLD flag, SR-09).
    function test_allowlist_is_independent_per_tld_instance() public {
        vm.prank(admin);
        arc.controller.setAllowlist(keccak256("root"), uint64(block.timestamp + 1 days));
        assertTrue(arc.controller.allowlistActive());
        assertFalse(circle.controller.allowlistActive());
        assertEq(circle.controller.allowlistRoot(), bytes32(0));
    }

    function test_register_reverts_AllowlistRequired_while_active() public {
        _seal(arc);
        (bytes32 root,,) = _twoLeafTree();
        vm.prank(admin);
        arc.controller.setAllowlist(root, uint64(block.timestamp + 1 days));

        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(0), false);
        _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        vm.expectRevert(ITldRegistrarController.AllowlistRequired.selector);
        vm.prank(alice);
        arc.controller.register{value: price}(r, price);
    }

    function test_registerWithProof_happy_path_for_both_allowlisted_owners() public {
        _seal(arc);
        (bytes32 root, bytes32[] memory proofAlice, bytes32[] memory proofBob) = _twoLeafTree();
        vm.prank(admin);
        arc.controller.setAllowlist(root, uint64(block.timestamp + 1 days));

        ITldRegistrarController.Registration memory rAlice =
            _registration("alice", alice, keccak256("s"), address(0), false);
        _commitAndWait(arc, rAlice, alice);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, price);
        vm.prank(alice);
        arc.controller.registerWithProof{value: price}(rAlice, price, proofAlice);
        assertEq(arc.registrar.ownerOf(uint256(_labelhash("alice"))), alice);

        ITldRegistrarController.Registration memory rBob = _registration("bob", bob, keccak256("s"), address(0), false);
        _commitAndWait(arc, rBob, bob);
        price = arc.controller.quote("bob");
        vm.deal(bob, price);
        vm.prank(bob);
        arc.controller.registerWithProof{value: price}(rBob, price, proofBob);
        assertEq(arc.registrar.ownerOf(uint256(_labelhash("bob"))), bob);
    }

    function test_registerWithProof_reverts_NotAllowlisted_for_unlisted_owner_or_wrong_proof() public {
        _seal(arc);
        (bytes32 root, bytes32[] memory proofAlice,) = _twoLeafTree();
        vm.prank(admin);
        arc.controller.setAllowlist(root, uint64(block.timestamp + 1 days));

        // stranger is not in the tree at all
        ITldRegistrarController.Registration memory rStranger =
            _registration("coin", stranger, keccak256("s"), address(0), false);
        _commitAndWait(arc, rStranger, stranger);
        uint256 price = arc.controller.quote("coin");
        vm.deal(stranger, price);
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.NotAllowlisted.selector, stranger));
        vm.prank(stranger);
        arc.controller.registerWithProof{value: price}(rStranger, price, emptyProof);

        // alice's proof does not prove bob
        ITldRegistrarController.Registration memory rBob = _registration("bank", bob, keccak256("s"), address(0), false);
        _commitAndWait(arc, rBob, bob);
        price = arc.controller.quote("bank");
        vm.deal(bob, price);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.NotAllowlisted.selector, bob));
        vm.prank(bob);
        arc.controller.registerWithProof{value: price}(rBob, price, proofAlice);
    }

    function test_registerWithProof_ignores_proof_once_inactive() public {
        _seal(arc);
        (bytes32 root,,) = _twoLeafTree();
        uint64 sunset = uint64(block.timestamp + 1 days);
        vm.prank(admin);
        arc.controller.setAllowlist(root, sunset);

        vm.warp(sunset); // exclusive boundary: allowlistActive() is false AT sunset
        assertFalse(arc.controller.allowlistActive());

        // stranger is not on the list, but the window is closed: plain register works...
        ITldRegistrarController.Registration memory r = _registration("dao", stranger, keccak256("s"), address(0), false);
        _commitAndWait(arc, r, stranger);
        uint256 price = arc.controller.quote("dao");
        vm.deal(stranger, price);
        vm.prank(stranger);
        arc.controller.register{value: price}(r, price);
        assertEq(arc.registrar.ownerOf(uint256(_labelhash("dao"))), stranger);

        // ...and so does registerWithProof with a garbage proof, since the gate is skipped entirely.
        ITldRegistrarController.Registration memory r2 =
            _registration("eth", stranger, keccak256("s"), address(0), false);
        _commitAndWait(arc, r2, stranger);
        price = arc.controller.quote("eth");
        vm.deal(stranger, price);
        bytes32[] memory garbage = new bytes32[](1);
        garbage[0] = keccak256("not-a-real-sibling");
        vm.prank(stranger);
        arc.controller.registerWithProof{value: price}(r2, price, garbage);
        assertEq(arc.registrar.ownerOf(uint256(_labelhash("eth"))), stranger);
    }

    function testFuzz_setAllowlist_sunset_bounds(uint64 sunset) public {
        vm.assume(sunset != 0);
        uint256 t0 = block.timestamp;
        uint256 maxWindow = arc.controller.MAX_ALLOWLIST_WINDOW();
        vm.startPrank(admin);
        if (sunset <= t0 || sunset > t0 + maxWindow) {
            vm.expectRevert(abi.encodeWithSelector(ITldRegistrarController.AllowlistSunsetInvalid.selector, sunset));
            arc.controller.setAllowlist(keccak256("root"), sunset);
        } else {
            arc.controller.setAllowlist(keccak256("root"), sunset);
            assertEq(arc.controller.allowlistSunset(), sunset);
            assertEq(arc.controller.allowlistActive(), block.timestamp < sunset);
        }
        vm.stopPrank();
    }

    // =============================================================================================
    // Gas (reported, not asserted)
    // =============================================================================================

    function test_gas_report() public {
        _genesis(arc, reserved, GENESIS_ROOT);
        bytes32 node = _node(arc, "alice");
        ITldRegistrarController.Registration memory r =
            _registration("alice", alice, keccak256("s"), address(resolver), true);
        r.data = new bytes[](1);
        r.data[0] = abi.encodeWithSelector(MockResolver.setAddr.selector, node, uint256(60), abi.encodePacked(alice));
        _commitAndWait(arc, r, alice);
        uint256 price = arc.controller.quote("alice");
        vm.deal(alice, 2 * price);
        vm.prank(alice);
        uint256 g0 = gasleft();
        arc.controller.register{value: price}(r, price);
        uint256 gasWithResolver = g0 - gasleft();

        ITldRegistrarController.Registration memory r2 = _registration("bob", bob, keccak256("s"), address(0), false);
        _commitAndWait(arc, r2, bob);
        price = arc.controller.quote("bob");
        vm.deal(bob, price);
        vm.prank(bob);
        g0 = gasleft();
        arc.controller.register{value: price}(r2, price);
        uint256 gasNoResolver = g0 - gasleft();

        string[] memory batch = new string[](50);
        for (uint256 i = 0; i < 50; i++) {
            batch[i] = string.concat("reserved", vm.toString(i));
        }
        vm.prank(genesis);
        g0 = gasleft();
        circle.controller.registerReservedBatch(batch);
        uint256 gasBatch = g0 - gasleft();

        g0 = gasleft();
        arc.controller.quote("carol");
        uint256 gasQuote = g0 - gasleft();

        console2.log("gas register (resolver + addr + data + reverse):", gasWithResolver);
        console2.log("gas register (no resolver):", gasNoResolver);
        console2.log("gas registerReservedBatch per name (50-label batch):", gasBatch / 50);
        console2.log("gas quote:", gasQuote);
        assertGt(gasWithResolver, gasNoResolver);
    }
}
