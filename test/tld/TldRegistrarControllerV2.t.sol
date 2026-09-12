// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {TldStackFixture} from "./mocks/TldStackFixture.sol";
import {MaliciousTreasury} from "./mocks/MaliciousTreasury.sol";
import {TldRegistrar} from "../../src/tld/TldRegistrar.sol";
import {TldRegistrarControllerV2} from "../../src/tld/TldRegistrarControllerV2.sol";
import {ITldRegistrarController} from "../../src/interfaces/ITldRegistrarController.sol";
import {ITldRegistrarControllerV2} from "../../src/interfaces/ITldRegistrarControllerV2.sol";
import {IIntegratorRegistry} from "../../src/interfaces/IIntegratorRegistry.sol";
import {IntegratorRegistry} from "../../src/parity/IntegratorRegistry.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {HandleNormalize} from "../../src/lib/HandleNormalize.sol";

/// @notice Unit tests for `TldRegistrarControllerV2` (WP #7772): the integrator revenue-share overload
///         on top of `TldRegistrarController`'s unmodified commit-reveal / genesis / allowlist / pause
///         surface, against the real `ENSRegistry` / `Root` / `ReverseRegistrar` / `TldRegistrar` /
///         `TldDirectory` / `ArcNSPriceOracle` stack (via `TldStackFixture`, the same fixture
///         `TldRegistrarController.t.sol` uses).
///
/// @dev CEO requirement walkthrough (WP #7772: "it needs to be whitelisted from an admin, don't want
///      it abused") — the exact resolution path exercised by every test below:
///        `registerWithIntegrator`/`registerWithProofAndIntegrator`
///          -> `_register(registration, maxPrice, integrator)`
///          -> `integratorRegistry.rateOf(integrator)`     (IntegratorRegistry.rateOf, view; reverts
///               `NotIntegrator` unless the timelock called `setIntegrator(integrator, true)` first)
///          -> `_settle(...)` -> `integratorRegistry.computeSplit(integrator, price)` (re-derives the
///               SAME `rateOf`, hard-clamped to `CAP_BPS = 4000` inside `IntegratorRegistry` itself)
///      `TldRegistrarControllerV2` never allow-lists, never sets a rate, and never grants itself any
///      role on `IntegratorRegistry` — see `test_no_rate_setter_reachable_on_controller` and
///      `test_no_self_registration_no_matter_the_entry_point` below.
contract TldRegistrarControllerV2Test is TldStackFixture {
    struct PairV2 {
        TldRegistrar registrar;
        TldRegistrarControllerV2 controller;
        bytes32 node;
        string label;
    }

    uint16 internal constant CAP_BPS = 4000;

    IntegratorRegistry internal integratorRegistry;
    PairV2 internal v2;
    address internal integrator = makeAddr("integrator");
    address internal notIntegrator = makeAddr("notIntegrator");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        vm.chainId(ArcNSConstants.ARC_TESTNET_CHAIN_ID);
        _deployShared();
        arc = _addTld("arc"); // V1, for the side-by-side parity legs
        integratorRegistry = new IntegratorRegistry(admin);
        v2 = _addTldV2("arcv2");

        vm.prank(admin);
        integratorRegistry.setIntegrator(integrator, true);
    }

    /// @dev Mirrors `TldStackFixture._addTld`, constructing `TldRegistrarControllerV2` instead, wired
    ///      to the SAME shared `ENSRegistry`/`root`/`reverse`/`directory`/`oracle`/`resolver` and the
    ///      SAME `_tldTiers()` pricing curve as every V1 `Pair`, so quotes for equal-length labels are
    ///      byte-identical between a V1 leg and a V2 leg.
    function _addTldV2(string memory label) internal returns (PairV2 memory p) {
        bytes32 node = HandleNormalize.tldNode(label);
        TldRegistrar reg = new TldRegistrar(registry, node, label, address(metadata), address(this));
        TldRegistrarControllerV2 ctl = new TldRegistrarControllerV2(
            TldRegistrarControllerV2.Init({
                admin: admin,
                genesisAdmin: genesis,
                pauser: pauser,
                registrar: address(reg),
                ens: address(registry),
                oracle: address(oracle),
                resolver: address(resolver),
                reverseRegistrar: address(reverse),
                directory: address(directory),
                treasury: treasury,
                integratorRegistry: address(integratorRegistry),
                minCommitmentAge: MIN_AGE,
                maxCommitmentAge: MAX_AGE,
                tld: label
            })
        );
        root.setSubnodeOwner(keccak256(bytes(label)), address(reg));
        reg.addController(address(ctl));
        reg.transferOwnership(admin);
        reverse.setController(address(ctl), true);

        vm.startPrank(admin);
        directory.add(node, label, address(reg), address(ctl), node);
        oracle.initNamespace(node, address(ctl), address(0), uint64(block.timestamp), _tldTiers(), _zeroTiers());
        vm.stopPrank();

        p = PairV2({registrar: reg, controller: ctl, node: node, label: label});
    }

    function _sealV2(PairV2 memory p) internal {
        vm.startPrank(genesis);
        p.controller.sealGenesis(bytes32(0));
        vm.stopPrank();
    }

    function _commitAndWaitV2(PairV2 memory p, ITldRegistrarController.Registration memory r, address who)
        internal
        returns (bytes32 commitment)
    {
        commitment = p.controller.makeCommitment(r);
        vm.prank(who);
        p.controller.commit(commitment);
        vm.warp(block.timestamp + MIN_AGE);
    }

    function _registerV2(PairV2 memory p, ITldRegistrarController.Registration memory r, address who)
        internal
        returns (uint256 price)
    {
        _commitAndWaitV2(p, r, who);
        price = p.controller.quote(r.label);
        vm.deal(who, who.balance + price);
        vm.prank(who);
        p.controller.register{value: price}(r, price);
    }

    // =============================================================================================
    // Constructor
    // =============================================================================================

    function test_constructor_zero_integratorRegistry_reverts() public {
        TldRegistrarControllerV2.Init memory init = TldRegistrarControllerV2.Init({
            admin: admin,
            genesisAdmin: genesis,
            pauser: pauser,
            registrar: address(v2.registrar),
            ens: address(registry),
            oracle: address(oracle),
            resolver: address(resolver),
            reverseRegistrar: address(reverse),
            directory: address(directory),
            treasury: treasury,
            integratorRegistry: address(0),
            minCommitmentAge: MIN_AGE,
            maxCommitmentAge: MAX_AGE,
            tld: "zeroint"
        });
        vm.expectRevert(TldRegistrarControllerV2.ZeroAddress.selector);
        new TldRegistrarControllerV2(init);
    }

    function test_views_integratorRegistry() public view {
        assertEq(address(v2.controller.integratorRegistry()), address(integratorRegistry));
    }

    // =============================================================================================
    // Regression parity — plain register()/registerWithProof() are byte-for-byte V1
    // =============================================================================================

    function test_register_parity_v1_vs_v2_identical_price_treasury_and_referrer() public {
        _genesis(arc, new string[](0), bytes32(0));
        _sealV2(v2);

        ITldRegistrarController.Registration memory r1 =
            _registration("alice", alice, keccak256("s"), address(0), false);
        uint256 priceV1 = _register(arc, r1, alice);
        uint256 treasuryAfterV1 = treasury.balance;
        assertEq(treasuryAfterV1, priceV1);

        ITldRegistrarController.Registration memory r2 =
            _registration("alice", alice, keccak256("s"), address(0), false);
        uint256 priceV2 = _registerV2(v2, r2, alice);

        assertEq(priceV2, priceV1, "same tiers, same label length => same quote");
        assertEq(treasury.balance - treasuryAfterV1, priceV2, "v2 treasury delta == price, identical to v1");
        assertEq(v2.registrar.ownerOf(uint256(_labelhash("alice"))), alice);
        assertEq(v2.registrar.nameExpires(uint256(_labelhash("alice"))), type(uint64).max);
        assertEq(v2.controller.paidWei(_labelhash("alice")), priceV2);
    }

    function test_registerWithProof_parity_v1_vs_v2() public {
        _genesis(arc, new string[](0), bytes32(0));
        _sealV2(v2);
        bytes32[] memory emptyProof = new bytes32[](0);

        ITldRegistrarController.Registration memory r1 = _registration("bob", bob, keccak256("s"), address(0), false);
        bytes32 commitment1 = arc.controller.makeCommitment(r1);
        vm.prank(bob);
        arc.controller.commit(commitment1);
        vm.warp(block.timestamp + MIN_AGE);
        uint256 priceV1 = arc.controller.quote("bob");
        vm.deal(bob, priceV1);
        vm.prank(bob);
        arc.controller.registerWithProof{value: priceV1}(r1, priceV1, emptyProof);
        uint256 treasuryAfterV1 = treasury.balance;

        ITldRegistrarController.Registration memory r2 = _registration("bob", bob, keccak256("s"), address(0), false);
        bytes32 commitment2 = v2.controller.makeCommitment(r2);
        vm.prank(bob);
        v2.controller.commit(commitment2);
        vm.warp(block.timestamp + MIN_AGE);
        uint256 priceV2 = v2.controller.quote("bob");
        vm.deal(bob, priceV2);
        vm.prank(bob);
        v2.controller.registerWithProof{value: priceV2}(r2, priceV2, emptyProof);

        assertEq(priceV2, priceV1);
        assertEq(treasury.balance - treasuryAfterV1, priceV2);
        assertEq(v2.registrar.ownerOf(uint256(_labelhash("bob"))), bob);
    }

    // =============================================================================================
    // Fail-closed on a bad integrator: whole call reverts, nothing mutates
    // =============================================================================================

    function test_registerWithIntegrator_notIntegrator_reverts_and_state_untouched() public {
        _sealV2(v2);
        ITldRegistrarController.Registration memory r =
            _registration("badint", alice, keccak256("s"), address(0), false);
        bytes32 commitment = _commitAndWaitV2(v2, r, alice);
        uint256 price = v2.controller.quote("badint");
        vm.deal(alice, price);

        assertTrue(v2.controller.available("badint"));
        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.NotIntegrator.selector, notIntegrator));
        vm.prank(alice);
        v2.controller.registerWithIntegrator{value: price}(r, price, notIntegrator);

        assertEq(v2.controller.commitments(commitment), block.timestamp - MIN_AGE, "commitment survives");
        assertTrue(v2.controller.available("badint"));
        assertEq(treasury.balance, 0);

        // the same commitment still reveals successfully afterwards
        vm.prank(alice);
        v2.controller.register{value: price}(r, price);
        assertEq(v2.registrar.ownerOf(uint256(_labelhash("badint"))), alice);
    }

    function test_registerWithProofAndIntegrator_notIntegrator_reverts_and_state_untouched() public {
        _sealV2(v2);
        bytes32[] memory emptyProof = new bytes32[](0);
        ITldRegistrarController.Registration memory r =
            _registration("badint2", alice, keccak256("s"), address(0), false);
        bytes32 commitment = _commitAndWaitV2(v2, r, alice);
        uint256 price = v2.controller.quote("badint2");
        vm.deal(alice, price);

        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.NotIntegrator.selector, notIntegrator));
        vm.prank(alice);
        v2.controller.registerWithProofAndIntegrator{value: price}(r, price, emptyProof, notIntegrator);

        assertEq(v2.controller.commitments(commitment), block.timestamp - MIN_AGE);
        assertTrue(v2.controller.available("badint2"));
    }

    function test_no_self_registration_no_matter_the_entry_point() public {
        _sealV2(v2);
        ITldRegistrarController.Registration memory r =
            _registration("selfreg", attacker, keccak256("s"), address(0), false);
        bytes32 commitment = _commitAndWaitV2(v2, r, attacker);
        uint256 price = v2.controller.quote("selfreg");
        vm.deal(attacker, price);

        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.NotIntegrator.selector, attacker));
        vm.prank(attacker);
        v2.controller.registerWithIntegrator{value: price}(r, price, attacker);

        assertEq(v2.controller.commitments(commitment), block.timestamp - MIN_AGE);
        assertFalse(integratorRegistry.isIntegrator(attacker));
        assertFalse(v2.controller.hasRole(v2.controller.DEFAULT_ADMIN_ROLE(), attacker));
    }

    // =============================================================================================
    // Zero-address integrator explicitly refused
    // =============================================================================================

    function test_registerWithIntegrator_zeroAddress_reverts_IntegratorRequired() public {
        _sealV2(v2);
        ITldRegistrarController.Registration memory r = _registration("zero1", alice, keccak256("s"), address(0), false);
        _commitAndWaitV2(v2, r, alice);
        uint256 price = v2.controller.quote("zero1");
        vm.deal(alice, price);
        vm.expectRevert(ITldRegistrarControllerV2.IntegratorRequired.selector);
        vm.prank(alice);
        v2.controller.registerWithIntegrator{value: price}(r, price, address(0));
    }

    function test_registerWithProofAndIntegrator_zeroAddress_reverts_IntegratorRequired() public {
        _sealV2(v2);
        bytes32[] memory emptyProof = new bytes32[](0);
        ITldRegistrarController.Registration memory r = _registration("zero2", alice, keccak256("s"), address(0), false);
        _commitAndWaitV2(v2, r, alice);
        uint256 price = v2.controller.quote("zero2");
        vm.deal(alice, price);
        vm.expectRevert(ITldRegistrarControllerV2.IntegratorRequired.selector);
        vm.prank(alice);
        v2.controller.registerWithProofAndIntegrator{value: price}(r, price, emptyProof, address(0));
    }

    // =============================================================================================
    // Happy path: split bookkeeping + referrer field
    // =============================================================================================

    function test_registerWithIntegrator_happy_path_splits_referrer_and_withdraws() public {
        _sealV2(v2);
        ITldRegistrarController.Registration memory r =
            _registration("splitme", alice, keccak256("s"), address(0), false);
        _commitAndWaitV2(v2, r, alice);
        uint256 price = v2.controller.quote("splitme");
        vm.deal(alice, price);
        uint256 expectedShare = price * 2000 / 10_000;
        bytes32 expectedReferrer = bytes32(uint256(uint160(integrator)));

        vm.expectEmit(true, true, false, true);
        emit ITldRegistrarController.NameRegistered(
            "splitme", _labelhash("splitme"), alice, price, 0, type(uint64).max, expectedReferrer
        );
        vm.prank(alice);
        v2.controller.registerWithIntegrator{value: price}(r, price, integrator);

        assertEq(v2.controller.withdrawable(integrator), expectedShare);
        assertEq(treasury.balance, price - expectedShare);

        uint256 before = integrator.balance;
        vm.prank(integrator);
        v2.controller.withdraw();
        assertEq(integrator.balance, before + expectedShare);

        vm.expectRevert(ITldRegistrarController.NothingToWithdraw.selector);
        vm.prank(integrator);
        v2.controller.withdraw();
    }

    /// @dev `integrator == address(0)` (plain `register`) still emits `referrer == bytes32(0)`,
    ///      byte-identical to V1.
    function test_referrer_is_zero_for_plain_register() public {
        _sealV2(v2);
        ITldRegistrarController.Registration memory r = _registration("noref", alice, keccak256("s"), address(0), false);
        _commitAndWaitV2(v2, r, alice);
        uint256 price = v2.controller.quote("noref");
        vm.deal(alice, price);

        vm.expectEmit(true, true, false, true);
        emit ITldRegistrarController.NameRegistered(
            "noref", _labelhash("noref"), alice, price, 0, type(uint64).max, bytes32(0)
        );
        vm.prank(alice);
        v2.controller.register{value: price}(r, price);
    }

    // =============================================================================================
    // Split invariant across the full [0, CAP_BPS] range + cap unreachable above it
    // =============================================================================================

    function testFuzz_split_invariant_full_rate_range(uint16 rateBps) public {
        rateBps = uint16(bound(uint256(rateBps), 0, CAP_BPS));
        vm.prank(admin);
        integratorRegistry.setIntegratorRate(integrator, rateBps);

        _sealV2(v2);
        ITldRegistrarController.Registration memory r =
            _registration("fuzzname", alice, keccak256("s"), address(0), false);
        _commitAndWaitV2(v2, r, alice);
        uint256 price = v2.controller.quote("fuzzname");
        vm.deal(alice, price);
        vm.prank(alice);
        v2.controller.registerWithIntegrator{value: price}(r, price, integrator);

        uint256 integratorShare = v2.controller.withdrawable(integrator);
        uint256 treasuryShare = treasury.balance;
        assertEq(integratorShare + treasuryShare, price, "no dust created or lost, any rate in [0, CAP_BPS]");
        assertEq(integratorShare, price * rateBps / 10_000);
        assertLe(integratorShare, price * CAP_BPS / 10_000, "never more than 40% no matter the rate");
    }

    function test_rate_above_cap_unreachable_at_the_registry() public {
        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.RateAboveCap.selector, 4001, CAP_BPS));
        vm.prank(admin);
        integratorRegistry.setIntegratorRate(integrator, 4001);

        vm.prank(admin);
        integratorRegistry.setIntegratorRate(integrator, CAP_BPS);
        _sealV2(v2);
        ITldRegistrarController.Registration memory r = _registration("atcap", alice, keccak256("s"), address(0), false);
        _commitAndWaitV2(v2, r, alice);
        uint256 price = v2.controller.quote("atcap");
        vm.deal(alice, price);
        vm.prank(alice);
        v2.controller.registerWithIntegrator{value: price}(r, price, integrator);
        assertEq(v2.controller.withdrawable(integrator), price * CAP_BPS / 10_000);
    }

    // =============================================================================================
    // No bypass: nothing on the controller's ABI can set/override a rate or the allow-list
    // =============================================================================================

    function test_no_rate_setter_reachable_on_controller() public {
        bytes memory callData = abi.encodeWithSignature("setIntegratorRate(address,uint16)", integrator, 4000);
        vm.prank(admin);
        (bool ok, bytes memory ret) = address(v2.controller).call(callData);
        assertFalse(ok);
        assertEq(bytes4(ret), ITldRegistrarController.ValueNotAccepted.selector, "no such function; hits fallback()");
        assertEq(integratorRegistry.rateOf(integrator), 2000);

        bytes memory setIntegratorCall = abi.encodeWithSignature("setIntegrator(address,bool)", attacker, true);
        vm.prank(admin);
        (ok, ret) = address(v2.controller).call(setIntegratorCall);
        assertFalse(ok);
        assertEq(bytes4(ret), ITldRegistrarController.ValueNotAccepted.selector);
        assertFalse(integratorRegistry.isIntegrator(attacker));
    }

    // =============================================================================================
    // Reentrancy: nonReentrant still guards every register* overload and withdraw()
    // =============================================================================================

    function test_reentrancy_blocked_on_register_via_malicious_treasury() public {
        MaliciousTreasury bad = new MaliciousTreasury();
        PairV2 memory badPair = _addTldV2WithTreasury("badtld", address(bad));
        bad.setTarget(address(badPair.controller));
        _sealV2(badPair);

        bad.setReentryCalldata(abi.encodeWithSignature("withdraw()"));

        ITldRegistrarController.Registration memory r =
            _registration("reentrytest", alice, keccak256("s"), address(0), false);
        _commitAndWaitV2(badPair, r, alice);
        uint256 price = badPair.controller.quote("reentrytest");
        vm.deal(alice, price);
        vm.prank(alice);
        badPair.controller.register{value: price}(r, price);

        assertTrue(bad.attempted());
        assertFalse(bad.reentrantCallOk());
        assertEq(bytes4(bad.reentrantReturnData()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(
            badPair.registrar.ownerOf(uint256(_labelhash("reentrytest"))), alice, "outer registration still succeeded"
        );
    }

    /// @dev Same fixture wiring as `_addTldV2` but with a caller-supplied treasury (the malicious mock),
    ///      whose own address is only known after it is deployed.
    function _addTldV2WithTreasury(string memory label, address treasury_) internal returns (PairV2 memory p) {
        bytes32 node = HandleNormalize.tldNode(label);
        TldRegistrar reg = new TldRegistrar(registry, node, label, address(metadata), address(this));
        TldRegistrarControllerV2 ctl = new TldRegistrarControllerV2(
            TldRegistrarControllerV2.Init({
                admin: admin,
                genesisAdmin: genesis,
                pauser: pauser,
                registrar: address(reg),
                ens: address(registry),
                oracle: address(oracle),
                resolver: address(resolver),
                reverseRegistrar: address(reverse),
                directory: address(directory),
                treasury: treasury_,
                integratorRegistry: address(integratorRegistry),
                minCommitmentAge: MIN_AGE,
                maxCommitmentAge: MAX_AGE,
                tld: label
            })
        );
        root.setSubnodeOwner(keccak256(bytes(label)), address(reg));
        reg.addController(address(ctl));
        reg.transferOwnership(admin);
        reverse.setController(address(ctl), true);

        vm.startPrank(admin);
        directory.add(node, label, address(reg), address(ctl), node);
        oracle.initNamespace(node, address(ctl), address(0), uint64(block.timestamp), _tldTiers(), _zeroTiers());
        vm.stopPrank();

        p = PairV2({registrar: reg, controller: ctl, node: node, label: label});
    }

    // =============================================================================================
    // Withdraw parity: an integrator's credit is just another withdrawable[] balance
    // =============================================================================================

    function test_integrator_double_withdraw_and_zero_balance_withdraw_revert() public {
        _sealV2(v2);
        ITldRegistrarController.Registration memory r = _registration("wd1", alice, keccak256("s"), address(0), false);
        _commitAndWaitV2(v2, r, alice);
        uint256 price = v2.controller.quote("wd1");
        vm.deal(alice, price);
        vm.prank(alice);
        v2.controller.registerWithIntegrator{value: price}(r, price, integrator);

        assertGt(v2.controller.withdrawable(integrator), 0);
        vm.prank(integrator);
        v2.controller.withdraw();
        assertEq(v2.controller.withdrawable(integrator), 0);

        vm.expectRevert(ITldRegistrarController.NothingToWithdraw.selector);
        vm.prank(integrator);
        v2.controller.withdraw();

        vm.expectRevert(ITldRegistrarController.NothingToWithdraw.selector);
        vm.prank(notIntegrator);
        v2.controller.withdraw();
    }

    // =============================================================================================
    // Genesis / pause / allowlist regression (unmodified inheritance, light coverage)
    // =============================================================================================

    function test_genesis_batch_and_seal_work_through_v2() public {
        string[] memory reservedLabels = new string[](1);
        reservedLabels[0] = "reserved1";
        vm.prank(genesis);
        v2.controller.registerReservedBatch(reservedLabels);
        assertEq(v2.controller.reservedCount(), 1);
        assertEq(v2.registrar.ownerOf(uint256(_labelhash("reserved1"))), treasury);

        // a second GENESIS_ROLE holder, granted BEFORE the seal (INV-7 forbids granting it after)
        vm.prank(admin);
        v2.controller.grantRole(ArcNSConstants.GENESIS_ROLE, bob);

        vm.prank(genesis);
        v2.controller.sealGenesis(bytes32(0));
        assertTrue(v2.controller.genesisSealed());
        assertFalse(v2.controller.hasRole(ArcNSConstants.GENESIS_ROLE, genesis));

        vm.expectRevert(ITldRegistrarController.GenesisAlreadySealed.selector);
        vm.prank(bob);
        v2.controller.sealGenesis(bytes32(0));
    }

    function test_pause_blocks_all_register_overloads_but_not_withdraw() public {
        _sealV2(v2);
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.deal(alice, 10 ether);

        vm.prank(pauser);
        v2.controller.pause();
        assertTrue(v2.controller.paused());

        ITldRegistrarController.Registration memory r = _registration("p1", alice, keccak256("s"), address(0), false);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        v2.controller.register{value: 1 ether}(r, 1 ether);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        v2.controller.registerWithProof{value: 1 ether}(r, 1 ether, emptyProof);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        v2.controller.registerWithIntegrator{value: 1 ether}(r, 1 ether, integrator);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        v2.controller.registerWithProofAndIntegrator{value: 1 ether}(r, 1 ether, emptyProof, integrator);

        vm.prank(admin);
        v2.controller.unpause();
        assertFalse(v2.controller.paused());
        uint256 price = _registerV2(v2, r, alice);
        assertEq(v2.registrar.ownerOf(uint256(_labelhash("p1"))), alice);
        assertGt(price, 0);
    }

    function test_allowlist_gate_applies_identically_to_integrator_overloads() public {
        _sealV2(v2);
        bytes32 root_ = keccak256("root");
        vm.prank(admin);
        v2.controller.setAllowlist(root_, uint64(block.timestamp + 1 days));

        ITldRegistrarController.Registration memory r =
            _registration("allow1", alice, keccak256("s"), address(0), false);
        bytes32 commitment = _commitAndWaitV2(v2, r, alice);
        uint256 price = v2.controller.quote("allow1");
        vm.deal(alice, price);
        vm.expectRevert(ITldRegistrarController.AllowlistRequired.selector);
        vm.prank(alice);
        v2.controller.registerWithIntegrator{value: price}(r, price, integrator);
        assertEq(v2.controller.commitments(commitment), block.timestamp - MIN_AGE);
    }
}
