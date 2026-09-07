// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ENSRegistry} from "@ensdomains/ens-contracts/registry/ENSRegistry.sol";
import {ArcNSResolver} from "../../src/resolver/ArcNSResolver.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {HandleNormalize} from "../../src/lib/HandleNormalize.sol";
import {MockHandleRegistry} from "../resolver/mocks/MockHandleRegistry.sol";
import {MockTldDirectory} from "../resolver/mocks/MockTldDirectory.sol";
import {MockTldRegistrar} from "../resolver/mocks/MockTldRegistrar.sol";

/// @dev Handler: random record writes, simulated transfers (C1 epoch bumps, registrar transfers), `clearRecords`
///      and verified-flag writes across handle, sub-handle and tagged TLD nodes. Ghost = the last value written
///      per (node, coinType, versionKey) — keyed by the resolver's own `versionOf(node)` at write time, because
///      TLD nodes are owner-keyed and A -> B -> A legitimately brings A's earlier records back.
contract ResolverHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Ghost {
        bool written;
        bytes value;
        bool verified;
    }

    ArcNSResolver internal resolver;
    MockHandleRegistry internal handles;
    MockTldRegistrar internal registrar;

    bytes32[] public nodes; // 0,1: handles; 2: sub-handle of 0; 3: tagged carol.arc; 4: sub-handle of 1
    uint256[] internal tokenOf; // C1 tokenId (handle nodes) or registrar tokenId (TLD node)
    uint8[] internal kind; // 1 handle, 2 tld
    address[] internal actors;

    uint256[] internal coins = [0, 2, 3, 501, 5010000];

    /// @dev node => coinType => versionKey => last write under that key
    mapping(bytes32 => mapping(uint256 => mapping(bytes32 => Ghost))) public ghost;

    uint256 public writes;
    uint256 public transfers;
    uint256 public clears;
    uint256 public verifies;
    uint256 public reverted;

    constructor(ArcNSResolver _resolver, MockHandleRegistry _handles, MockTldRegistrar _registrar, address arcCtl) {
        resolver = _resolver;
        handles = _handles;
        registrar = _registrar;
        actors.push(vm.addr(0xA1));
        actors.push(vm.addr(0xA2));
        actors.push(vm.addr(0xA3));
        actors.push(vm.addr(0xA4));

        (uint256 t0, bytes32 n0) = handles.register("alice", actors[0]);
        (uint256 t1, bytes32 n1) = handles.register("bob", actors[1]);
        bytes32 s0 = handles.createSubname(t0, "pay");
        bytes32 s1 = handles.createSubname(t1, "pay");
        // NB: a handle tokenId is keccak256(name) and a registrar tokenId is labelhash(label) — the same hash — so
        // the TLD name uses a label no handle in this handler has, and owner lookups also match on `kind`.
        uint256 arcToken = uint256(HandleNormalize.labelhash("carol"));
        bytes32 arcNode = HandleNormalize.labelNode("carol", ArcNSConstants.ARC_NODE);
        registrar.mint(actors[2], arcToken);
        vm.prank(arcCtl);
        resolver.tagNode(arcNode, ArcNSConstants.ARC_NODE, arcToken);

        _push(n0, t0, 1);
        _push(n1, t1, 1);
        _push(s0, t0, 1);
        _push(arcNode, arcToken, 2);
        _push(s1, t1, 1);
    }

    function _push(bytes32 n, uint256 t, uint8 k) internal {
        nodes.push(n);
        tokenOf.push(t);
        kind.push(k);
    }

    function nodeCount() external view returns (uint256) {
        return nodes.length;
    }

    function coinCount() external view returns (uint256) {
        return coins.length;
    }

    function coinAt(uint256 i) external view returns (uint256) {
        return coins[i];
    }

    function _ownerOf(uint256 i) internal view returns (address) {
        if (kind[i] == 2) return registrar.ownerOf(tokenOf[i]);
        return handles.ownerOf(tokenOf[i]); // sub-handles follow their parent's owner
    }

    function setAddr(uint256 nodeSeed, uint256 coinSeed, bytes32 valueSeed) external {
        try this.doSetAddr(nodeSeed, coinSeed, valueSeed) {}
        catch {
            reverted++;
        }
    }

    function doSetAddr(uint256 nodeSeed, uint256 coinSeed, bytes32 valueSeed) external {
        require(msg.sender == address(this));
        uint256 i = nodeSeed % nodes.length;
        uint256 coin = coins[coinSeed % coins.length];
        bytes memory value = abi.encodePacked(valueSeed, uint8(nodeSeed)); // 33 bytes, never empty
        vm.prank(_ownerOf(i));
        resolver.setAddr(nodes[i], coin, value);
        ghost[nodes[i]][coin][resolver.versionOf(nodes[i])] = Ghost({written: true, value: value, verified: false});
        writes++;
    }

    function transfer(uint256 nodeSeed, uint256 toSeed) external {
        try this.doTransfer(nodeSeed, toSeed) {}
        catch {
            reverted++;
        }
    }

    function doTransfer(uint256 nodeSeed, uint256 toSeed) external {
        require(msg.sender == address(this));
        uint256 i = nodeSeed % nodes.length;
        address to = actors[toSeed % actors.length];
        if (kind[i] == 1) {
            handles.transfer(tokenOf[i], to); // epoch + 1 even when `to` is the current owner
        } else {
            address from = registrar.ownerOf(tokenOf[i]);
            if (from == to) return;
            vm.prank(from);
            registrar.transferFrom(from, to, tokenOf[i]);
        }
        transfers++;
    }

    function clear(uint256 nodeSeed) external {
        try this.doClear(nodeSeed) {}
        catch {
            reverted++;
        }
    }

    function doClear(uint256 nodeSeed) external {
        require(msg.sender == address(this));
        uint256 i = nodeSeed % nodes.length;
        vm.prank(_ownerOf(i));
        resolver.clearRecords(nodes[i]);
        clears++;
    }

    function verifySelf(uint256 nodeSeed) external {
        try this.doVerifySelf(nodeSeed) {}
        catch {
            reverted++;
        }
    }

    function doVerifySelf(uint256 nodeSeed) external {
        require(msg.sender == address(this));
        uint256 i = nodeSeed % nodes.length;
        uint256 coin = ArcNSConstants.evmCoinType();
        address who = _ownerOf(i);
        vm.prank(who);
        resolver.setAddr(nodes[i], coin, abi.encodePacked(who));
        vm.prank(who);
        resolver.verifyAddrSelf(nodes[i], coin);
        ghost[nodes[i]][coin][resolver.versionOf(nodes[i])] =
            Ghost({written: true, value: abi.encodePacked(who), verified: true});
        verifies++;
    }
}

/// @notice INV-2: `∀ record: resolve() returns it ⇔ record.epoch == name.epoch` (threat-model §3), here in its
///         structural form: a record is readable iff it was written under the node's current version key.
contract ResolverInvariantTest is Test {
    ResolverHandler internal handler;
    ArcNSResolver internal resolver;

    function setUp() public {
        vm.warp(1_757_000_000);
        ENSRegistry registry = new ENSRegistry();
        MockHandleRegistry handles = new MockHandleRegistry();
        MockTldDirectory directory = new MockTldDirectory();
        MockTldRegistrar arcRegistrar = new MockTldRegistrar("arc");
        address arcCtl = makeAddr("arcController");
        directory.add(ArcNSConstants.ARC_NODE, "arc", address(arcRegistrar), arcCtl, ArcNSConstants.ARC_NODE);
        resolver = new ArcNSResolver(
            registry, IHandleRegistry(address(handles)), directory, makeAddr("reverse"), makeAddr("admin")
        );
        handler = new ResolverHandler(resolver, handles, arcRegistrar, arcCtl);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ResolverHandler.setAddr.selector;
        selectors[1] = ResolverHandler.transfer.selector;
        selectors[2] = ResolverHandler.clear.selector;
        selectors[3] = ResolverHandler.verifySelf.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_INV2_records_readable_iff_written_under_current_version() public view {
        uint256 n = handler.nodeCount();
        uint256 c = handler.coinCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 node = handler.nodes(i);
            bytes32 current = resolver.versionOf(node);
            for (uint256 j = 0; j <= c; j++) {
                uint256 coin = j == c ? ArcNSConstants.evmCoinType() : handler.coinAt(j);
                (bool written, bytes memory value, bool wasVerified) = handler.ghost(node, coin, current);
                bytes memory got = resolver.addr(node, coin);
                if (written) {
                    assertEq(got, value, "record written under the current key must be readable");
                    assertEq(resolver.verified(node, coin), wasVerified, "verified flag follows the record");
                    assertTrue(resolver.hasAddr(node, coin));
                } else {
                    assertEq(got.length, 0, "record from another version must be unreachable");
                    assertFalse(resolver.verified(node, coin), "verified flag from another version is dead");
                    assertFalse(resolver.hasAddr(node, coin));
                }
            }
        }
    }

    /// @dev Call-success counters (test/invariant/README.md): none of the four actions may revert, so every
    ///      counter equals the number of times the fuzzer picked that selector. Checked at the end of each run
    ///      (depth 64 over 4 selectors) so a run that only reverts is caught as a broken handler.
    function invariant_handler_actions_never_revert() public view {
        assertEq(handler.reverted(), 0, "a handler action reverted");
    }

    function afterInvariant() public view {
        assertGt(handler.writes(), 0, "no successful writes");
        assertGt(handler.transfers(), 0, "no successful transfers");
        assertGt(handler.clears(), 0, "no successful clears");
        assertGt(handler.verifies(), 0, "no successful verifies");
    }
}
