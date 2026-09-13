// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {TldStackFixture} from "./mocks/TldStackFixture.sol";
import {MaliciousTreasury} from "./mocks/MaliciousTreasury.sol";
import {TldRegistrar} from "../../src/tld/TldRegistrar.sol";
import {TldMetadata} from "../../src/tld/TldMetadata.sol";
import {TldRegistrarControllerV3} from "../../src/tld/TldRegistrarControllerV3.sol";
import {ITldRegistrarController} from "../../src/interfaces/ITldRegistrarController.sol";
import {ITldRegistrarControllerV3} from "../../src/interfaces/ITldRegistrarControllerV3.sol";
import {IIntegratorRegistry} from "../../src/interfaces/IIntegratorRegistry.sol";
import {ITldDirectory} from "../../src/interfaces/ITldDirectory.sol";
import {IntegratorRegistry} from "../../src/parity/IntegratorRegistry.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {HandleNormalize} from "../../src/lib/HandleNormalize.sol";

/// @notice Unit tests for `TldRegistrarControllerV3` (WP #7773): a THIRD, purely additive controller
///         that sits alongside the existing V1 `TldRegistrarController` on the SAME `.arc`/`.circle`
///         `TldRegistrar` and `TldDirectory` row, against the real `ENSRegistry`/`Root`/
///         `ReverseRegistrar`/`TldRegistrar`/`TldDirectory`/`ArcNSPriceOracle` stack (via
///         `TldStackFixture`, the same fixture `TldRegistrarController.t.sol`/`...V2.t.sol` use).
///
/// @dev CEO requirement walkthrough (WP #7773 additivity design, mirrored from the director brief):
///        `registerDirect(label, owner, maxPrice)`
///          -> `_register(label, owner, maxPrice, address(0))`
///          -> `directory.registrationsOpen(tldNode)`         (READ-ONLY; V3 never calls
///               `TldDirectory.setController` and is never the row's controller)
///          -> `registrar.register(id, owner, duration)`      (the ONLY BaseRegistrar call V3 makes;
///               `TldRegistrar.controllers` is a plain `mapping(address => bool)`, so granting V3 here
///               never evicts V1/V2 — unlike `TldDirectory.setController`/`ArcNSPriceOracle.setController`,
///               which are single-address-per-node and WOULD evict whoever holds them today)
///          -> NO `oracle.recordSale`, NO `ens.setRecord`, NO `resolver.tagNode`, NO
///               `reverseRegistrar.setNameForAddr` — none of V1/V2's ENS/resolver/oracle-write surface
///               is reachable from this contract at all; it holds no reference to any of them.
///      Every test below either exercises `registerDirect`'s narrower surface directly, or proves one
///      of the two accepted, CEO-flagged side effects of that narrower surface: (a) `totalSold` for the
///      shared oracle namespace never advances from a V3 mint, and (b) `TldMetadata.tokenURI` cannot
///      render a name minted through V3 (it always defers to `TldDirectory.controllerOf`, i.e. V1/V2).
contract TldRegistrarControllerV3Test is TldStackFixture {
    IntegratorRegistry internal integratorRegistry;
    TldRegistrarControllerV3 internal v3;
    TldRegistrarControllerV3 internal v3Circle;
    address internal integrator = makeAddr("integrator");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        vm.chainId(ArcNSConstants.ARC_TESTNET_CHAIN_ID);
        _deployShared();
        arc = _addTld("arc"); // V1, the incumbent controller this deployment is additive to
        integratorRegistry = new IntegratorRegistry(admin);
        v3 = _addV3(arc);
    }

    /// @dev Deploys `TldRegistrarControllerV3` wired to the SAME `registrar`/`directory`/`oracle` node
    ///      as `p` (a V1 `Pair` already added via `TldStackFixture._addTld`) and grants it
    ///      `TldRegistrar.addController` — the one and only grant this contract ever needs. Crucially,
    ///      `directory.add(...)` is NOT called again: the directory's `controllerOf(p.node)` stays
    ///      whatever `p.controller` (V1) already is, proving V3 never becomes the directory controller.
    function _addV3(Pair memory p) internal returns (TldRegistrarControllerV3 ctl) {
        ctl = new TldRegistrarControllerV3(
            TldRegistrarControllerV3.Init({
                admin: admin,
                genesisAdmin: genesis,
                pauser: pauser,
                registrar: address(p.registrar),
                oracle: address(oracle),
                directory: address(directory),
                treasury: treasury,
                integratorRegistry: address(integratorRegistry),
                tld: p.label
            })
        );
        vm.prank(admin);
        p.registrar.addController(address(ctl));
    }

    function _addV3WithTreasury(Pair memory p, address treasury_) internal returns (TldRegistrarControllerV3 ctl) {
        ctl = new TldRegistrarControllerV3(
            TldRegistrarControllerV3.Init({
                admin: admin,
                genesisAdmin: genesis,
                pauser: pauser,
                registrar: address(p.registrar),
                oracle: address(oracle),
                directory: address(directory),
                treasury: treasury_,
                integratorRegistry: address(integratorRegistry),
                tld: p.label
            })
        );
        vm.prank(admin);
        p.registrar.addController(address(ctl));
    }

    function _sealV3(TldRegistrarControllerV3 ctl) internal {
        vm.startPrank(genesis);
        ctl.sealGenesis(bytes32(0));
        vm.stopPrank();
    }

    /// @dev Full `registerDirect` happy path as `who`: one tx, no commitment anywhere.
    function _registerDirect(TldRegistrarControllerV3 ctl, string memory label, address who)
        internal
        returns (uint256 price)
    {
        price = ctl.quote(label);
        vm.deal(who, who.balance + price);
        vm.prank(who);
        ctl.registerDirect{value: price}(label, who, price);
    }

    // =============================================================================================
    // Constructor
    // =============================================================================================

    function test_constructor_zero_address_reverts() public {
        TldRegistrarControllerV3.Init memory base = TldRegistrarControllerV3.Init({
            admin: admin,
            genesisAdmin: genesis,
            pauser: pauser,
            registrar: address(arc.registrar),
            oracle: address(oracle),
            directory: address(directory),
            treasury: treasury,
            integratorRegistry: address(integratorRegistry),
            tld: "zerotest"
        });

        TldRegistrarControllerV3.Init memory init = base;
        init.admin = address(0);
        vm.expectRevert(TldRegistrarControllerV3.ZeroAddress.selector);
        new TldRegistrarControllerV3(init);

        init = base;
        init.genesisAdmin = address(0);
        vm.expectRevert(TldRegistrarControllerV3.ZeroAddress.selector);
        new TldRegistrarControllerV3(init);

        init = base;
        init.pauser = address(0);
        vm.expectRevert(TldRegistrarControllerV3.ZeroAddress.selector);
        new TldRegistrarControllerV3(init);

        init = base;
        init.registrar = address(0);
        vm.expectRevert(TldRegistrarControllerV3.ZeroAddress.selector);
        new TldRegistrarControllerV3(init);

        init = base;
        init.oracle = address(0);
        vm.expectRevert(TldRegistrarControllerV3.ZeroAddress.selector);
        new TldRegistrarControllerV3(init);

        init = base;
        init.directory = address(0);
        vm.expectRevert(TldRegistrarControllerV3.ZeroAddress.selector);
        new TldRegistrarControllerV3(init);

        init = base;
        init.treasury = address(0);
        vm.expectRevert(TldRegistrarControllerV3.ZeroAddress.selector);
        new TldRegistrarControllerV3(init);

        init = base;
        init.integratorRegistry = address(0);
        vm.expectRevert(TldRegistrarControllerV3.ZeroAddress.selector);
        new TldRegistrarControllerV3(init);
    }

    // =============================================================================================
    // Happy path: no ENS/resolver record set, only the BaseRegistrar-level mint happens
    // =============================================================================================

    function test_registerDirect_happy_path_mints_no_ens_record_set() public {
        _sealV3(v3);
        bytes32 node = _node(arc, "direct1");

        assertEq(registry.owner(node), address(0), "no ENS record before registerDirect");
        assertEq(registry.resolver(node), address(0));

        uint256 price = _registerDirect(v3, "direct1", alice);

        assertGt(price, 0);
        assertEq(arc.registrar.ownerOf(uint256(_labelhash("direct1"))), alice, "ERC721 mint happened");
        assertEq(arc.registrar.nameExpires(uint256(_labelhash("direct1"))), type(uint64).max);
        assertEq(treasury.balance, price);
        assertEq(v3.paidWei(_labelhash("direct1")), price);

        // The resolver/ENS path is genuinely never touched: `registrar.register` only ever calls
        // `ens.setSubnodeOwner`, never `ens.setResolver`, so no resolver is ever attached to the node.
        assertEq(registry.resolver(node), address(0), "no resolver record set by registerDirect");
    }

    function test_registerDirect_emits_NameRegistered_with_zero_referrer() public {
        _sealV3(v3);
        uint256 price = v3.quote("evt1");
        vm.deal(alice, price);
        vm.expectEmit(true, true, false, true);
        emit ITldRegistrarControllerV3.NameRegistered(
            "evt1", _labelhash("evt1"), alice, price, 0, type(uint64).max, bytes32(0)
        );
        vm.prank(alice);
        v3.registerDirect{value: price}("evt1", alice, price);
    }

    // =============================================================================================
    // Revert table: price / value / availability / canonicality
    // =============================================================================================

    function test_registerDirect_priceChanged_insufficientValue_nameNotAvailable_notCanonical_revert() public {
        _sealV3(v3);

        // PriceChanged: maxPrice below the live quote
        uint256 price = v3.quote("tbl1");
        vm.deal(alice, price);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarControllerV3.PriceChanged.selector, price, price - 1));
        vm.prank(alice);
        v3.registerDirect{value: price}("tbl1", alice, price - 1);

        // InsufficientValue: correct maxPrice, underpaid msg.value
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarControllerV3.InsufficientValue.selector, price, price - 1));
        vm.prank(alice);
        v3.registerDirect{value: price - 1}("tbl1", alice, price);

        // NameNotAvailable: register once, then try again
        vm.prank(alice);
        v3.registerDirect{value: price}("tbl1", alice, price);
        uint256 price2 = 1_000_000 ether;
        vm.deal(bob, price2);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarControllerV3.NameNotAvailable.selector, "tbl1"));
        vm.prank(bob);
        v3.registerDirect{value: price2}("tbl1", bob, price2);

        // NotCanonical: uppercase label
        vm.deal(alice, price2);
        vm.expectRevert(abi.encodeWithSelector(ITldRegistrarControllerV3.NotCanonical.selector, "UPPER"));
        vm.prank(alice);
        v3.registerDirect{value: price2}("UPPER", alice, price2);
    }

    // =============================================================================================
    // RegistrationsClosed: directory-level pause (shared, read-only gate) and pre-seal
    // =============================================================================================

    function test_registerDirect_registrationsClosed_when_directory_paused() public {
        _sealV3(v3);
        vm.prank(pauser);
        directory.pause(arc.node);

        uint256 price = v3.quote("dirpaused");
        vm.deal(alice, price);
        vm.expectRevert(ITldRegistrarControllerV3.RegistrationsClosed.selector);
        vm.prank(alice);
        v3.registerDirect{value: price}("dirpaused", alice, price);
    }

    function test_registerDirect_registrationsClosed_before_v3_sealGenesis() public {
        // v3 has NOT been sealed in this test (setUp only deploys + adds controller).
        uint256 price = v3.quote("presealx");
        vm.deal(alice, price);
        vm.expectRevert(ITldRegistrarControllerV3.RegistrationsClosed.selector);
        vm.prank(alice);
        v3.registerDirect{value: price}("presealx", alice, price);
    }

    // =============================================================================================
    // Pause / withdraw independence
    // =============================================================================================

    function test_registerDirect_blocked_while_v3_paused_but_withdraw_still_works() public {
        _sealV3(v3);
        uint256 price = _registerDirect(v3, "overpay1", alice);
        // credit alice with an excess balance via a second, overpaid call
        uint256 price2 = v3.quote("overpay2");
        vm.deal(alice, price2 + 1 ether);
        vm.prank(alice);
        v3.registerDirect{value: price2 + 1 ether}("overpay2", alice, price2 + 1 ether);
        assertEq(v3.withdrawable(alice), 1 ether);

        vm.prank(pauser);
        v3.pause();
        assertTrue(v3.paused());

        vm.deal(bob, 10 ether);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(bob);
        v3.registerDirect{value: 1 ether}("blockedwhilepaused", bob, 1 ether);

        // withdraw is unaffected by pause()
        uint256 before = alice.balance;
        vm.prank(alice);
        v3.withdraw();
        assertEq(alice.balance, before + 1 ether);

        vm.prank(admin);
        v3.unpause();
        assertFalse(v3.paused());
        uint256 price3 = _registerDirect(v3, "afterunpause", bob);
        assertGt(price3, 0);
        assertGt(price, 0);
    }

    // =============================================================================================
    // Allowlist: no proof escape hatch on this controller
    // =============================================================================================

    function test_registerDirect_blocked_during_v3_allowlist_window_with_no_proof_escape_hatch() public {
        _sealV3(v3);
        bytes32 root_ = keccak256("root");
        vm.prank(admin);
        v3.setAllowlist(root_, uint64(block.timestamp + 1 days));
        assertTrue(v3.allowlistActive());

        uint256 price = v3.quote("allowblocked");
        vm.deal(alice, price);
        vm.expectRevert(ITldRegistrarControllerV3.AllowlistRequired.selector);
        vm.prank(alice);
        v3.registerDirect{value: price}("allowblocked", alice, price);

        // no such thing as registerDirectWithProof on the ABI: any attempt hits the fallback
        bytes memory callData = abi.encodeWithSignature(
            "registerDirectWithProof(string,address,uint256,bytes32[])", "allowblocked", alice, price, new bytes32[](0)
        );
        vm.deal(alice, price);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(v3).call{value: price}(callData);
        assertFalse(ok);
        assertEq(bytes4(ret), ITldRegistrarControllerV3.ValueNotAccepted.selector, "no proof escape hatch exists");

        // clearing the allowlist unblocks registerDirect again
        vm.prank(admin);
        v3.setAllowlist(bytes32(0), 0);
        uint256 price2 = _registerDirect(v3, "allowblocked", alice);
        assertGt(price2, 0);
    }

    // =============================================================================================
    // Additivity: V1 keeps the directory controller slot and keeps working after V3 is granted
    // =============================================================================================

    function test_v1_or_v2_still_holds_directory_controllerOf_and_still_works_after_v3_addController_granted() public {
        address controllerBefore = directory.controllerOf(arc.node);
        assertEq(controllerBefore, address(arc.controller));

        // v3 is already granted `addController` in setUp(); re-confirm the invariant explicitly here.
        assertTrue(arc.registrar.controllers(address(v3)));
        assertEq(directory.controllerOf(arc.node), controllerBefore, "V3 grant never touches the directory row");

        // Full V1 commit/reveal cycle, including its resolver + reverse-record path, still works.
        _genesis(arc, new string[](0), bytes32(0));
        ITldRegistrarController.Registration memory r =
            _registration("stillworks", alice, keccak256("s"), address(resolver), true);
        uint64 totalSoldBefore = oracle.namespaceInfo(arc.node).totalSold;
        uint256 price = _register(arc, r, alice);

        assertEq(arc.registrar.ownerOf(uint256(_labelhash("stillworks"))), alice);
        assertEq(treasury.balance, price);
        assertEq(oracle.namespaceInfo(arc.node).totalSold, totalSoldBefore + 1, "V1's own recordSale still fires");
        assertEq(directory.controllerOf(arc.node), controllerBefore, "still V1 after the full cycle");
    }

    // =============================================================================================
    // oracle.recordSale is never invoked from registerDirect (critical regression guard)
    // =============================================================================================

    function test_oracle_recordSale_never_invoked_totalSold_unchanged_for_tldNode_after_registerDirect() public {
        _sealV3(v3);
        uint64 totalSoldBefore = oracle.namespaceInfo(arc.node).totalSold;

        _registerDirect(v3, "nosale1", alice);
        _registerDirect(v3, "nosale2", bob);
        _registerDirect(v3, "nosale3", alice);

        assertEq(
            oracle.namespaceInfo(arc.node).totalSold,
            totalSoldBefore,
            "V3-driven registerDirect mints must never advance the shared oracle's totalSold"
        );
    }

    function test_oracle_recordSale_never_invoked_for_a_second_tld_circle() public {
        circle = _addTld("circle");
        v3Circle = _addV3(circle);
        _sealV3(v3Circle);

        uint64 totalSoldBefore = oracle.namespaceInfo(circle.node).totalSold;
        _registerDirect(v3Circle, "circledirect", alice);
        assertEq(oracle.namespaceInfo(circle.node).totalSold, totalSoldBefore, "same guarantee holds for .circle");
    }

    // =============================================================================================
    // Known, accepted limitation: TldMetadata.tokenURI cannot render a V3-minted name's label
    // =============================================================================================

    /// @dev `TldMetadata.tokenURI` always resolves the label through
    ///      `ITldRegistrarController(TldDirectory.get(tldNode).controller).labelOf(...)` — i.e.
    ///      whichever controller the DIRECTORY currently names (V1 here), never V3, regardless of who
    ///      actually minted the token. Since V1's own `labels[labelhash]` was never populated for a
    ///      name registered through V3, the lookup returns the empty string and `TldMetadata` reverts
    ///      `UnknownLabel` (verified against the actual `TldMetadata.sol` logic, not merely blank
    ///      output) — this is the exact, verified shape of the documented metadata gap.
    function test_tokenURI_for_v3_registered_name_reverts_unknownLabel_known_limitation() public {
        _sealV3(v3);
        _registerDirect(v3, "metadatagap", alice);
        uint256 tokenId = uint256(_labelhash("metadatagap"));

        // V3's own bookkeeping is correct and independently readable...
        assertEq(v3.labelOf(_labelhash("metadatagap")), "metadatagap");
        // ...but the shared TldRegistrar.tokenURI (delegating to TldMetadata) cannot see it, because
        // TldMetadata only ever asks the directory's controller (V1), which has no record of this id.
        vm.expectRevert(abi.encodeWithSelector(TldMetadata.UnknownLabel.selector, address(arc.registrar), tokenId));
        arc.registrar.tokenURI(tokenId);
    }

    // =============================================================================================
    // Local bookkeeping is correct independent of the tokenURI limitation above
    // =============================================================================================

    function test_paidWei_and_labels_populated_locally_on_v3() public {
        _sealV3(v3);
        uint256 price = _registerDirect(v3, "localbook", alice);
        assertEq(v3.paidWei(_labelhash("localbook")), price);
        assertEq(v3.labelOf(_labelhash("localbook")), "localbook");
    }

    // =============================================================================================
    // Genesis: reserved batch is a safe no-op (names already exist under V1), no tagNode call
    // =============================================================================================

    function test_registerReservedBatch_no_longer_calls_tagNode_and_is_a_noop_when_names_already_exist() public {
        // Mint "already1" under V1's genesis first, so it exists by the time V3's batch runs.
        string[] memory v1Reserved = new string[](1);
        v1Reserved[0] = "already1";
        vm.prank(genesis);
        arc.controller.registerReservedBatch(v1Reserved);
        assertEq(arc.registrar.ownerOf(uint256(_labelhash("already1"))), treasury);

        string[] memory v3Reserved = new string[](1);
        v3Reserved[0] = "already1";
        vm.prank(genesis);
        v3.registerReservedBatch(v3Reserved); // does not revert; mint is skipped (`continue`)
        assertEq(v3.reservedCount(), 0, "already-registered label is skipped, not re-minted");
        assertEq(v3.labelOf(_labelhash("already1")), "", "V3 never wrote a label for a name it did not mint");
        // ownership unchanged: still the treasury from V1's mint, not re-assigned
        assertEq(arc.registrar.ownerOf(uint256(_labelhash("already1"))), treasury);
    }

    function test_genesis_batch_and_seal_work_through_v3() public {
        string[] memory reservedLabels = new string[](1);
        reservedLabels[0] = "v3reserved1";
        vm.prank(genesis);
        v3.registerReservedBatch(reservedLabels);
        assertEq(v3.reservedCount(), 1);
        assertEq(arc.registrar.ownerOf(uint256(_labelhash("v3reserved1"))), treasury);

        // a second GENESIS_ROLE holder, granted BEFORE the seal (INV-7 forbids granting it after)
        vm.prank(admin);
        v3.grantRole(ArcNSConstants.GENESIS_ROLE, bob);

        vm.prank(genesis);
        v3.sealGenesis(bytes32(0));
        assertTrue(v3.genesisSealed());
        assertFalse(v3.hasRole(ArcNSConstants.GENESIS_ROLE, genesis));

        vm.expectRevert(ITldRegistrarControllerV3.GenesisAlreadySealed.selector);
        vm.prank(bob);
        v3.sealGenesis(bytes32(0));
    }

    function test_grantRole_genesisRole_after_seal_reverts() public {
        _sealV3(v3);
        vm.expectRevert(ITldRegistrarControllerV3.GenesisAlreadySealed.selector);
        vm.prank(admin);
        v3.grantRole(ArcNSConstants.GENESIS_ROLE, bob);
    }

    // =============================================================================================
    // Reentrancy
    // =============================================================================================

    function test_reentrancy_blocked_on_register_via_malicious_treasury() public {
        MaliciousTreasury bad = new MaliciousTreasury();
        Pair memory badPair = _addTld("badtldv3");
        TldRegistrarControllerV3 badV3 = _addV3WithTreasury(badPair, address(bad));
        bad.setTarget(address(badV3));
        _sealV3(badV3);

        bad.setReentryCalldata(abi.encodeWithSignature("withdraw()"));

        uint256 price = badV3.quote("reentrytest");
        vm.deal(alice, price);
        vm.prank(alice);
        badV3.registerDirect{value: price}("reentrytest", alice, price);

        assertTrue(bad.attempted());
        assertFalse(bad.reentrantCallOk());
        assertEq(bytes4(bad.reentrantReturnData()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(
            badPair.registrar.ownerOf(uint256(_labelhash("reentrytest"))), alice, "outer registration still succeeded"
        );
    }

    function test_reentrancy_blocked_on_withdraw_via_malicious_treasury() public {
        MaliciousTreasury bad = new MaliciousTreasury();
        Pair memory badPair = _addTld("badtldv3b");
        TldRegistrarControllerV3 badV3 = _addV3WithTreasury(badPair, address(bad));
        bad.setTarget(address(badV3));
        _sealV3(badV3);

        // Overpay to credit `bad` (the treasury) itself via the pull ledger isn't possible (treasury
        // is paid directly by `_settle`, not through withdrawable); instead exercise reentrancy on the
        // withdraw path by crediting `alice` via overpayment and having `bad`'s receive() attempt to
        // reenter `withdraw()` mid-treasury-payment on a SEPARATE registration.
        uint256 price = badV3.quote("wdreentry");
        vm.deal(alice, price + 1 ether);
        bad.setReentryCalldata(abi.encodeWithSignature("withdraw()"));
        vm.prank(alice);
        badV3.registerDirect{value: price + 1 ether}("wdreentry", alice, price + 1 ether);

        assertTrue(bad.attempted());
        assertFalse(bad.reentrantCallOk(), "reentrant withdraw() call during treasury payout must fail");
        assertEq(bytes4(bad.reentrantReturnData()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(badV3.withdrawable(alice), 1 ether, "alice's overpayment credit is intact and separately withdrawable");
    }

    // =============================================================================================
    // Integrator branch is dead code from registerDirect (integrator == address(0) short-circuits)
    // =============================================================================================

    function test_integratorRegistry_never_called_from_registerDirect_even_if_it_would_revert() public {
        RevertingIntegratorRegistry bad = new RevertingIntegratorRegistry();
        Pair memory p = _addTld("deadbranchv3");
        TldRegistrarControllerV3 ctl = new TldRegistrarControllerV3(
            TldRegistrarControllerV3.Init({
                admin: admin,
                genesisAdmin: genesis,
                pauser: pauser,
                registrar: address(p.registrar),
                oracle: address(oracle),
                directory: address(directory),
                treasury: treasury,
                integratorRegistry: address(bad),
                tld: p.label
            })
        );
        vm.prank(admin);
        p.registrar.addController(address(ctl));
        _sealV3(ctl);

        uint256 price = ctl.quote("deadbranch1");
        vm.deal(alice, price);
        vm.prank(alice);
        ctl.registerDirect{value: price}("deadbranch1", alice, price); // does not revert
        assertEq(p.registrar.ownerOf(uint256(_labelhash("deadbranch1"))), alice);
    }

    // =============================================================================================
    // Wrong role cannot call the registrar directly
    // =============================================================================================

    function test_wrong_role_cannot_call_registrar_register_directly() public {
        assertFalse(arc.registrar.controllers(attacker));
        vm.expectRevert();
        vm.prank(attacker);
        arc.registrar.register(uint256(_labelhash("hijack")), attacker, 365 days);
    }

    // =============================================================================================
    // ABI/selector-shape guard: no resolver/data/reverseRecord param exists anywhere on V3
    // =============================================================================================

    function test_registerDirect_signature_has_no_resolver_data_reverseRecord_params() public view {
        assertTrue(v3.supportsInterface(type(ITldRegistrarControllerV3).interfaceId));
        assertFalse(
            v3.supportsInterface(type(ITldRegistrarController).interfaceId),
            "V3 must never advertise the V1/V2 resolver-taking interface"
        );
    }

    function test_no_resolver_taking_register_selector_exists_on_v3() public {
        _sealV3(v3);
        ITldRegistrarController.Registration memory r =
            _registration("noselector", alice, keccak256("s"), address(resolver), false);
        bytes memory callData =
            abi.encodeWithSignature("register((string,address,bytes32,address,bytes[],bool),uint256)", r, 1 ether);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(v3).call{value: 0}(callData);
        assertFalse(ok);
        assertEq(bytes4(ret), ITldRegistrarControllerV3.ValueNotAccepted.selector, "hits the payable fallback");
    }
}

/// @dev IntegratorRegistry stand-in whose views unconditionally revert, so any call into it from
///      `_register`'s dead integrator branch would be immediately observable as a test failure.
contract RevertingIntegratorRegistry is IIntegratorRegistry {
    error AlwaysReverts();

    function CAP_BPS() external pure returns (uint16) {
        revert AlwaysReverts();
    }

    function isIntegrator(address) external pure returns (bool) {
        revert AlwaysReverts();
    }

    function defaultRateBps() external pure returns (uint16) {
        revert AlwaysReverts();
    }

    function rateOf(address) external pure returns (uint16) {
        revert AlwaysReverts();
    }

    function computeSplit(address, uint256) external pure returns (uint256) {
        revert AlwaysReverts();
    }

    function setIntegrator(address, bool) external pure {
        revert AlwaysReverts();
    }

    function setIntegratorRate(address, uint16) external pure {
        revert AlwaysReverts();
    }

    function setDefaultRate(uint16) external pure {
        revert AlwaysReverts();
    }
}
