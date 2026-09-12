// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {ArcNSDeployLib} from "../../script/lib/ArcNSDeployLib.sol";
import {ControllerV2CutoverLib} from "../../script/lib/ControllerV2CutoverLib.sol";
import {VerifyControllerV2} from "../../script/VerifyControllerV2.s.sol";
import {HandleController} from "../../src/handle/HandleController.sol";
import {HandleControllerV2} from "../../src/handle/HandleControllerV2.sol";
import {TldRegistrarController} from "../../src/tld/TldRegistrarController.sol";
import {TldRegistrarControllerV2} from "../../src/tld/TldRegistrarControllerV2.sol";
import {ITldRegistrarController} from "../../src/interfaces/ITldRegistrarController.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {IntegratorRegistry} from "../../src/parity/IntegratorRegistry.sol";

/// @notice WP #7772 corrected cutover, end to end, in-process against the REAL production wiring
///         (`ArcNSDeployLib` — the same library `script/DeployAll.s.sol` and `test/integration/
///         FullStack.t.sol` use: a real `TimelockController` holding `DEFAULT_ADMIN_ROLE` everywhere,
///         a real `ArcNSPriceOracle`/`ReverseRegistrar`/`TldDirectory`/`BaseRegistrar`, never mocks).
///         Proves the defect onchain-plan.md found (V1/V2 cannot be simultaneously live per namespace)
///         and proves `ControllerV2CutoverLib`'s atomic per-namespace `scheduleBatch` fixes it: after
///         ONE batch executes for a namespace, V2 can complete a real commit-reveal registration in
///         that namespace and V1 cannot — in the SAME test, no intermediate broken state observed.
contract ControllerV2CutoverTest is Test {
    uint256 internal constant DELAY = 1 hours;
    uint8 internal constant HUMAN = 0;
    address internal constant TREASURY = address(0x7EA5);
    address internal constant SAFE = address(0x5AFE); // Admin Safe stand-in: proposer == executor, exactly like MarketGrantTest/FullStackTest

    ArcNSDeployLib.Book internal b;
    ArcNSDeployLib.Params internal p;
    TimelockController internal timelock;
    IntegratorRegistry internal integratorRegistry;

    HandleControllerV2 internal hv2;
    TldRegistrarControllerV2 internal arcv2;
    TldRegistrarControllerV2 internal cirv2;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

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

        ArcNSDeployLib.Book memory bm = ArcNSDeployLib.deployShared(p);
        bm.tlds = new ArcNSDeployLib.Tld[](2);
        bm.tlds[0] = ArcNSDeployLib.addTld(bm, p, "arc");
        bm.tlds[1] = ArcNSDeployLib.addTld(bm, p, "circle");
        ArcNSDeployLib.handoff(bm, p);
        _store(bm);

        b.handleController.sealGenesis(keccak256("handle-root"));
        for (uint256 i = 0; i < 2; i++) {
            b.tlds[i].controller.sealGenesis(keccak256(bytes(b.tlds[i].label)));
        }

        integratorRegistry = new IntegratorRegistry(address(timelock));

        hv2 = new HandleControllerV2(
            HandleControllerV2.Init({
                admin: address(timelock),
                genesisAdmin: address(this),
                pauser: SAFE,
                registry: address(b.handles),
                oracle: address(b.oracle),
                treasury: TREASURY,
                integratorRegistry: address(integratorRegistry),
                minCommitmentAge: p.minCommitmentAge,
                maxCommitmentAge: p.maxCommitmentAge
            })
        );
        hv2.sealGenesis(keccak256("handle-root"));

        arcv2 = new TldRegistrarControllerV2(_tldV2Init("arc"));
        arcv2.sealGenesis(keccak256(bytes("arc")));
        cirv2 = new TldRegistrarControllerV2(_tldV2Init("circle"));
        cirv2.sealGenesis(keccak256(bytes("circle")));

        vm.deal(alice, 1_000_000e18);
        vm.deal(bob, 1_000_000e18);
    }

    function _tldV2Init(string memory label) internal view returns (TldRegistrarControllerV2.Init memory) {
        ArcNSDeployLib.Tld memory t = label2tld(label);
        return TldRegistrarControllerV2.Init({
            admin: address(timelock),
            genesisAdmin: address(this),
            pauser: SAFE,
            registrar: address(t.registrar),
            ens: address(b.registry),
            oracle: address(b.oracle),
            resolver: address(b.resolver),
            reverseRegistrar: address(b.reverseRegistrar),
            directory: address(b.directory),
            treasury: TREASURY,
            integratorRegistry: address(integratorRegistry),
            minCommitmentAge: p.minCommitmentAge,
            maxCommitmentAge: p.maxCommitmentAge,
            tld: label
        });
    }

    function label2tld(string memory label) internal view returns (ArcNSDeployLib.Tld memory) {
        for (uint256 i = 0; i < b.tlds.length; i++) {
            if (keccak256(bytes(b.tlds[i].label)) == keccak256(bytes(label))) return b.tlds[i];
        }
        revert("label not found");
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

    // ---------------------------------------------------------------------------------------------
    // Timelock plumbing (byte-for-byte the MarketGrantTest pattern)
    // ---------------------------------------------------------------------------------------------

    function _scheduleAsSafe(ControllerV2CutoverLib.BatchPayload memory batch) internal {
        vm.prank(SAFE);
        (bool ok,) = address(timelock).call(batch.scheduleCalldata);
        assertTrue(ok, string.concat("schedule failed: ", batch.label));
    }

    function _executeAsSafe(ControllerV2CutoverLib.BatchPayload memory batch) internal returns (bool ok) {
        vm.prank(SAFE);
        (ok,) = address(timelock).call(batch.executeCalldata);
    }

    function _cutover(ControllerV2CutoverLib.BatchPayload memory batch) internal {
        _scheduleAsSafe(batch);
        assertTrue(
            timelock.getOperationState(batch.operationId) == TimelockController.OperationState.Waiting,
            string.concat(batch.label, ": not Waiting after schedule")
        );
        vm.warp(block.timestamp + DELAY);
        assertTrue(_executeAsSafe(batch), string.concat(batch.label, ": execute failed"));
        assertTrue(
            timelock.getOperationState(batch.operationId) == TimelockController.OperationState.Done,
            string.concat(batch.label, ": not Done after execute")
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Commit/reveal helpers
    // ---------------------------------------------------------------------------------------------

    function _registerHandle(HandleController ctl, string memory name, address owner, bytes32 secret) internal {
        bytes32 c = ctl.makeCommitment(name, owner, secret, HUMAN);
        ctl.commit(c);
        vm.warp(block.timestamp + p.minCommitmentAge);
        uint256 price = ctl.quote(name);
        vm.prank(owner);
        ctl.register{value: price}(name, owner, secret, HUMAN, price);
    }

    function _registerHandleV2(HandleControllerV2 ctl, string memory name, address owner, bytes32 secret) internal {
        bytes32 c = ctl.makeCommitment(name, owner, secret, HUMAN);
        ctl.commit(c);
        vm.warp(block.timestamp + p.minCommitmentAge);
        uint256 price = ctl.quote(name);
        vm.prank(owner);
        ctl.register{value: price}(name, owner, secret, HUMAN, price);
    }

    function _tldRegistration(string memory label, address owner, bytes32 secret)
        internal
        pure
        returns (ITldRegistrarController.Registration memory r)
    {
        r.label = label;
        r.owner = owner;
        r.secret = secret;
        r.resolver = address(0);
        r.data = new bytes[](0);
        r.reverseRecord = false;
    }

    function _registerTld(TldRegistrarController ctl, string memory label, address owner, bytes32 secret) internal {
        ITldRegistrarController.Registration memory r = _tldRegistration(label, owner, secret);
        bytes32 c = ctl.makeCommitment(r);
        ctl.commit(c);
        vm.warp(block.timestamp + p.minCommitmentAge);
        uint256 price = ctl.quote(label);
        vm.prank(owner);
        ctl.register{value: price}(r, price);
    }

    function _registerTldV2(TldRegistrarControllerV2 ctl, string memory label, address owner, bytes32 secret) internal {
        ITldRegistrarController.Registration memory r = _tldRegistration(label, owner, secret);
        bytes32 c = ctl.makeCommitment(r);
        ctl.commit(c);
        vm.warp(block.timestamp + p.minCommitmentAge);
        uint256 price = ctl.quote(label);
        vm.prank(owner);
        ctl.register{value: price}(r, price);
    }

    // ---------------------------------------------------------------------------------------------
    // 1. Before ANY cutover batch: V1 registers fine, V2 reverts on the oracle gate (proves the defect
    //    onchain-plan.md found is real, not hypothetical, in this exact fixture)
    // ---------------------------------------------------------------------------------------------

    /// @dev Two distinct pre-cutover failure modes, both real: (1) V2 with NO grants at all reverts at
    ///      the registry's own access-control check, before it ever reaches the oracle — V1 meanwhile
    ///      works normally. (2) Isolating the EXACT old-runbook defect (onchain-plan.md §4.2-1): grant
    ///      ONLY `REGISTRAR_ROLE` to V2 (what the old runbook's step 2a alone did) WITHOUT repointing
    ///      the oracle — V2 still reverts, but now specifically at `oracle.recordSale`
    ///      (`NotNamespaceController`), proving the oracle gate — not the registry role — is the real
    ///      authority check the old runbook missed.
    function test_beforeCutover_V1_works_V2_blockedFirstByMissingRole_thenByOracle() public {
        _registerHandle(b.handleController, "alpha", alice, keccak256("s-alpha"));
        assertFalse(b.handleController.available("alpha"));

        // (1) V2 with zero grants: reverts at HandleRegistry's own access control.
        bytes32 c = hv2.makeCommitment("beta", bob, keccak256("s-beta"), HUMAN);
        hv2.commit(c);
        vm.warp(block.timestamp + p.minCommitmentAge);
        uint256 price = hv2.quote("beta");
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(hv2), ArcNSConstants.REGISTRAR_ROLE
            )
        );
        hv2.register{value: price}("beta", bob, keccak256("s-beta"), HUMAN, price);

        // (2) Isolate the old runbook's exact defect: grant JUST REGISTRAR_ROLE (step 2a), leave the
        // oracle pointed at V1. Registry minting now succeeds internally, but `oracle.recordSale`
        // reverts `NotNamespaceController` — the whole call still reverts atomically (name NOT minted).
        vm.prank(address(timelock));
        b.handles.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(hv2));

        bytes32 c2 = hv2.makeCommitment("beta2", bob, keccak256("s-beta2"), HUMAN);
        hv2.commit(c2);
        vm.warp(block.timestamp + p.minCommitmentAge);
        uint256 price2 = hv2.quote("beta2");
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArcNSPriceOracle.NotNamespaceController.selector, ArcNSConstants.HANDLE_ROOT, address(hv2)
            )
        );
        hv2.register{value: price2}("beta2", bob, keccak256("s-beta2"), HUMAN, price2);
        assertTrue(hv2.available("beta2"), "reverted atomically: not minted despite holding REGISTRAR_ROLE");
    }

    // ---------------------------------------------------------------------------------------------
    // 2. Batch H: after ONE scheduleBatch/executeBatch, V2 registers a real name and V1 is dead —
    //    the whole register() call reverts (proves the "whole tx reverts, no partial mint survives"
    //    claim in ControllerV2CutoverLib's NatSpec, not just "the oracle call reverts").
    // ---------------------------------------------------------------------------------------------

    function test_batchH_atomicCutover_V2liveV1dead() public {
        address tokenizer = b.oracle.namespaceInfo(ArcNSConstants.HANDLE_ROOT).tokenizer;
        assertEq(tokenizer, address(b.handles), "HANDLE_ROOT tokenizer is HandleRegistry pre-cutover");

        ControllerV2CutoverLib.BatchPayload memory batchH = ControllerV2CutoverLib.buildHandleBatch(
            address(b.handles), address(b.oracle), address(hv2), tokenizer, DELAY
        );
        _cutover(batchH);

        assertTrue(b.handles.hasRole(ArcNSConstants.REGISTRAR_ROLE, address(hv2)), "V2 has REGISTRAR_ROLE");
        assertEq(b.oracle.namespaceInfo(ArcNSConstants.HANDLE_ROOT).controller, address(hv2), "oracle points at V2");
        // hygiene not run: V1 still nominally holds the role, but is functionally dead (checked next).
        assertTrue(
            b.handles.hasRole(ArcNSConstants.REGISTRAR_ROLE, address(b.handleController)),
            "V1 role NOT yet revoked (hygiene is separate)"
        );

        // V2 registration succeeds end to end.
        _registerHandleV2(hv2, "gamma", alice, keccak256("s-gamma"));
        assertFalse(b.handleController.available("gamma"));
        assertEq(b.handles.ownerOf(ArcNSConstants.handleTokenId("gamma")), alice);

        // V1 registration of a DIFFERENT name now reverts the whole call, atomically — the token is
        // never minted (proves "no partial state survives", not merely "the tx as a whole reverts").
        assertTrue(b.handleController.available("delta"));
        bytes32 c = b.handleController.makeCommitment("delta", bob, keccak256("s-delta"), HUMAN);
        b.handleController.commit(c);
        vm.warp(block.timestamp + p.minCommitmentAge);
        uint256 price = b.handleController.quote("delta");
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArcNSPriceOracle.NotNamespaceController.selector,
                ArcNSConstants.HANDLE_ROOT,
                address(b.handleController)
            )
        );
        b.handleController.register{value: price}("delta", bob, keccak256("s-delta"), HUMAN, price);
        assertTrue(b.handleController.available("delta"), "V1 register() reverted atomically: name NOT minted");
    }

    // ---------------------------------------------------------------------------------------------
    // 3. Batch <tld>: proves the reverse-registrar grant (onchain-plan.md §4.2-2, the one the OLD
    //    runbook omitted entirely) — a V2 registration WITH reverseRecord=true only works after the
    //    batch, and the directory + oracle checks the same way batch H does.
    // ---------------------------------------------------------------------------------------------

    function test_batchArc_atomicCutover_reverseRegistrarGrant_V2liveV1dead() public {
        ArcNSDeployLib.Tld memory arcTld = label2tld("arc");

        // Isolate the EXACT defect onchain-plan.md §4.2-2 found: reproduce what the OLD (defective)
        // runbook granted — BaseRegistrar controller + oracle controller, but NOT ReverseRegistrar —
        // by pranking the timelock directly (not the atomic batch), then show a `reverseRecord=true`
        // registration reverts specifically on the missing ReverseRegistrar authorization, even though
        // V2 otherwise has full minting authority.
        vm.startPrank(address(timelock));
        arcTld.registrar.addController(address(arcv2));
        b.oracle.setController(arcTld.node, address(arcv2), address(0));
        vm.stopPrank();

        ITldRegistrarController.Registration memory rBefore = _tldRegistration("early", alice, keccak256("s-early"));
        rBefore.resolver = address(b.resolver);
        rBefore.reverseRecord = true;
        bytes32 cBefore = arcv2.makeCommitment(rBefore);
        arcv2.commit(cBefore);
        vm.warp(block.timestamp + p.minCommitmentAge);
        uint256 priceBefore = arcv2.quote("early");
        vm.prank(alice);
        vm.expectRevert(); // ReverseRegistrar.authorised: caller is not a controller (the omitted grant)
        arcv2.register{value: priceBefore}(rBefore, priceBefore);
        assertTrue(arcTld.registrar.available(uint256(keccak256("early"))), "reverted atomically: not minted");

        // The REAL atomic batch (includes the ReverseRegistrar grant this time) — re-running
        // addController/oracle.setController with the same values is idempotent, so this is exactly
        // what the corrected runbook sends as ONE operation, not a re-run of the isolation above.
        ControllerV2CutoverLib.BatchPayload memory batchArc = ControllerV2CutoverLib.buildTldBatch(
            "arc",
            address(arcTld.registrar),
            address(b.reverseRegistrar),
            address(b.directory),
            address(b.oracle),
            arcTld.node,
            address(arcv2),
            DELAY
        );
        _cutover(batchArc);

        assertTrue(arcTld.registrar.controllers(address(arcv2)), "BaseRegistrar: V2 added");
        assertTrue(b.reverseRegistrar.controllers(address(arcv2)), "ReverseRegistrar: V2 authorised");
        assertEq(b.directory.controllerOf(arcTld.node), address(arcv2), "TldDirectory: controllerOf == V2");
        assertEq(b.oracle.namespaceInfo(arcTld.node).controller, address(arcv2), "oracle: controller == V2");

        // Now the SAME reverseRecord=true registration succeeds end to end (new name — "early"'s
        // commitment is now stale, use a fresh one).
        ITldRegistrarController.Registration memory rAfter = _tldRegistration("later", alice, keccak256("s-later"));
        rAfter.resolver = address(b.resolver);
        rAfter.reverseRecord = true;
        bytes32 cAfter = arcv2.makeCommitment(rAfter);
        arcv2.commit(cAfter);
        vm.warp(block.timestamp + p.minCommitmentAge);
        uint256 priceAfter = arcv2.quote("later");
        vm.prank(alice);
        arcv2.register{value: priceAfter}(rAfter, priceAfter);
        assertEq(arcTld.registrar.ownerOf(uint256(keccak256("later"))), alice);

        // V1 .arc registration now reverts atomically (oracle gate), same as batch H's proof.
        assertTrue(arcTld.controller.available("stranded"));
        bytes32 cV1 = arcTld.controller.makeCommitment(_tldRegistration("stranded", bob, keccak256("s-stranded")));
        arcTld.controller.commit(cV1);
        vm.warp(block.timestamp + p.minCommitmentAge);
        uint256 priceV1 = arcTld.controller.quote("stranded");
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArcNSPriceOracle.NotNamespaceController.selector, arcTld.node, address(arcTld.controller)
            )
        );
        arcTld.controller.register{value: priceV1}(_tldRegistration("stranded", bob, keccak256("s-stranded")), priceV1);
        assertTrue(arcTld.controller.available("stranded"), "V1 register() reverted atomically: name NOT minted");
    }

    // ---------------------------------------------------------------------------------------------
    // 4. VerifyControllerV2: exact FAIL-line transitions across the H and arc batches (the reporting
    //    tool must reflect reality at every step, not just the final state).
    // ---------------------------------------------------------------------------------------------

    function test_verifyControllerV2_transitionsCorrectly_acrossBatches() public {
        ArcNSDeployLib.Tld memory arcTld = label2tld("arc");
        ArcNSDeployLib.Tld memory cirTld = label2tld("circle");
        VerifyControllerV2 v = new VerifyControllerV2();

        VerifyControllerV2.Inputs memory i;
        i.handleRegistry = address(b.handles);
        i.handleControllerV1 = address(b.handleController);
        i.handleControllerV2 = address(hv2);
        i.oracle = address(b.oracle);
        i.reverseRegistrar = address(b.reverseRegistrar);
        i.directory = address(b.directory);
        i.tldLabels = new string[](2);
        i.tldLabels[0] = "arc";
        i.tldLabels[1] = "circle";
        i.registrars = new address[](2);
        i.registrars[0] = address(arcTld.registrar);
        i.registrars[1] = address(cirTld.registrar);
        i.controllersV1 = new address[](2);
        i.controllersV1[0] = address(arcTld.controller);
        i.controllersV1[1] = address(cirTld.controller);
        i.controllersV2 = new address[](2);
        i.controllersV2[0] = address(arcv2);
        i.controllersV2[1] = address(cirv2);
        i.tldNodes = new bytes32[](2);
        i.tldNodes[0] = arcTld.node;
        i.tldNodes[1] = cirTld.node;

        // Before any cutover: every "V2 wired" check fails AND every "V1 revoked" check fails (V1
        // still holds every flag) — matches onchain-plan.md §4.1's live pre-cutover finding, extended
        // by this branch's new oracle + reverse-registrar checks. Handle: 2 wired (role, oracle) + 1
        // hygiene = 3. Each TLD: 4 wired (registrar, reverse, directory, oracle) + 1 hygiene = 5. Total
        // 3 + 5 + 5 = 13.
        assertFalse(v.verify(i));
        assertEq(v.failureCount(), 13, "pre-cutover failure count");

        // Batch H only.
        address tokenizer = b.oracle.namespaceInfo(ArcNSConstants.HANDLE_ROOT).tokenizer;
        _cutover(
            ControllerV2CutoverLib.buildHandleBatch(
                address(b.handles), address(b.oracle), address(hv2), tokenizer, DELAY
            )
        );
        assertFalse(v.verify(i), "still failing: arc/circle untouched, and handle hygiene not run");

        // Batch arc + circle.
        _cutover(
            ControllerV2CutoverLib.buildTldBatch(
                "arc",
                address(arcTld.registrar),
                address(b.reverseRegistrar),
                address(b.directory),
                address(b.oracle),
                arcTld.node,
                address(arcv2),
                DELAY
            )
        );
        _cutover(
            ControllerV2CutoverLib.buildTldBatch(
                "circle",
                address(cirTld.registrar),
                address(b.reverseRegistrar),
                address(b.directory),
                address(b.oracle),
                cirTld.node,
                address(cirv2),
                DELAY
            )
        );

        // All three "V2 wired" halves now pass; only the three "V1 revoked" hygiene lines remain.
        assertFalse(v.verify(i));
        assertEq(v.failureCount(), 3, "only the 3 V1-revoked hygiene lines remain");

        // Hygiene: revoke V1 role + controller flags directly through the timelock (mirrors
        // GrantControllerV2's hygiene batch without re-deriving its calldata here).
        vm.prank(address(timelock));
        b.handles.revokeRole(ArcNSConstants.REGISTRAR_ROLE, address(b.handleController));
        vm.prank(address(timelock));
        arcTld.registrar.removeController(address(arcTld.controller));
        vm.prank(address(timelock));
        cirTld.registrar.removeController(address(cirTld.controller));

        assertTrue(v.verify(i), "ROLES_VERIFIED after hygiene");
        assertEq(v.failureCount(), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // 5. Pending-commitment gate (CEO decision Q1): commitmentIsPending mirrors the EXACT age window
    //    `_consumeCommitment` itself checks — ts==0 -> never pending; 0<age<maxAge -> pending
    //    (regardless of whether it has yet cleared minCommitmentAge — it WILL be revealable, just not
    //    yet); age>=maxAge -> not pending (permanently CommitmentTooOld regardless of this cutover).
    // ---------------------------------------------------------------------------------------------

    function test_commitmentIsPending_matchesRevealAgeWindow() public {
        VerifyControllerV2 v = new VerifyControllerV2();
        uint256 maxAge = p.maxCommitmentAge;

        assertFalse(v.commitmentIsPending(0, maxAge), "never committed => not pending");

        bytes32 secret = keccak256("gate-secret");
        bytes32 c = b.handleController.makeCommitment("gatetest", alice, secret, HUMAN);
        b.handleController.commit(c);
        uint256 committedAt = block.timestamp;

        // Too new to reveal yet, but still pending (will become revealable).
        assertTrue(v.commitmentIsPending(committedAt, maxAge), "just committed => pending");
        uint256 price = b.handleController.quote("gatetest");
        vm.prank(alice);
        vm.expectRevert(); // CommitmentTooNew
        b.handleController.register{value: price}("gatetest", alice, secret, HUMAN, price);

        // Past minCommitmentAge, before maxCommitmentAge: pending AND revealable — reveal it, which
        // clears `commitments[c]` to 0 (the happy path the runbook's gate is built around).
        vm.warp(committedAt + p.minCommitmentAge);
        assertTrue(v.commitmentIsPending(committedAt, maxAge));
        vm.prank(alice);
        b.handleController.register{value: price}("gatetest", alice, secret, HUMAN, price);
        assertEq(b.handleController.commitments(c), 0, "revealed: commitment cleared");
        assertFalse(v.commitmentIsPending(0, maxAge));

        // A SEPARATE commitment left un-revealed past maxCommitmentAge: pending flips to false (it can
        // never be revealed on V1 again, cutover or not — CommitmentTooOld), and a live reveal attempt
        // proves the same thing on-chain.
        bytes32 c2 = b.handleController.makeCommitment("gatetest2", bob, secret, HUMAN);
        b.handleController.commit(c2);
        uint256 committedAt2 = block.timestamp;
        vm.warp(committedAt2 + maxAge + 1);
        assertFalse(v.commitmentIsPending(committedAt2, maxAge), "expired => not pending");
        uint256 price2 = b.handleController.quote("gatetest2");
        vm.prank(bob);
        vm.expectRevert(); // CommitmentTooOld
        b.handleController.register{value: price2}("gatetest2", bob, secret, HUMAN, price2);
    }

    function test_checkPendingCommitments_liveGate_countsCorrectly() public {
        VerifyControllerV2 v = new VerifyControllerV2();
        bytes32 secret = keccak256("live-gate");
        bytes32 pendingHash = b.handleController.makeCommitment("livegate", alice, secret, HUMAN);
        b.handleController.commit(pendingHash);
        vm.warp(block.timestamp + p.minCommitmentAge);

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = pendingHash;
        assertEq(v.checkPendingCommitments(address(b.handleController), hashes, p.maxCommitmentAge), 1);

        // Reveal it: gate clears to 0.
        uint256 price = b.handleController.quote("livegate");
        vm.prank(alice);
        b.handleController.register{value: price}("livegate", alice, secret, HUMAN, price);
        assertEq(v.checkPendingCommitments(address(b.handleController), hashes, p.maxCommitmentAge), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // 6. Library-level payload correctness (mirrors MarketGrant.t.sol's hand-computed-calldata style)
    // ---------------------------------------------------------------------------------------------

    function test_lib_buildHandleBatch_matchesHandComputedCalldataAndOpId() public view {
        address tokenizer = address(b.handles);
        ControllerV2CutoverLib.BatchPayload memory batch = ControllerV2CutoverLib.buildHandleBatch(
            address(b.handles), address(b.oracle), address(hv2), tokenizer, DELAY
        );

        assertEq(batch.targets.length, 2);
        assertEq(batch.targets[0], address(b.handles));
        assertEq(
            batch.data[0],
            abi.encodeWithSelector(bytes4(0x2f2ff15d), ArcNSConstants.REGISTRAR_ROLE, address(hv2)),
            "grantRole calldata"
        );
        assertEq(batch.targets[1], address(b.oracle));
        assertEq(
            batch.data[1],
            abi.encodeWithSelector(
                bytes4(keccak256("setController(bytes32,address,address)")),
                ArcNSConstants.HANDLE_ROOT,
                address(hv2),
                tokenizer
            ),
            "oracle setController calldata"
        );
        assertEq(batch.predecessor, bytes32(0));
        assertEq(batch.salt, keccak256(abi.encodePacked("arcns:wp-7772:cutover:", "handles", ":", address(hv2))));
        assertEq(
            batch.operationId,
            keccak256(abi.encode(batch.targets, batch.values, batch.data, batch.predecessor, batch.salt)),
            "op id (hand)"
        );
        assertEq(
            batch.operationId,
            timelock.hashOperationBatch(batch.targets, batch.values, batch.data, batch.predecessor, batch.salt),
            "op id (chain)"
        );
    }

    function test_lib_rejectsZeroInputs() public {
        vm.expectRevert(bytes("ControllerV2CutoverLib: zero addr"));
        this.buildHandleExt(address(0), address(b.oracle), address(hv2), address(b.handles), DELAY);
        vm.expectRevert(bytes("ControllerV2CutoverLib: zero delay"));
        this.buildHandleExt(address(b.handles), address(b.oracle), address(hv2), address(b.handles), 0);

        vm.expectRevert(bytes("ControllerV2CutoverLib: zero node"));
        this.buildTldExt("arc", address(0x1), address(0x2), address(0x3), address(0x4), bytes32(0), address(0x5), DELAY);
    }

    function buildHandleExt(address reg, address oracle, address v2, address tok, uint256 delay)
        external
        pure
        returns (ControllerV2CutoverLib.BatchPayload memory)
    {
        return ControllerV2CutoverLib.buildHandleBatch(reg, oracle, v2, tok, delay);
    }

    function buildTldExt(
        string memory label,
        address registrar,
        address reverseRegistrar,
        address directory,
        address oracle,
        bytes32 node,
        address v2,
        uint256 delay
    ) external pure returns (ControllerV2CutoverLib.BatchPayload memory) {
        return ControllerV2CutoverLib.buildTldBatch(
            label, registrar, reverseRegistrar, directory, oracle, node, v2, delay
        );
    }

    function test_timelock_deployerCannotScheduleOrExecute() public {
        address tokenizer = address(b.handles);
        ControllerV2CutoverLib.BatchPayload memory batch = ControllerV2CutoverLib.buildHandleBatch(
            address(b.handles), address(b.oracle), address(hv2), tokenizer, DELAY
        );
        (bool ok,) = address(timelock).call(batch.scheduleCalldata); // msg.sender = this test contract, not SAFE
        assertFalse(ok, "only the Safe (proposer) may schedule");
    }

    function test_timelock_executeBeforeDelayReverts() public {
        address tokenizer = address(b.handles);
        ControllerV2CutoverLib.BatchPayload memory batch = ControllerV2CutoverLib.buildHandleBatch(
            address(b.handles), address(b.oracle), address(hv2), tokenizer, DELAY
        );
        _scheduleAsSafe(batch);
        vm.warp(block.timestamp + DELAY - 1);
        assertFalse(_executeAsSafe(batch), "execute before minDelay must fail");
        assertFalse(b.handles.hasRole(ArcNSConstants.REGISTRAR_ROLE, address(hv2)));
    }
}
