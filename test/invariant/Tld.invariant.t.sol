// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ENSRegistry} from "@ensdomains/ens-contracts/registry/ENSRegistry.sol";

import {TldStackFixture} from "../tld/mocks/TldStackFixture.sol";
import {MockResolver} from "../tld/mocks/MockResolver.sol";
import {ArcNSPriceOracle} from "../../src/pricing/ArcNSPriceOracle.sol";
import {TldDirectory} from "../../src/tld/TldDirectory.sol";
import {TldRegistrar} from "../../src/tld/TldRegistrar.sol";
import {TldRegistrarController} from "../../src/tld/TldRegistrarController.sol";
import {ITldRegistrarController} from "../../src/interfaces/ITldRegistrarController.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";

/// @dev Drives two TLD pairs sharing one ENS stack: commits / reveals (in and out of the window),
///      raw ERC-721 transfers, `reclaim`, reserved batches pre-seal and `sealGenesis`.
///      Ghosts explain every legitimate divergence the invariants would otherwise flag.
contract TldHandler is Test {
    struct Reg {
        uint8 tld;
        uint256 id;
        bytes32 node;
    }

    uint256 internal constant MIN_AGE = 60;
    uint256 internal constant MAX_AGE = 24 hours;

    ENSRegistry public immutable registry;
    MockResolver public immutable resolver;
    ArcNSPriceOracle public immutable oracle;
    TldDirectory public immutable directory;
    address public immutable treasury;
    address public immutable genesis;

    TldRegistrar[2] public regs;
    TldRegistrarController[2] public ctls;
    bytes32[2] public nodes;
    address[3] public actors;
    string[] public pool;

    // ---- ghosts
    Reg[] public registered;
    mapping(uint8 tld => mapping(uint256 id => bool)) public reclaimPending;
    mapping(bytes32 => uint256) public commitTs; // key = keccak(tld, commitment)
    bool[2] public isSealed;
    uint256[2] public batches;

    uint256 public calls;
    uint256 public commitOk;
    uint256[2] public revealAttempts;
    /// @dev Reveal attempts made under conditions where `register` MUST succeed (see `_revealMustSucceed`).
    uint256 public revealsExpected;
    /// @dev ...of which reverted anyway. Any non-zero value is a liveness defect in the reveal path.
    uint256 public unexpectedRevealReverts;
    uint256 public registerOk;
    uint256 public registerRevert;
    uint256 public transferOk;
    uint256 public reclaimOk;
    uint256 public batchOk;
    uint256 public sealOk;
    uint256 public revealOutsideWindow;
    uint256 public preSealMintsNotToTreasury;
    uint256 public preSealPaidRegistrations;
    uint256 public arcMutatedByCircle;

    constructor(
        ENSRegistry registry_,
        MockResolver resolver_,
        ArcNSPriceOracle oracle_,
        TldDirectory directory_,
        address treasury_,
        address genesis_,
        TldRegistrar[2] memory regs_,
        TldRegistrarController[2] memory ctls_,
        address[3] memory actors_
    ) {
        registry = registry_;
        resolver = resolver_;
        oracle = oracle_;
        directory = directory_;
        treasury = treasury_;
        genesis = genesis_;
        regs = regs_;
        ctls = ctls_;
        nodes = [ctls_[0].tldNode(), ctls_[1].tldNode()];
        actors = actors_;
        for (uint256 i = 0; i < 40; i++) {
            pool.push(string.concat("name", vm.toString(i)));
        }
        pool.push("x");
        pool.push("yz");
        pool.push("nike");
    }

    // ---- views for the invariants --------------------------------------------------------------

    function registeredCount() external view returns (uint256) {
        return registered.length;
    }

    function poolLength() external view returns (uint256) {
        return pool.length;
    }

    /// @dev Everything `.arc` owns that a `.circle`-only action must never touch.
    function arcHash() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                directory.get(nodes[0]),
                registry.owner(nodes[0]),
                oracle.namespaceInfo(nodes[0]),
                regs[0].balanceOf(treasury),
                ctls[0].reservedCount(),
                ctls[0].genesisSealed(),
                address(regs[0]).balance,
                address(ctls[0]).balance
            )
        );
    }

    // ---- actions ---------------------------------------------------------------------------------

    function commit(uint8 tld, uint8 actor, uint8 label, bool withResolver) external {
        calls++;
        tld = tld % 2;
        bytes32 before = arcHash();
        ITldRegistrarController.Registration memory r = _reg(actor, label, withResolver);
        bytes32 c = ctls[tld].makeCommitment(r);
        vm.prank(actors[actor % 3]);
        try ctls[tld].commit(c) {
            commitTs[keccak256(abi.encode(tld, c))] = block.timestamp;
            commitOk++;
        } catch {}
        _circleGuard(tld, before);
    }

    /// @dev Commit, wait `wait` seconds (mostly inside the window, sometimes outside), reveal.
    function commitAndReveal(uint8 tld, uint8 actor, uint8 label, bool withResolver, uint32 wait) external {
        calls++;
        tld = tld % 2;
        bytes32 before = arcHash();
        ITldRegistrarController.Registration memory r = _reg(actor, label, withResolver);
        r.label = _freeLabel(tld, label);
        bytes32 c = ctls[tld].makeCommitment(r);
        bytes32 key = keccak256(abi.encode(tld, c));
        vm.prank(actors[actor % 3]);
        try ctls[tld].commit(c) {
            commitTs[key] = block.timestamp;
            commitOk++;
        } catch {}
        vm.warp(block.timestamp + bound(uint256(wait), 0, MAX_AGE + 120));
        _reveal(tld, r, key);
        _circleGuard(tld, before);
    }

    /// @dev Reveal against whatever commitment (if any) exists for these parameters.
    function reveal(uint8 tld, uint8 actor, uint8 label, bool withResolver) external {
        calls++;
        tld = tld % 2;
        bytes32 before = arcHash();
        ITldRegistrarController.Registration memory r = _reg(actor, label, withResolver);
        bytes32 c = ctls[tld].makeCommitment(r);
        _reveal(tld, r, keccak256(abi.encode(tld, c)));
        _circleGuard(tld, before);
    }

    /// @dev Raw ERC-721 transfer: ENS-verbatim, the registry owner does NOT follow until `reclaim`.
    function transferRaw(uint256 which, uint8 to) external {
        calls++;
        if (registered.length == 0) return;
        Reg memory g = registered[which % registered.length];
        bytes32 before = arcHash();
        address owner = regs[g.tld].ownerOf(g.id);
        address dest = actors[to % 3];
        vm.prank(owner);
        regs[g.tld].transferFrom(owner, dest, g.id);
        transferOk++;
        if (dest != owner) reclaimPending[g.tld][g.id] = true;
        _circleGuard(g.tld, before);
    }

    function reclaim(uint256 which) external {
        calls++;
        if (registered.length == 0) return;
        Reg memory g = registered[which % registered.length];
        bytes32 before = arcHash();
        address owner = regs[g.tld].ownerOf(g.id);
        vm.prank(owner);
        regs[g.tld].reclaim(g.id, owner);
        reclaimOk++;
        reclaimPending[g.tld][g.id] = false;
        _circleGuard(g.tld, before);
    }

    function reservedBatch(uint8 tld, uint8 count, uint8 seed) external {
        calls++;
        tld = tld % 2;
        if (isSealed[tld]) return;
        bytes32 before = arcHash();
        uint256 n = bound(uint256(count), 1, 6);
        string[] memory labels = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            labels[i] = pool[(uint256(seed) + i) % pool.length];
        }
        vm.prank(genesis);
        try ctls[tld].registerReservedBatch(labels) {
            batchOk++;
            batches[tld]++;
            for (uint256 i = 0; i < n; i++) {
                uint256 id = uint256(keccak256(bytes(labels[i])));
                if (regs[tld].ownerOf(id) != treasury && !reclaimPending[tld][id] && !_known(tld, id)) {
                    preSealMintsNotToTreasury++;
                }
                _track(tld, id);
            }
        } catch {}
        // Genesis is a finite ceremony: after a few batches the TLD seals itself.
        if (batches[tld] >= 3) _seal(tld);
        _circleGuard(tld, before);
    }

    function seal(uint8 tld) external {
        calls++;
        tld = tld % 2;
        bytes32 before = arcHash();
        _seal(tld);
        _circleGuard(tld, before);
    }

    function warp(uint32 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(uint256(dt), 0, 2 days));
    }

    // ---- internals -------------------------------------------------------------------------------

    function _reg(uint8 actor, uint8 label, bool withResolver)
        internal
        view
        returns (ITldRegistrarController.Registration memory r)
    {
        r.label = pool[label % pool.length];
        r.owner = actors[actor % 3];
        r.secret = keccak256(abi.encode(actor, label));
        r.resolver = withResolver ? address(resolver) : address(0);
        r.data = new bytes[](0);
        r.reverseRecord = withResolver;
    }

    /// @dev First available pool label at or after `start` (so a isSealed TLD's reveals mostly land).
    function _freeLabel(uint8 tld, uint8 start) internal view returns (string memory) {
        for (uint256 i = 0; i < pool.length; i++) {
            string memory l = pool[(uint256(start) + i) % pool.length];
            if (ctls[tld].available(l)) return l;
        }
        return pool[start % pool.length];
    }

    /// @dev The handler's own knowledge of ONE attempt: every precondition `register` checks holds, so a
    ///      revert would be a liveness defect, not a legitimate rejection. Mirrors the controller's order:
    ///      sealed + directory Active, not paused, canonical + free label, commitment inside
    ///      `[minCommitmentAge, maxCommitmentAge)` (ghost `commitTs` tracks the chain 1:1 — every commit
    ///      and every consuming reveal goes through this handler). The payer is funded and `maxPrice` is
    ///      the live quote inside `_reveal`, so those two preconditions hold by construction.
    function _revealMustSucceed(uint8 tld, ITldRegistrarController.Registration memory r, bytes32 key)
        internal
        view
        returns (bool)
    {
        uint256 committed = commitTs[key];
        if (committed == 0) return false;
        uint256 age = block.timestamp - committed;
        if (age < MIN_AGE || age >= MAX_AGE) return false;
        if (!ctls[tld].genesisSealed() || !directory.registrationsOpen(nodes[tld])) return false;
        if (ctls[tld].paused()) return false;
        return ctls[tld].available(r.label);
    }

    function _reveal(uint8 tld, ITldRegistrarController.Registration memory r, bytes32 key) internal {
        revealAttempts[tld]++;
        uint256 committed = commitTs[key];
        bool expected = _revealMustSucceed(tld, r, key);
        if (expected) revealsExpected++;
        uint256 price = ctls[tld].quote(r.label);
        address payer = actors[uint256(keccak256(abi.encode(r.secret))) % 3];
        vm.deal(payer, payer.balance + price);
        vm.prank(payer);
        try ctls[tld].register{value: price}(r, price) {
            registerOk++;
            uint256 age = block.timestamp - committed;
            if (committed == 0 || age < MIN_AGE || age >= MAX_AGE) revealOutsideWindow++;
            if (!isSealed[tld]) preSealPaidRegistrations++;
            uint256 id = uint256(keccak256(bytes(r.label)));
            if (!isSealed[tld] && regs[tld].ownerOf(id) != treasury) preSealMintsNotToTreasury++;
            _track(tld, id);
            reclaimPending[tld][id] = false;
            delete commitTs[key];
        } catch {
            registerRevert++;
            if (expected) unexpectedRevealReverts++;
        }
    }

    function _seal(uint8 tld) internal {
        if (isSealed[tld]) return;
        vm.prank(genesis);
        ctls[tld].sealGenesis(keccak256(abi.encode("root", tld)));
        isSealed[tld] = true;
        sealOk++;
    }

    function _track(uint8 tld, uint256 id) internal {
        if (_known(tld, id)) return;
        registered.push(Reg({tld: tld, id: id, node: keccak256(abi.encodePacked(nodes[tld], bytes32(id)))}));
    }

    function _known(uint8 tld, uint256 id) internal view returns (bool) {
        for (uint256 i = 0; i < registered.length; i++) {
            if (registered[i].tld == tld && registered[i].id == id) return true;
        }
        return false;
    }

    /// @dev Every `.circle`-scoped action (tld == 1) must leave the `.arc` hash untouched.
    function _circleGuard(uint8 tld, bytes32 before) internal {
        if (tld == 1 && arcHash() != before) arcMutatedByCircle++;
    }
}

/// @notice INV-1 / INV-7 / INV-9 on the real ENS stack with two TLD pairs (threat-model §3;
///         test/invariant/README.md rows WP-110 / WP-139 / WP-111), plus per-TLD storage isolation.
contract TldInvariantTest is TldStackFixture {
    TldHandler internal handler;

    function setUp() public {
        vm.chainId(ArcNSConstants.ARC_TESTNET_CHAIN_ID);
        _deployShared();
        arc = _addTld("arc");
        circle = _addTld("circle");
        address carol = makeAddr("carol");
        handler = new TldHandler(
            registry,
            resolver,
            oracle,
            directory,
            treasury,
            genesis,
            [arc.registrar, circle.registrar],
            [arc.controller, circle.controller],
            [alice, bob, carol]
        );
        targetContract(address(handler));
    }

    /// @dev ENS-verbatim behaviour: `BaseRegistrarImplementation.transferFrom` moves the ERC-721 only;
    ///      the ENS registry owner follows when the new holder calls `reclaim(id, owner)`. The ghost
    ///      `reclaimPending` must explain every divergence — nothing else may.
    function invariant_INV1_registrar_owner_is_the_only_authority() public view {
        uint256 n = handler.registeredCount();
        for (uint256 i = 0; i < n; i++) {
            (uint8 tld, uint256 id, bytes32 node) = handler.registered(i);
            TldRegistrar reg = tld == 0 ? arc.registrar : circle.registrar;
            address tokenOwner = reg.ownerOf(id);
            address ensOwner = registry.owner(node);
            if (ensOwner != tokenOwner) {
                assertTrue(handler.reclaimPending(tld, id), "divergence not explained by a pending reclaim");
            } else {
                // once re-aligned (or never moved) there is exactly one authority
                assertEq(ensOwner, tokenOwner);
            }
            assertEq(reg.nameExpires(id), type(uint64).max, "permanent");
        }
    }

    function invariant_INV7_pre_seal_mints_only_to_treasury() public view {
        assertEq(handler.preSealMintsNotToTreasury(), 0);
        assertEq(handler.preSealPaidRegistrations(), 0, "paid path closed before seal");
        TldRegistrarController[2] memory ctls = [arc.controller, circle.controller];
        for (uint8 t = 0; t < 2; t++) {
            if (ctls[t].genesisSealed()) {
                assertFalse(ctls[t].hasRole(ArcNSConstants.GENESIS_ROLE, genesis), "GENESIS_ROLE survives seal");
                assertFalse(ctls[t].hasRole(ArcNSConstants.GENESIS_ROLE, admin));
                assertFalse(ctls[t].hasRole(ArcNSConstants.GENESIS_ROLE, treasury));
                assertTrue(handler.isSealed(t));
            } else {
                assertTrue(ctls[t].hasRole(ArcNSConstants.GENESIS_ROLE, genesis));
            }
        }
    }

    function invariant_INV9_no_reveal_outside_window() public view {
        assertEq(handler.revealOutsideWindow(), 0);
    }

    function invariant_circle_ops_never_touch_arc_storage() public view {
        assertEq(handler.arcMutatedByCircle(), 0);
    }

    function invariant_oracle_totalSold_equals_paid_registrations() public view {
        uint256 paid;
        uint256 n = handler.registeredCount();
        for (uint256 i = 0; i < n; i++) {
            (uint8 tld, uint256 id,) = handler.registered(i);
            TldRegistrarController ctl = tld == 0 ? arc.controller : circle.controller;
            if (ctl.paidWei(bytes32(id)) > 0) paid++;
        }
        uint256 sold = oracle.namespaceInfo(arc.node).totalSold + oracle.namespaceInfo(circle.node).totalSold;
        assertEq(sold, handler.registerOk(), "every paid registration is one sale");
        assertEq(paid, handler.registerOk(), "reserved names never carry a price");
    }

    function invariant_call_counters_are_consistent() public view {
        assertEq(handler.registerOk() + handler.registerRevert(), handler.revealAttempts(0) + handler.revealAttempts(1));
        assertLe(handler.sealOk(), 2);
        assertLe(handler.revealsExpected(), handler.revealAttempts(0) + handler.revealAttempts(1));
    }

    /// @dev Liveness of the reveal path, judged per attempt: a reveal the handler made with every
    ///      precondition satisfied (`TldHandler._revealMustSucceed`) never reverts. Attempts the handler
    ///      deliberately places outside the window, on a taken label or before the seal are legitimate
    ///      rejections and are not counted, so the check does not depend on the fuzz seed.
    function invariant_reveal_succeeds_whenever_preconditions_hold() public view {
        assertEq(handler.unexpectedRevealReverts(), 0, "reveal reverted although every precondition held");
    }

    /// @dev Self-check of the handler's per-attempt judgement, so the liveness invariant above can never pass
    ///      vacuously: the ghost counts exactly the attempts the controller is bound to accept, and each
    ///      legitimate rejection (pre-seal, too new, too old, taken label) is left out.
    function test_handler_judges_reveal_preconditions_like_the_controller() public {
        // pre-seal: registrations closed, so not expected and rejected
        handler.commitAndReveal(0, 1, 3, false, 100);
        assertEq(handler.revealsExpected(), 0);
        assertEq(handler.registerRevert(), 1);
        handler.seal(0);
        // in-window on a free label (the earlier commitment, now 200 s old): expected and lands
        handler.commitAndReveal(0, 1, 3, false, 100);
        assertEq(handler.revealsExpected(), 1);
        assertEq(handler.registerOk(), 1);
        // too new / too old: not expected, rejected
        handler.commitAndReveal(0, 1, 4, true, 10);
        handler.commitAndReveal(0, 2, 5, false, uint32(MAX_AGE + 100));
        assertEq(handler.revealsExpected(), 1);
        assertEq(handler.registerRevert(), 3);
        // plain reveal path: first reveal of `name7` expected and lands, the re-commit + reveal of the now
        // taken label is not expected and rejected
        handler.commit(0, 0, 7, false);
        handler.warp(100);
        handler.reveal(0, 0, 7, false);
        assertEq(handler.revealsExpected(), 2);
        assertEq(handler.registerOk(), 2);
        handler.commit(0, 0, 7, false);
        handler.warp(100);
        handler.reveal(0, 0, 7, false);
        assertEq(handler.revealsExpected(), 2);
        assertEq(handler.registerRevert(), 4);
        assertEq(handler.unexpectedRevealReverts(), 0);
    }

    function afterInvariant() public view {
        // A run that only reverts is a broken handler: genesis or commits must have succeeded, and every
        // reveal made under must-succeed conditions must have landed (registerOk also counts reveals that
        // landed without being pre-judged, so `>=`).
        if (handler.calls() >= 64) {
            assertGt(handler.batchOk() + handler.commitOk(), 0, "no successful genesis or commit");
        }
        if (handler.revealsExpected() > 0) {
            assertGe(
                handler.registerOk(), handler.revealsExpected(), "fewer successful reveals than must-succeed attempts"
            );
        }
    }
}
