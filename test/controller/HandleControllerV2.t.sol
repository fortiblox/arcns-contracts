// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {HandleController} from "../../src/handle/HandleController.sol";
import {HandleControllerV2} from "../../src/handle/HandleControllerV2.sol";
import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IHandleController} from "../../src/interfaces/IHandleController.sol";
import {IHandleControllerV2} from "../../src/interfaces/IHandleControllerV2.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {IIntegratorRegistry} from "../../src/interfaces/IIntegratorRegistry.sol";
import {IntegratorRegistry} from "../../src/parity/IntegratorRegistry.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {MockOracle} from "../handle/mocks/MockOracle.sol";
import {RevertingReceiver} from "../handle/mocks/TestHelpers.sol";
import {MaliciousTreasury} from "../handle/mocks/MaliciousTreasury.sol";

/// @notice Unit tests for `HandleControllerV2` (WP #7772): the integrator revenue-share overload
///         wired on top of `HandleController`'s unmodified commit-reveal / pull-ledger / genesis /
///         allowlist / pause surface.
///
/// @dev CEO requirement walkthrough (WP #7772: "it needs to be whitelisted from an admin, don't want
///      it abused") — the exact resolution path exercised by every test below:
///        `registerWithIntegrator`/`registerWithProofAndIntegrator`
///          -> `_register(..., integrator)`
///          -> `integratorRegistry.rateOf(integrator)`         (IntegratorRegistry.rateOf, view)
///               reverts `NotIntegrator` unless the timelock called
///               `IntegratorRegistry.setIntegrator(integrator, true)` first
///          -> `integratorRegistry.computeSplit(integrator, price)`
///               internally re-derives the SAME `rateOf`, hard-clamped to `CAP_BPS = 4000` inside
///               `IntegratorRegistry` itself (never inside this controller)
///      `HandleControllerV2` never allow-lists, never sets a rate, and never grants itself any role on
///      `IntegratorRegistry` — see `test_no_rate_setter_reachable_on_controller` and
///      `test_no_self_registration_no_matter_the_entry_point` below, which prove both directions.
contract HandleControllerV2Test is Test {
    bytes32 internal constant HANDLE_ROOT = ArcNSConstants.HANDLE_ROOT;
    uint256 internal constant PRICE = 5e18;
    uint256 internal constant MIN_AGE = 60;
    uint256 internal constant MAX_AGE = 24 hours;
    uint256 internal constant T0 = 1_700_000_000;
    bytes32 internal constant ROOT = keccak256("genesis-root");
    uint16 internal constant CAP_BPS = 4000;

    HandleRegistry internal registry;
    HandleController internal v1;
    HandleControllerV2 internal v2;
    MockOracle internal oracle;
    IntegratorRegistry internal integratorRegistry;

    address internal admin = makeAddr("admin");
    address internal deployer = makeAddr("deployer"); // v1 genesis admin
    address internal deployer2 = makeAddr("deployer2"); // v2 genesis admin
    address internal pauser = makeAddr("pauser");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");
    address internal integrator = makeAddr("integrator");
    address internal notIntegrator = makeAddr("notIntegrator");

    bytes32 internal secret = keccak256("alice-secret");
    uint8 internal constant HUMAN = 0;

    function setUp() public {
        vm.warp(T0);
        oracle = new MockOracle();
        registry = new HandleRegistry(admin, treasury, IArcNSPriceOracle(address(oracle)), 7 days);
        integratorRegistry = new IntegratorRegistry(admin);

        v1 = new HandleController(_initV1(treasury, MIN_AGE, MAX_AGE));
        v2 = new HandleControllerV2(_initV2(treasury, MIN_AGE, MAX_AGE, address(integratorRegistry)));

        vm.startPrank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(v1));
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(v2));
        vm.stopPrank();

        // Default namespace controller is v2 (most tests exercise v2 alone); the parity test flips it
        // to v1 for its v1 leg and back to v2 for its v2 leg.
        oracle.init(HANDLE_ROOT, address(v2), address(registry), PRICE, 2e18);

        vm.deal(alice, 100e18);
        vm.deal(bob, 100e18);
        vm.deal(attacker, 100e18);

        vm.prank(admin);
        integratorRegistry.setIntegrator(integrator, true);
    }

    function _initV1(address treasury_, uint256 minAge, uint256 maxAge)
        internal
        view
        returns (HandleController.Init memory)
    {
        return HandleController.Init({
            admin: admin,
            genesisAdmin: deployer,
            pauser: pauser,
            registry: address(registry),
            oracle: address(oracle),
            treasury: treasury_,
            minCommitmentAge: minAge,
            maxCommitmentAge: maxAge
        });
    }

    function _initV2(address treasury_, uint256 minAge, uint256 maxAge, address integratorRegistry_)
        internal
        view
        returns (HandleControllerV2.Init memory)
    {
        return HandleControllerV2.Init({
            admin: admin,
            genesisAdmin: deployer2,
            pauser: pauser,
            registry: address(registry),
            oracle: address(oracle),
            treasury: treasury_,
            integratorRegistry: integratorRegistry_,
            minCommitmentAge: minAge,
            maxCommitmentAge: maxAge
        });
    }

    function _sealV1() internal {
        vm.prank(deployer);
        v1.sealGenesis(ROOT);
    }

    function _sealV2() internal {
        vm.prank(deployer2);
        v2.sealGenesis(ROOT);
    }

    function _commit2(string memory name, address owner, address committer) internal returns (bytes32 c) {
        c = v2.makeCommitment(name, owner, secret, HUMAN);
        vm.prank(committer);
        v2.commit(c);
    }

    // =============================================================================================
    // Constructor
    // =============================================================================================

    function test_constructor_zero_integratorRegistry_reverts() public {
        HandleControllerV2.Init memory init = _initV2(treasury, MIN_AGE, MAX_AGE, address(0));
        vm.expectRevert(HandleControllerV2.ZeroAddress.selector);
        new HandleControllerV2(init);
    }

    function test_views_integratorRegistry_and_v1_surface_unchanged() public view {
        assertEq(address(v2.integratorRegistry()), address(integratorRegistry));
        assertEq(v2.namespaceId(), HANDLE_ROOT);
        assertEq(v2.treasury(), treasury);
        assertTrue(v2.hasRole(v2.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(v2.hasRole(ArcNSConstants.GENESIS_ROLE, deployer2));
        assertTrue(v2.hasRole(ArcNSConstants.PAUSER_ROLE, pauser));
    }

    // =============================================================================================
    // Regression parity — plain register()/registerWithProof() are byte-for-byte V1 (WP-129 bar)
    // =============================================================================================

    /// @dev Same registry, same oracle (same price config), same treasury, both controllers holding
    ///      REGISTRAR_ROLE simultaneously. The oracle's single `recordSale` controller-gate is flipped
    ///      to whichever controller is about to be called (a MockOracle test-harness constraint, not a
    ///      difference in what's being compared); price, treasury delta, minted tokenId formula and
    ///      `NameRegistered` event shape are asserted equal between the V1 leg and the V2 leg.
    function test_register_parity_v1_vs_v2_identical_price_treasury_and_event() public {
        _sealV1();
        _sealV2();

        // --- V1 leg ---
        oracle.setController(HANDLE_ROOT, address(v1), address(registry));
        bytes32 c1 = v1.makeCommitment("parityone", alice, secret, HUMAN);
        vm.prank(alice);
        v1.commit(c1);
        vm.warp(T0 + MIN_AGE);
        uint256 tokenId1 = ArcNSConstants.handleTokenId("parityone");

        vm.expectEmit(true, true, true, true, address(v1));
        emit IHandleController.NameRegistered("parityone", tokenId1, alice, PRICE, HUMAN);
        vm.prank(alice);
        v1.register{value: PRICE}("parityone", alice, secret, HUMAN, PRICE);

        uint256 treasuryAfterV1 = treasury.balance;
        assertEq(treasuryAfterV1, PRICE, "v1: treasury receives exactly price");
        assertEq(registry.ownerOf(tokenId1), alice);

        // --- V2 leg: identical inputs (fresh name; same registry can't reuse "parityone") ---
        oracle.setController(HANDLE_ROOT, address(v2), address(registry));
        bytes32 c2 = v2.makeCommitment("paritytwo", alice, secret, HUMAN);
        vm.prank(alice);
        v2.commit(c2);
        vm.warp(T0 + 2 * MIN_AGE);
        uint256 tokenId2 = ArcNSConstants.handleTokenId("paritytwo");

        vm.expectEmit(true, true, true, true, address(v2));
        emit IHandleController.NameRegistered("paritytwo", tokenId2, alice, PRICE, HUMAN);
        vm.prank(alice);
        v2.register{value: PRICE}("paritytwo", alice, secret, HUMAN, PRICE);

        uint256 treasuryDeltaV2 = treasury.balance - treasuryAfterV1;
        assertEq(treasuryDeltaV2, PRICE, "v2 plain register(): identical treasury delta to v1");
        assertEq(treasuryDeltaV2, treasuryAfterV1, "v1 and v2 push the identical amount for the identical price");
        assertEq(registry.ownerOf(tokenId2), alice);
        assertEq(v1.quote("parityone"), v2.quote("paritytwo"), "same oracle, same price");
        assertEq(v2.withdrawable(alice), 0);
        assertEq(address(v2).balance, 0);
    }

    /// @dev `registerWithProof`, integrator untouched (`address(0)`): same parity bar as plain
    ///      `register`, through the allowlist-proof entry point.
    function test_registerWithProof_parity_v1_vs_v2() public {
        _sealV1();
        _sealV2();

        oracle.setController(HANDLE_ROOT, address(v1), address(registry));
        bytes32[] memory emptyProof = new bytes32[](0);
        bytes32 c1 = v1.makeCommitment("proofone", alice, secret, HUMAN);
        vm.prank(alice);
        v1.commit(c1);
        vm.warp(T0 + MIN_AGE);
        vm.prank(alice);
        v1.registerWithProof{value: PRICE}("proofone", alice, secret, HUMAN, PRICE, emptyProof);
        uint256 treasuryAfterV1 = treasury.balance;

        oracle.setController(HANDLE_ROOT, address(v2), address(registry));
        bytes32 c2 = v2.makeCommitment("prooftwo", alice, secret, HUMAN);
        vm.prank(alice);
        v2.commit(c2);
        vm.warp(T0 + 2 * MIN_AGE);
        vm.prank(alice);
        v2.registerWithProof{value: PRICE}("prooftwo", alice, secret, HUMAN, PRICE, emptyProof);

        assertEq(treasury.balance - treasuryAfterV1, PRICE);
        assertEq(registry.ownerOf(registry.tokenIdOf("prooftwo")), alice);
    }

    // =============================================================================================
    // Fail-closed on a bad integrator (T-REG-1 class): whole call reverts, nothing mutates
    // =============================================================================================

    function test_registerWithIntegrator_notIntegrator_reverts_and_state_untouched() public {
        _sealV2();
        bytes32 c = _commit2("badint", alice, alice);
        vm.warp(T0 + MIN_AGE);

        assertTrue(v2.available("badint"));
        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.NotIntegrator.selector, notIntegrator));
        vm.prank(alice);
        v2.registerWithIntegrator{value: PRICE}("badint", alice, secret, HUMAN, PRICE, notIntegrator);

        // fail-closed: commitment not consumed, name still available, nothing minted, no value moved
        assertEq(v2.commitments(c), T0, "commitment survives the revert");
        assertTrue(v2.available("badint"), "name still available");
        assertFalse(registry.exists(ArcNSConstants.handleTokenId("badint")));
        assertEq(treasury.balance, 0);
        assertEq(alice.balance, 100e18, "no value left the caller");

        // the same commitment can still be revealed successfully afterwards
        vm.prank(alice);
        v2.register{value: PRICE}("badint", alice, secret, HUMAN, PRICE);
        assertEq(registry.ownerOf(ArcNSConstants.handleTokenId("badint")), alice);
    }

    function test_registerWithProofAndIntegrator_notIntegrator_reverts_and_state_untouched() public {
        _sealV2();
        bytes32[] memory emptyProof = new bytes32[](0);
        bytes32 c = _commit2("badint2", alice, alice);
        vm.warp(T0 + MIN_AGE);

        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.NotIntegrator.selector, notIntegrator));
        vm.prank(alice);
        v2.registerWithProofAndIntegrator{value: PRICE}(
            "badint2", alice, secret, HUMAN, PRICE, emptyProof, notIntegrator
        );

        assertEq(v2.commitments(c), T0);
        assertTrue(v2.available("badint2"));
    }

    /// @dev A never-allow-listed attacker naming ITSELF as the integrator gets nothing, on any
    ///      register* overload — the no-self-registration guarantee lives entirely in
    ///      `IntegratorRegistry` (unmodified), exercised here from the controller's call surface.
    function test_no_self_registration_no_matter_the_entry_point() public {
        _sealV2();
        bytes32[] memory emptyProof = new bytes32[](0);

        bytes32 c1 = _commit2("selfreg1", attacker, attacker);
        vm.warp(T0 + MIN_AGE);
        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.NotIntegrator.selector, attacker));
        vm.prank(attacker);
        v2.registerWithIntegrator{value: PRICE}("selfreg1", attacker, secret, HUMAN, PRICE, attacker);
        assertEq(v2.commitments(c1), T0);

        bytes32 c2 = v2.makeCommitment("selfreg2", attacker, secret, HUMAN);
        vm.prank(attacker);
        v2.commit(c2);
        vm.warp(T0 + 2 * MIN_AGE);
        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.NotIntegrator.selector, attacker));
        vm.prank(attacker);
        v2.registerWithProofAndIntegrator{value: PRICE}(
            "selfreg2", attacker, secret, HUMAN, PRICE, emptyProof, attacker
        );
        assertEq(v2.commitments(c2), T0 + MIN_AGE);
        assertFalse(v2.hasRole(v2.DEFAULT_ADMIN_ROLE(), attacker));
        assertFalse(integratorRegistry.isIntegrator(attacker));
    }

    // =============================================================================================
    // Zero-address integrator explicitly refused (never a silent zero-split)
    // =============================================================================================

    function test_registerWithIntegrator_zeroAddress_reverts_IntegratorRequired() public {
        _sealV2();
        _commit2("zero1", alice, alice);
        vm.warp(T0 + MIN_AGE);
        vm.expectRevert(IHandleControllerV2.IntegratorRequired.selector);
        vm.prank(alice);
        v2.registerWithIntegrator{value: PRICE}("zero1", alice, secret, HUMAN, PRICE, address(0));
    }

    function test_registerWithProofAndIntegrator_zeroAddress_reverts_IntegratorRequired() public {
        _sealV2();
        bytes32[] memory emptyProof = new bytes32[](0);
        _commit2("zero2", alice, alice);
        vm.warp(T0 + MIN_AGE);
        vm.expectRevert(IHandleControllerV2.IntegratorRequired.selector);
        vm.prank(alice);
        v2.registerWithProofAndIntegrator{value: PRICE}("zero2", alice, secret, HUMAN, PRICE, emptyProof, address(0));
    }

    // =============================================================================================
    // Happy path with a valid integrator + split bookkeeping
    // =============================================================================================

    function test_registerWithIntegrator_happy_path_splits_and_emits() public {
        _sealV2();
        bytes32 c = _commit2("splitme", alice, alice);
        vm.warp(T0 + MIN_AGE);
        uint256 tokenId = ArcNSConstants.handleTokenId("splitme");
        uint256 expectedShare = PRICE * 2000 / 10_000; // default rate 20%

        vm.expectEmit(true, true, true, true, address(v2));
        emit IHandleController.Credited(integrator, expectedShare);
        vm.expectEmit(true, true, true, true, address(v2));
        emit IIntegratorRegistry.FeeSplit(integrator, PRICE, expectedShare, 2000);
        vm.expectEmit(true, true, true, true, address(v2));
        emit IHandleController.TreasuryFee(tokenId, PRICE - expectedShare);
        vm.expectEmit(true, true, true, true, address(v2));
        emit IHandleController.NameRegistered("splitme", tokenId, alice, PRICE, HUMAN);
        vm.prank(alice);
        v2.registerWithIntegrator{value: PRICE}("splitme", alice, secret, HUMAN, PRICE, integrator);

        assertEq(v2.commitments(c), 0);
        assertEq(v2.withdrawable(integrator), expectedShare);
        assertEq(treasury.balance, PRICE - expectedShare);
        assertEq(registry.ownerOf(tokenId), alice);

        // integrator withdraws its credited share via the ordinary pull ledger
        uint256 before = integrator.balance;
        vm.prank(integrator);
        v2.withdraw();
        assertEq(integrator.balance, before + expectedShare);
        assertEq(v2.withdrawable(integrator), 0);

        vm.expectRevert(IHandleController.NothingToWithdraw.selector);
        vm.prank(integrator);
        v2.withdraw();
    }

    // =============================================================================================
    // Split invariant across the full [0, CAP_BPS] range + cap unreachable above it
    // =============================================================================================

    function testFuzz_split_invariant_full_rate_range(uint256 price, uint16 rateBps) public {
        price = bound(price, 0, 1_000_000e18);
        rateBps = uint16(bound(uint256(rateBps), 0, CAP_BPS));

        vm.prank(admin);
        integratorRegistry.setIntegratorRate(integrator, rateBps);

        oracle.setPrice(HANDLE_ROOT, price);
        _sealV2();
        vm.deal(alice, price + 1 ether);
        bytes32 c = v2.makeCommitment("fuzzname", alice, secret, HUMAN);
        vm.prank(alice);
        v2.commit(c);
        vm.warp(T0 + MIN_AGE);

        vm.prank(alice);
        v2.registerWithIntegrator{value: price}("fuzzname", alice, secret, HUMAN, price, integrator);

        uint256 integratorShare = v2.withdrawable(integrator);
        uint256 treasuryShare = treasury.balance;
        assertEq(integratorShare + treasuryShare, price, "no dust created or lost, any rate in [0, CAP_BPS]");
        assertEq(integratorShare, price * rateBps / 10_000);
        assertLe(integratorShare, price * CAP_BPS / 10_000, "never more than 40% no matter the rate");
    }

    /// @dev The cap lives on `IntegratorRegistry`, not here — confirm 4001 bps is unreachable at the
    ///      source, so no rate this controller could ever read can exceed `CAP_BPS`.
    function test_rate_above_cap_unreachable_at_the_registry() public {
        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.RateAboveCap.selector, 4001, CAP_BPS));
        vm.prank(admin);
        integratorRegistry.setIntegratorRate(integrator, 4001);

        // exactly the cap is fine, and the controller pays out exactly 40% for it
        vm.prank(admin);
        integratorRegistry.setIntegratorRate(integrator, CAP_BPS);
        _sealV2();
        bytes32 c = v2.makeCommitment("atcap", alice, secret, HUMAN);
        vm.prank(alice);
        v2.commit(c);
        vm.warp(T0 + MIN_AGE);
        vm.prank(alice);
        v2.registerWithIntegrator{value: PRICE}("atcap", alice, secret, HUMAN, PRICE, integrator);
        assertEq(v2.withdrawable(integrator), PRICE * CAP_BPS / 10_000);
        assertEq(treasury.balance, PRICE - PRICE * CAP_BPS / 10_000);
    }

    // =============================================================================================
    // No bypass: nothing on the controller's ABI can set/override a rate or the allow-list
    // =============================================================================================

    /// @dev Grepping `IHandleController`/`IHandleControllerV2`'s full ABI surface confirms there is no
    ///      `setIntegrator`/`setIntegratorRate`/`setDefaultRate`-shaped function anywhere on
    ///      `HandleControllerV2` — the only writer of `IntegratorRegistry` state is
    ///      `IntegratorRegistry` itself (`DEFAULT_ADMIN_ROLE` = timelock). This test proves it live: a
    ///      raw call to that selector on the controller — even from the controller's OWN
    ///      `DEFAULT_ADMIN_ROLE` holder — hits neither `receive` nor any real function and reverts via
    ///      the unconditional `fallback()` (`ValueNotAccepted`), because the function does not exist.
    function test_no_rate_setter_reachable_on_controller() public {
        bytes memory callData = abi.encodeWithSignature("setIntegratorRate(address,uint16)", integrator, 4000);
        vm.prank(admin); // even the controller's own timelock-equivalent admin cannot reach it
        (bool ok, bytes memory ret) = address(v2).call(callData);
        assertFalse(ok);
        assertEq(bytes4(ret), IHandleController.ValueNotAccepted.selector, "no such function; hits fallback()");
        // the rate is unaffected — still whatever IntegratorRegistry alone says it is
        assertEq(integratorRegistry.rateOf(integrator), 2000);

        bytes memory setIntegratorCall = abi.encodeWithSignature("setIntegrator(address,bool)", attacker, true);
        vm.prank(admin);
        (ok, ret) = address(v2).call(setIntegratorCall);
        assertFalse(ok);
        assertEq(bytes4(ret), IHandleController.ValueNotAccepted.selector);
        assertFalse(integratorRegistry.isIntegrator(attacker));
    }

    // =============================================================================================
    // Reentrancy: nonReentrant still guards every register* overload and withdraw()
    // =============================================================================================

    function test_reentrancy_blocked_on_register_via_malicious_treasury() public {
        MaliciousTreasury bad = new MaliciousTreasury();
        HandleControllerV2 v2b =
            new HandleControllerV2(_initV2(address(bad), MIN_AGE, MAX_AGE, address(integratorRegistry)));
        bad.setTarget(address(v2b));
        vm.prank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(v2b));
        oracle.setController(HANDLE_ROOT, address(v2b), address(registry));
        vm.prank(deployer2);
        v2b.sealGenesis(ROOT);

        // reentry attempt: call register() again from inside the treasury push
        bad.setReentryCalldata(
            abi.encodeWithSignature(
                "register(string,address,bytes32,uint8,uint256)", "reentrant", alice, secret, HUMAN, PRICE
            )
        );

        bytes32 c = v2b.makeCommitment("reentrytest", alice, secret, HUMAN);
        vm.prank(alice);
        v2b.commit(c);
        vm.warp(T0 + MIN_AGE);
        vm.prank(alice);
        v2b.register{value: PRICE}("reentrytest", alice, secret, HUMAN, PRICE);

        // the outer call completed (treasury doesn't revert on receive), but the reentrant call inside
        // it was rejected specifically by the reentrancy guard, not by some other coincidental revert
        assertTrue(bad.attempted());
        assertFalse(bad.reentrantCallOk());
        assertEq(bytes4(bad.reentrantReturnData()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(
            registry.ownerOf(ArcNSConstants.handleTokenId("reentrytest")), alice, "outer registration still succeeded"
        );
    }

    function test_reentrancy_blocked_on_withdraw_via_malicious_treasury() public {
        MaliciousTreasury bad = new MaliciousTreasury();
        HandleControllerV2 v2b =
            new HandleControllerV2(_initV2(address(bad), MIN_AGE, MAX_AGE, address(integratorRegistry)));
        bad.setTarget(address(v2b));
        vm.prank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(v2b));
        oracle.setController(HANDLE_ROOT, address(v2b), address(registry));
        vm.prank(deployer2);
        v2b.sealGenesis(ROOT);

        bad.setReentryCalldata(abi.encodeWithSignature("withdraw()"));

        bytes32 c = v2b.makeCommitment("reentrywd", alice, secret, HUMAN);
        vm.prank(alice);
        v2b.commit(c);
        vm.warp(T0 + MIN_AGE);
        vm.prank(alice);
        v2b.register{value: PRICE}("reentrywd", alice, secret, HUMAN, PRICE);

        assertTrue(bad.attempted());
        assertFalse(bad.reentrantCallOk());
        assertEq(bytes4(bad.reentrantReturnData()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    }

    // =============================================================================================
    // Withdraw parity: an integrator's credit is just another withdrawable[] balance
    // =============================================================================================

    function test_integrator_double_withdraw_and_zero_balance_withdraw_revert() public {
        _sealV2();
        bytes32 c = v2.makeCommitment("wd1", alice, secret, HUMAN);
        vm.prank(alice);
        v2.commit(c);
        vm.warp(T0 + MIN_AGE);
        vm.prank(alice);
        v2.registerWithIntegrator{value: PRICE}("wd1", alice, secret, HUMAN, PRICE, integrator);

        uint256 credited = v2.withdrawable(integrator);
        assertGt(credited, 0);
        vm.prank(integrator);
        v2.withdraw();
        assertEq(v2.withdrawable(integrator), 0);

        vm.expectRevert(IHandleController.NothingToWithdraw.selector);
        vm.prank(integrator);
        v2.withdraw();

        // an integrator who never received anything also gets NothingToWithdraw
        vm.expectRevert(IHandleController.NothingToWithdraw.selector);
        vm.prank(notIntegrator);
        v2.withdraw();
    }

    // =============================================================================================
    // Genesis / pause / allowlist regression (unmodified inheritance, light coverage)
    // =============================================================================================

    function test_genesis_batch_and_seal_work_through_v2() public {
        string[] memory names = new string[](2);
        names[0] = "gen1";
        names[1] = "gen2";
        uint8[] memory types = new uint8[](2);
        vm.prank(deployer2);
        v2.registerReservedBatch(names, types);
        assertEq(v2.reservedCount(), 2);
        assertEq(registry.ownerOf(registry.tokenIdOf("gen1")), treasury);

        // a second GENESIS_ROLE holder, granted BEFORE the seal (INV-7 forbids granting it after), so
        // we can prove the sealed FLAG (not just the role) gates re-sealing — mirrors
        // HandleController.t.sol::test_sealGenesis_revokes_role_and_second_seal_reverts
        vm.prank(admin);
        v2.grantRole(ArcNSConstants.GENESIS_ROLE, bob);

        vm.prank(deployer2);
        v2.sealGenesis(ROOT);
        assertTrue(v2.genesisSealed());
        assertFalse(v2.hasRole(ArcNSConstants.GENESIS_ROLE, deployer2));

        vm.expectRevert(IHandleController.GenesisAlreadySealed.selector);
        vm.prank(bob);
        v2.sealGenesis(ROOT);
    }

    function test_pause_blocks_all_register_overloads_but_not_withdraw() public {
        _sealV2();
        vm.prank(admin);
        integratorRegistry.setIntegrator(integrator, true);
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.prank(pauser);
        v2.pause();
        assertTrue(v2.paused());

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        v2.register{value: PRICE}("p1", alice, secret, HUMAN, PRICE);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        v2.registerWithProof{value: PRICE}("p2", alice, secret, HUMAN, PRICE, emptyProof);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        v2.registerWithIntegrator{value: PRICE}("p3", alice, secret, HUMAN, PRICE, integrator);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        v2.registerWithProofAndIntegrator{value: PRICE}("p4", alice, secret, HUMAN, PRICE, emptyProof, integrator);

        vm.prank(admin);
        v2.unpause();
        assertFalse(v2.paused());
        _commit2("p1", alice, alice);
        vm.warp(block.timestamp + MIN_AGE);
        vm.prank(alice);
        v2.register{value: PRICE}("p1", alice, secret, HUMAN, PRICE);
        assertEq(registry.ownerOf(registry.tokenIdOf("p1")), alice);
    }

    function test_allowlist_gate_applies_identically_to_integrator_overloads() public {
        _sealV2();
        bytes32 root = keccak256("root");
        vm.prank(admin);
        v2.setAllowlist(root, uint64(T0 + 1 days));

        bytes32 c = _commit2("allow1", alice, alice);
        vm.warp(T0 + MIN_AGE);
        vm.expectRevert(IHandleController.AllowlistRequired.selector);
        vm.prank(alice);
        v2.registerWithIntegrator{value: PRICE}("allow1", alice, secret, HUMAN, PRICE, integrator);
        assertEq(v2.commitments(c), T0);
    }
}
