// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {HandleController} from "../../src/handle/HandleController.sol";
import {HandleControllerV2} from "../../src/handle/HandleControllerV2.sol";
import {HandleControllerV3} from "../../src/handle/HandleControllerV3.sol";
import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IHandleController} from "../../src/interfaces/IHandleController.sol";
import {IHandleControllerV2} from "../../src/interfaces/IHandleControllerV2.sol";
import {IHandleControllerV3} from "../../src/interfaces/IHandleControllerV3.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {IIntegratorRegistry} from "../../src/interfaces/IIntegratorRegistry.sol";
import {IntegratorRegistry} from "../../src/parity/IntegratorRegistry.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {MockOracle} from "../handle/mocks/MockOracle.sol";
import {MaliciousTreasury} from "../handle/mocks/MaliciousTreasury.sol";

/// @dev An `IIntegratorRegistry` that unconditionally reverts on `rateOf`/`computeSplit`, used to prove
///      the integrator-split branch retained inside `HandleControllerV3._register` is genuinely dead
///      code from `registerDirect` (which only ever calls it with `integrator == address(0)`, short-
///      circuiting `rateBps = 0` before any external call is made).
contract AlwaysRevertingIntegratorRegistry is IIntegratorRegistry {
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

/// @notice Unit tests for `HandleControllerV3`: TESTNET-ONLY single-transaction (`registerDirect`)
///         registration for the handle namespace, additive alongside `HandleController` (V1) and
///         `HandleControllerV2` on the same `HandleRegistry`.
///
/// @dev CEO-requirement walkthrough exercised by the tests below:
///        1. Front-running protection dropped deliberately: `registerDirect` mints with no commit step
///           at all — `test_registerDirect_happy_path_mints_charges_and_emits` shows a single tx with
///           no prior `commit`-shaped call anywhere, and `test_commitFunctionSelector_doesNotExist`
///           proves the commit-reveal ABI surface is genuinely gone, not merely unused.
///        2. `oracle.recordSale` is NEVER called by V3 — the single most important design decision in
///           this file, because `ArcNSPriceOracle.namespaceInfo(ns).controller` is a single address per
///           namespace and `setController` REPLACES it; making V3 the namespace controller would break
///           whichever of V1/V2 is currently live. `test_oracle_recordSale_never_invoked_...` is the
///           regression guard: `totalSold` must never move because of a `registerDirect` call.
///        3. Additivity: V3 is granted `REGISTRAR_ROLE` ALONGSIDE V1 and V2 (never instead of), and
///           nothing is ever revoked from either — `test_v1_and_v2_registration_still_work_after_v3_...`
///           and `test_v3_registerDirect_and_v1_commitReveal_mint_different_names_in_the_same_block`
///           prove all three controllers coexist and keep working on the same `HandleRegistry`/oracle.
contract HandleControllerV3Test is Test {
    bytes32 internal constant HANDLE_ROOT = ArcNSConstants.HANDLE_ROOT;
    uint256 internal constant PRICE = 5e18;
    uint256 internal constant MIN_AGE = 60;
    uint256 internal constant MAX_AGE = 24 hours;
    uint256 internal constant T0 = 1_700_000_000;
    bytes32 internal constant ROOT = keccak256("genesis-root");

    HandleRegistry internal registry;
    HandleController internal v1;
    HandleControllerV2 internal v2;
    HandleControllerV3 internal v3;
    MockOracle internal oracle;
    IntegratorRegistry internal integratorRegistry;

    address internal admin = makeAddr("admin");
    address internal deployer = makeAddr("deployer"); // v1 genesis admin
    address internal deployer2 = makeAddr("deployer2"); // v2 genesis admin
    address internal deployer3 = makeAddr("deployer3"); // v3 genesis admin
    address internal pauser = makeAddr("pauser");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");
    address internal integrator = makeAddr("integrator");

    bytes32 internal secret = keccak256("alice-secret");
    uint8 internal constant HUMAN = 0;

    function setUp() public {
        vm.warp(T0);
        oracle = new MockOracle();
        registry = new HandleRegistry(admin, treasury, IArcNSPriceOracle(address(oracle)), 7 days);
        integratorRegistry = new IntegratorRegistry(admin);

        v1 = new HandleController(_initV1(treasury, MIN_AGE, MAX_AGE));
        v2 = new HandleControllerV2(_initV2(treasury, MIN_AGE, MAX_AGE, address(integratorRegistry)));
        v3 = new HandleControllerV3(_initV3(treasury, address(integratorRegistry)));

        // V3 is granted REGISTRAR_ROLE ALONGSIDE V1 and V2, mirroring the live additive plan — nothing
        // is ever revoked from either as part of standing V3 up.
        vm.startPrank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(v1));
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(v2));
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(v3));
        vm.stopPrank();

        // Default namespace controller is v1 (the live oracle-controller slot V3 must never touch);
        // individual tests flip it to v2 for their v2 leg. V3 never becomes the oracle controller.
        oracle.init(HANDLE_ROOT, address(v1), address(registry), PRICE, 2e18);

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

    function _initV3(address treasury_, address integratorRegistry_)
        internal
        view
        returns (HandleControllerV3.Init memory)
    {
        return HandleControllerV3.Init({
            admin: admin,
            genesisAdmin: deployer3,
            pauser: pauser,
            registry: address(registry),
            oracle: address(oracle),
            treasury: treasury_,
            integratorRegistry: integratorRegistry_
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

    function _sealV3() internal {
        vm.prank(deployer3);
        v3.sealGenesis(ROOT);
    }

    // =============================================================================================
    // Constructor
    // =============================================================================================

    function test_constructor_zero_address_reverts() public {
        HandleControllerV3.Init memory base = _initV3(treasury, address(integratorRegistry));

        HandleControllerV3.Init memory init = base;
        init.admin = address(0);
        vm.expectRevert(HandleControllerV3.ZeroAddress.selector);
        new HandleControllerV3(init);

        init = base;
        init.genesisAdmin = address(0);
        vm.expectRevert(HandleControllerV3.ZeroAddress.selector);
        new HandleControllerV3(init);

        init = base;
        init.pauser = address(0);
        vm.expectRevert(HandleControllerV3.ZeroAddress.selector);
        new HandleControllerV3(init);

        init = base;
        init.registry = address(0);
        vm.expectRevert(HandleControllerV3.ZeroAddress.selector);
        new HandleControllerV3(init);

        init = base;
        init.oracle = address(0);
        vm.expectRevert(HandleControllerV3.ZeroAddress.selector);
        new HandleControllerV3(init);

        init = base;
        init.treasury = address(0);
        vm.expectRevert(HandleControllerV3.ZeroAddress.selector);
        new HandleControllerV3(init);

        init = base;
        init.integratorRegistry = address(0);
        vm.expectRevert(HandleControllerV3.ZeroAddress.selector);
        new HandleControllerV3(init);
    }

    function test_views_match_v2_where_shared() public view {
        assertEq(v3.namespaceId(), HANDLE_ROOT);
        assertEq(v3.namespaceId(), v2.namespaceId());
        assertEq(v3.treasury(), treasury);
        assertEq(v3.treasury(), v2.treasury());
        assertEq(address(v3.integratorRegistry()), address(integratorRegistry));
        assertEq(address(v3.integratorRegistry()), address(v2.integratorRegistry()));
        assertEq(v3.valid("alice"), v2.valid("alice"));
        assertEq(v3.valid("Not_Valid!"), v2.valid("Not_Valid!"));
        assertEq(v3.available("freshname"), v2.available("freshname"));
        assertEq(v3.quote("freshname"), v2.quote("freshname"));
        assertTrue(v3.hasRole(v3.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(v3.hasRole(ArcNSConstants.GENESIS_ROLE, deployer3));
        assertTrue(v3.hasRole(ArcNSConstants.PAUSER_ROLE, pauser));
    }

    /// @dev Proves the commit-reveal surface is genuinely gone from V3's ABI, not just unused: raw
    ///      calls to `commit(bytes32)` and `makeCommitment(string,address,bytes32,uint8)` selectors hit
    ///      the unconditional payable `fallback()` and revert `ValueNotAccepted`, exactly like any other
    ///      nonexistent function on this contract.
    function test_commitFunctionSelector_doesNotExist() public {
        bytes memory commitCall = abi.encodeWithSignature("commit(bytes32)", keccak256("whatever"));
        (bool ok1, bytes memory ret1) = address(v3).call(commitCall);
        assertFalse(ok1);
        assertEq(bytes4(ret1), IHandleControllerV3.ValueNotAccepted.selector);

        bytes memory makeCommitmentCall =
            abi.encodeWithSignature("makeCommitment(string,address,bytes32,uint8)", "alice", alice, secret, HUMAN);
        (bool ok2, bytes memory ret2) = address(v3).call(makeCommitmentCall);
        assertFalse(ok2);
        assertEq(bytes4(ret2), IHandleControllerV3.ValueNotAccepted.selector);
    }

    // =============================================================================================
    // registerDirect — happy path and reverts
    // =============================================================================================

    function test_registerDirect_happy_path_mints_charges_and_emits() public {
        _sealV3();
        uint256 tokenId = ArcNSConstants.handleTokenId("directname");

        // No commit call anywhere before this — single transaction, no prior state at all.
        vm.expectEmit(true, true, true, true, address(v3));
        emit IHandleControllerV3.NameRegistered("directname", tokenId, alice, PRICE, HUMAN);
        vm.prank(alice);
        v3.registerDirect{value: PRICE}("directname", alice, HUMAN, PRICE);

        assertEq(registry.ownerOf(tokenId), alice);
        assertEq(treasury.balance, PRICE);
        assertEq(address(v3).balance, 0);
    }

    function test_registerDirect_priceChanged_reverts_when_quote_exceeds_maxPrice() public {
        _sealV3();
        vm.expectRevert(abi.encodeWithSelector(IHandleControllerV3.PriceChanged.selector, PRICE, PRICE - 1));
        vm.prank(alice);
        v3.registerDirect{value: PRICE}("toopricey", alice, HUMAN, PRICE - 1);
        assertFalse(registry.exists(ArcNSConstants.handleTokenId("toopricey")));
    }

    function test_registerDirect_insufficientValue_reverts() public {
        _sealV3();
        vm.expectRevert(abi.encodeWithSelector(IHandleControllerV3.InsufficientValue.selector, PRICE, PRICE - 1));
        vm.prank(alice);
        v3.registerDirect{value: PRICE - 1}("underpaid", alice, HUMAN, PRICE);
        assertFalse(registry.exists(ArcNSConstants.handleTokenId("underpaid")));
    }

    function test_registerDirect_nameNotAvailable_reverts_for_already_registered_handle() public {
        _sealV3();
        vm.prank(alice);
        v3.registerDirect{value: PRICE}("taken", alice, HUMAN, PRICE);

        vm.expectRevert(abi.encodeWithSelector(IHandleControllerV3.NameNotAvailable.selector, "taken"));
        vm.prank(bob);
        v3.registerDirect{value: PRICE}("taken", bob, HUMAN, PRICE);
        assertEq(registry.ownerOf(ArcNSConstants.handleTokenId("taken")), alice);
    }

    function test_registerDirect_notCanonical_reverts() public {
        _sealV3();
        string memory bad = "Not_Valid!";
        vm.expectRevert(abi.encodeWithSelector(IHandleControllerV3.NotCanonical.selector, bad));
        vm.prank(alice);
        v3.registerDirect{value: PRICE}(bad, alice, HUMAN, PRICE);
    }

    function test_registerDirect_registrationsClosed_before_sealGenesis_reverts() public {
        // v3 constructed in setUp() but never sealed here.
        vm.expectRevert(IHandleControllerV3.RegistrationsClosed.selector);
        vm.prank(alice);
        v3.registerDirect{value: PRICE}("tooearly", alice, HUMAN, PRICE);
    }

    function test_registerDirect_blocked_while_paused_but_withdraw_still_works() public {
        _sealV3();
        vm.prank(alice);
        v3.registerDirect{value: PRICE + 1 ether}("beforepause", alice, HUMAN, PRICE + 1 ether);
        uint256 credited = v3.withdrawable(alice);
        assertEq(credited, 1 ether);

        vm.prank(pauser);
        v3.pause();
        assertTrue(v3.paused());

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        v3.registerDirect{value: PRICE}("duringpause", alice, HUMAN, PRICE);

        // withdraw is never pausable (SR-62)
        uint256 before = alice.balance;
        vm.prank(alice);
        v3.withdraw();
        assertEq(alice.balance, before + credited);

        vm.prank(admin);
        v3.unpause();
        assertFalse(v3.paused());
        vm.prank(alice);
        v3.registerDirect{value: PRICE}("afterunpause", alice, HUMAN, PRICE);
        assertEq(registry.ownerOf(ArcNSConstants.handleTokenId("afterunpause")), alice);
    }

    /// @dev Documents the flagged limitation explicitly: unlike V2 (which has `registerWithProof` as an
    ///      escape hatch), V3 has no proof-taking sibling, so `allowlistActive() == true` makes
    ///      `registerDirect` permanently unusable until governance clears V3's own allowlist.
    function test_registerDirect_blocked_during_allowlist_window_with_no_proof_escape_hatch() public {
        _sealV3();
        bytes32 root = keccak256("v3-allowlist-root");
        vm.prank(admin);
        v3.setAllowlist(root, uint64(T0 + 1 days));
        assertTrue(v3.allowlistActive());

        vm.expectRevert(IHandleControllerV3.AllowlistRequired.selector);
        vm.prank(alice);
        v3.registerDirect{value: PRICE}("allowlisted", alice, HUMAN, PRICE);

        // no escape hatch: even a caller who WOULD be on an allowlist has no proof parameter to supply.
        vm.expectRevert(IHandleControllerV3.AllowlistRequired.selector);
        vm.prank(bob);
        v3.registerDirect{value: PRICE}("allowlisted2", bob, HUMAN, PRICE);

        // clearing the allowlist restores normal operation.
        vm.prank(admin);
        v3.setAllowlist(bytes32(0), 0);
        assertFalse(v3.allowlistActive());
        vm.prank(alice);
        v3.registerDirect{value: PRICE}("allowlisted", alice, HUMAN, PRICE);
        assertEq(registry.ownerOf(ArcNSConstants.handleTokenId("allowlisted")), alice);

        // V3's allowlist is independent per-contract state from V2's — this never affected v2.
        assertFalse(v2.allowlistActive());
    }

    // =============================================================================================
    // Pull ledger: excess credit / withdraw
    // =============================================================================================

    function test_excess_value_credited_and_withdrawable() public {
        _sealV3();
        uint256 overpay = PRICE + 3 ether;
        vm.prank(alice);
        v3.registerDirect{value: overpay}("overpaid", alice, HUMAN, overpay);

        assertEq(v3.withdrawable(alice), 3 ether);
        assertEq(address(v3).balance, 3 ether);

        uint256 before = alice.balance;
        vm.prank(alice);
        v3.withdraw();
        assertEq(alice.balance, before + 3 ether);
        assertEq(v3.withdrawable(alice), 0);
        assertEq(address(v3).balance, 0);
    }

    function test_withdraw_nothing_reverts() public {
        vm.expectRevert(IHandleControllerV3.NothingToWithdraw.selector);
        vm.prank(alice);
        v3.withdraw();
    }

    function test_double_withdraw_reverts_second_time() public {
        _sealV3();
        vm.prank(alice);
        v3.registerDirect{value: PRICE + 1 ether}("doublewd", alice, HUMAN, PRICE + 1 ether);

        vm.prank(alice);
        v3.withdraw();

        vm.expectRevert(IHandleControllerV3.NothingToWithdraw.selector);
        vm.prank(alice);
        v3.withdraw();
    }

    // =============================================================================================
    // Genesis / INV-7
    // =============================================================================================

    function test_genesis_batch_and_seal_work_through_v3() public {
        string[] memory names = new string[](2);
        names[0] = "gen1v3";
        names[1] = "gen2v3";
        uint8[] memory types = new uint8[](2);
        vm.prank(deployer3);
        v3.registerReservedBatch(names, types);
        assertEq(v3.reservedCount(), 2);
        assertEq(registry.ownerOf(registry.tokenIdOf("gen1v3")), treasury);

        vm.prank(admin);
        v3.grantRole(ArcNSConstants.GENESIS_ROLE, bob);

        vm.prank(deployer3);
        v3.sealGenesis(ROOT);
        assertTrue(v3.genesisSealed());
        assertFalse(v3.hasRole(ArcNSConstants.GENESIS_ROLE, deployer3));

        vm.expectRevert(IHandleControllerV3.GenesisAlreadySealed.selector);
        vm.prank(bob);
        v3.sealGenesis(ROOT);
    }

    function test_grantRole_genesisRole_after_seal_reverts() public {
        _sealV3();
        vm.expectRevert(IHandleControllerV3.GenesisAlreadySealed.selector);
        vm.prank(admin);
        v3.grantRole(ArcNSConstants.GENESIS_ROLE, bob);
    }

    // =============================================================================================
    // Reentrancy
    // =============================================================================================

    function test_reentrancy_blocked_on_register_via_malicious_treasury() public {
        MaliciousTreasury bad = new MaliciousTreasury();
        HandleControllerV3 v3b = new HandleControllerV3(_initV3(address(bad), address(integratorRegistry)));
        bad.setTarget(address(v3b));
        vm.prank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(v3b));
        vm.prank(deployer3);
        v3b.sealGenesis(ROOT);

        bad.setReentryCalldata(
            abi.encodeWithSignature("registerDirect(string,address,uint8,uint256)", "reentrant", alice, HUMAN, PRICE)
        );

        vm.prank(alice);
        v3b.registerDirect{value: PRICE}("reentrytest", alice, HUMAN, PRICE);

        assertTrue(bad.attempted());
        assertFalse(bad.reentrantCallOk());
        assertEq(bytes4(bad.reentrantReturnData()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(
            registry.ownerOf(ArcNSConstants.handleTokenId("reentrytest")), alice, "outer registration still succeeded"
        );
    }

    function test_reentrancy_blocked_on_withdraw_via_malicious_treasury() public {
        MaliciousTreasury bad = new MaliciousTreasury();
        HandleControllerV3 v3b = new HandleControllerV3(_initV3(address(bad), address(integratorRegistry)));
        bad.setTarget(address(v3b));
        vm.prank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(v3b));
        vm.prank(deployer3);
        v3b.sealGenesis(ROOT);

        bad.setReentryCalldata(abi.encodeWithSignature("withdraw()"));

        vm.prank(alice);
        v3b.registerDirect{value: PRICE}("reentrywd", alice, HUMAN, PRICE);

        assertTrue(bad.attempted());
        assertFalse(bad.reentrantCallOk());
        assertEq(bytes4(bad.reentrantReturnData()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    }

    // =============================================================================================
    // Dead-code proof: integrator branch is unreachable from registerDirect
    // =============================================================================================

    /// @dev `registerDirect` only ever calls `_register(..., address(0))`, so `integrator == address(0)`
    ///      short-circuits `rateBps = 0` before any external call into `IntegratorRegistry` — swapping
    ///      in a registry whose `rateOf`/`computeSplit` unconditionally revert must not affect
    ///      `registerDirect` at all.
    function test_integratorRegistry_never_called_from_registerDirect_even_if_it_would_revert() public {
        AlwaysRevertingIntegratorRegistry angryRegistry = new AlwaysRevertingIntegratorRegistry();
        HandleControllerV3 v3c = new HandleControllerV3(_initV3(treasury, address(angryRegistry)));
        vm.prank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(v3c));
        vm.prank(deployer3);
        v3c.sealGenesis(ROOT);

        vm.prank(alice);
        v3c.registerDirect{value: PRICE}("deadbranch", alice, HUMAN, PRICE);
        assertEq(registry.ownerOf(ArcNSConstants.handleTokenId("deadbranch")), alice);
        assertEq(treasury.balance, PRICE);
    }

    // =============================================================================================
    // CRITICAL: V3 never advances the oracle's sale counter
    // =============================================================================================

    /// @dev Regression guard against someone re-adding `oracle.recordSale(HANDLE_ROOT)` inside V3's
    ///      `_register` and silently reintroducing the single-namespace-controller collision: V3 is
    ///      never the oracle's controller for HANDLE_ROOT (V1 is, per `setUp`), so a reintroduced call
    ///      would revert `NotNamespaceController` — but even if it somehow didn't, `totalSold` must
    ///      never move because of a `registerDirect` call.
    function test_oracle_recordSale_never_invoked_totalSold_unchanged_after_registerDirect() public {
        _sealV3();
        uint64 before = oracle.totalSold(HANDLE_ROOT);
        uint256 recordSaleCallsBefore = oracle.recordSaleCalls();

        vm.prank(alice);
        v3.registerDirect{value: PRICE}("nosale1", alice, HUMAN, PRICE);
        vm.prank(bob);
        v3.registerDirect{value: PRICE}("nosale2", bob, HUMAN, PRICE);
        vm.prank(alice);
        v3.registerDirect{value: PRICE}("nosale3", alice, HUMAN, PRICE);

        assertEq(oracle.totalSold(HANDLE_ROOT), before, "V3 registrations must never advance totalSold");
        assertEq(oracle.recordSaleCalls(), recordSaleCallsBefore, "oracle.recordSale must never be invoked by V3");
    }

    // =============================================================================================
    // Additivity: V1/V2 keep working exactly as before after V3 is deployed and granted
    // =============================================================================================

    /// @dev The core additivity proof: run a full V1 commit/wait/reveal cycle AND a V2
    ///      `registerWithIntegrator` call, both AFTER V3 already holds `REGISTRAR_ROLE` on the same
    ///      `HandleRegistry`, and assert both still mint successfully and both still call
    ///      `oracle.recordSale` successfully — i.e. V3's grant never touched the oracle's namespace
    ///      controller slot that V1 (and, in its leg, V2) depend on.
    function test_v1_and_v2_registration_still_work_after_v3_deployed_and_granted() public {
        _sealV1();
        _sealV2();
        _sealV3();

        // --- V1 leg: full commit/wait/reveal cycle, oracle controller = v1 (set in setUp) ---
        uint64 soldBefore = oracle.totalSold(HANDLE_ROOT);
        bytes32 c1 = v1.makeCommitment("stillv1", alice, secret, HUMAN);
        vm.prank(alice);
        v1.commit(c1);
        vm.warp(T0 + MIN_AGE);
        vm.prank(alice);
        v1.register{value: PRICE}("stillv1", alice, secret, HUMAN, PRICE);
        assertEq(registry.ownerOf(ArcNSConstants.handleTokenId("stillv1")), alice);
        assertEq(oracle.totalSold(HANDLE_ROOT), soldBefore + 1, "v1's recordSale still succeeds");

        // --- V2 leg: registerWithIntegrator, oracle controller flipped to v2 for its own leg ---
        oracle.setController(HANDLE_ROOT, address(v2), address(registry));
        bytes32 c2 = v2.makeCommitment("stillv2", bob, secret, HUMAN);
        vm.prank(bob);
        v2.commit(c2);
        vm.warp(T0 + 2 * MIN_AGE);
        vm.prank(bob);
        v2.registerWithIntegrator{value: PRICE}("stillv2", bob, secret, HUMAN, PRICE, integrator);
        assertEq(registry.ownerOf(ArcNSConstants.handleTokenId("stillv2")), bob);
        assertEq(oracle.totalSold(HANDLE_ROOT), soldBefore + 2, "v2's recordSale still succeeds too");

        // V3 was never made the oracle controller by any of the above.
        assertEq(oracle.namespaceInfo(HANDLE_ROOT).controller, address(v2));
        assertTrue(registry.hasRole(ArcNSConstants.REGISTRAR_ROLE, address(v1)));
        assertTrue(registry.hasRole(ArcNSConstants.REGISTRAR_ROLE, address(v2)));
        assertTrue(registry.hasRole(ArcNSConstants.REGISTRAR_ROLE, address(v3)));
    }

    /// @dev Cross-controller coexistence smoke test: V3's no-commit `registerDirect` and V1's
    ///      commit-reveal cycle mint different names in the same block without interfering with each
    ///      other's state (separate commitment maps, separate withdraw ledgers, same shared registry).
    function test_v3_registerDirect_and_v1_commitReveal_mint_different_names_in_the_same_block() public {
        _sealV1();
        _sealV3();

        bytes32 c1 = v1.makeCommitment("blockv1", alice, secret, HUMAN);
        vm.prank(alice);
        v1.commit(c1);
        vm.warp(T0 + MIN_AGE);

        vm.prank(alice);
        v1.register{value: PRICE}("blockv1", alice, secret, HUMAN, PRICE);
        vm.prank(bob);
        v3.registerDirect{value: PRICE}("blockv3", bob, HUMAN, PRICE);

        assertEq(registry.ownerOf(ArcNSConstants.handleTokenId("blockv1")), alice);
        assertEq(registry.ownerOf(ArcNSConstants.handleTokenId("blockv3")), bob);
    }

    /// @dev V3's `quote()` is a pure delegation to the shared oracle — it reflects whatever price the
    ///      oracle currently reports regardless of which controller (if any) most recently recorded a
    ///      sale, proving V3 carries no cached/derived pricing state of its own.
    function test_quote_reflects_current_oracle_price_regardless_of_which_controller_recorded_sales() public {
        _sealV1();
        _sealV3();

        bytes32 c1 = v1.makeCommitment("pricebump", alice, secret, HUMAN);
        vm.prank(alice);
        v1.commit(c1);
        vm.warp(T0 + MIN_AGE);
        vm.prank(alice);
        v1.register{value: PRICE}("pricebump", alice, secret, HUMAN, PRICE);

        // Simulate the curve moving (the real oracle would derive this from totalSold internally; the
        // mock exposes `setPrice` directly since curve maths is out of its scope).
        uint256 newPrice = PRICE * 2;
        oracle.setPrice(HANDLE_ROOT, newPrice);

        assertEq(v3.quote("newname"), newPrice, "v3.quote reads straight through to the shared oracle");
        vm.prank(bob);
        v3.registerDirect{value: newPrice}("newname", bob, HUMAN, newPrice);
        assertEq(registry.ownerOf(ArcNSConstants.handleTokenId("newname")), bob);
    }

    // =============================================================================================
    // Access control: only REGISTRAR_ROLE holders can mint on the shared registry
    // =============================================================================================

    function test_registerDirect_wrongRole_cannot_call_registry_register_directly() public {
        _sealV3();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, ArcNSConstants.REGISTRAR_ROLE
            )
        );
        vm.prank(attacker);
        registry.register("bypass", attacker, HUMAN, false);
    }
}
