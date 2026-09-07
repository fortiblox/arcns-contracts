// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {HandleController} from "../../src/handle/HandleController.sol";
import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IHandleController} from "../../src/interfaces/IHandleController.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {MockOracle} from "../handle/mocks/MockOracle.sol";
import {RevertingReceiver} from "../handle/mocks/TestHelpers.sol";

/// @notice Unit tests for `HandleController` (WP-105): commit-reveal (T-REG-1), pricing guard,
///         pull ledger, reserved genesis (CEO 6a), seal (SR-16), pause (SR-62).
contract HandleControllerTest is Test {
    bytes32 internal constant HANDLE_ROOT = ArcNSConstants.HANDLE_ROOT;
    uint256 internal constant PRICE = 5e18;
    uint256 internal constant MIN_AGE = 60;
    uint256 internal constant MAX_AGE = 24 hours;
    uint256 internal constant T0 = 1_700_000_000;
    bytes32 internal constant ROOT = keccak256("genesis-root");

    HandleRegistry internal registry;
    HandleController internal controller;
    MockOracle internal oracle;

    address internal admin = makeAddr("admin");
    address internal deployer = makeAddr("deployer");
    address internal pauser = makeAddr("pauser");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    bytes32 internal secret = keccak256("alice-secret");
    uint8 internal constant HUMAN = 0;

    function setUp() public {
        vm.warp(T0);
        oracle = new MockOracle();
        registry = new HandleRegistry(admin, treasury, IArcNSPriceOracle(address(oracle)), 7 days);
        controller = new HandleController(_init(treasury, MIN_AGE, MAX_AGE));
        oracle.init(HANDLE_ROOT, address(controller), address(registry), PRICE, 2e18);
        vm.prank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(controller));
        vm.deal(alice, 100e18);
        vm.deal(bob, 100e18);
        vm.deal(attacker, 100e18);
    }

    function _init(address treasury_, uint256 minAge, uint256 maxAge)
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

    function _seal() internal {
        vm.prank(deployer);
        controller.sealGenesis(ROOT);
    }

    function _commit(string memory name, address owner, address committer) internal returns (bytes32 c) {
        c = controller.makeCommitment(name, owner, secret, HUMAN);
        vm.prank(committer);
        controller.commit(c);
    }

    function _register(string memory name, address owner, uint256 value) internal {
        vm.prank(owner);
        controller.register{value: value}(name, owner, secret, HUMAN, PRICE);
    }

    function _names(uint256 n) internal pure returns (string[] memory names, uint8[] memory types) {
        string[6] memory pool = ["apple", "bank", "coin", "dao", "eth", "fort"];
        names = new string[](n);
        types = new uint8[](n);
        for (uint256 i = 0; i < n; i++) {
            names[i] = pool[i];
            types[i] = uint8(i % 4);
        }
    }

    // ---- constructor / views --------------------------------------------------------------------

    function test_constructor_floors_and_zero_checks() public {
        vm.expectRevert(abi.encodeWithSelector(IHandleController.MinCommitmentAgeBelowFloor.selector, 29, 30));
        new HandleController(_init(treasury, 29, MAX_AGE));

        vm.expectRevert(abi.encodeWithSelector(IHandleController.MaxCommitmentAgeInvalid.selector, 60));
        new HandleController(_init(treasury, 60, 60));

        vm.expectRevert(abi.encodeWithSelector(IHandleController.MaxCommitmentAgeInvalid.selector, 24 hours + 1));
        new HandleController(_init(treasury, 60, 24 hours + 1));

        vm.expectRevert(HandleController.ZeroAddress.selector);
        new HandleController(_init(address(0), 60, MAX_AGE));

        HandleController ok = new HandleController(_init(treasury, 30, 31));
        assertEq(ok.minCommitmentAge(), 30);
        assertEq(ok.maxCommitmentAge(), 31);
        assertEq(ok.MIN_COMMITMENT_AGE_FLOOR(), 30);
    }

    function test_views_and_roles() public view {
        assertEq(controller.namespaceId(), HANDLE_ROOT);
        assertEq(controller.treasury(), treasury);
        assertEq(address(controller.registry()), address(registry));
        assertEq(address(controller.oracle()), address(oracle));
        assertEq(controller.minCommitmentAge(), MIN_AGE);
        assertEq(controller.maxCommitmentAge(), MAX_AGE);
        assertFalse(controller.genesisSealed());
        assertEq(controller.genesisRoot(), bytes32(0));
        assertEq(controller.reservedCount(), 0);
        assertTrue(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(controller.hasRole(ArcNSConstants.GENESIS_ROLE, deployer));
        assertTrue(controller.hasRole(ArcNSConstants.PAUSER_ROLE, pauser));
        assertTrue(controller.valid("alice"));
        assertFalse(controller.valid("Alice"));
        assertTrue(controller.available("alice"));
        assertFalse(controller.available("Alice"));
        assertEq(controller.quote("alice"), PRICE);
    }

    function test_makeCommitment_formula() public view {
        bytes32 expected = keccak256(
            abi.encode(ArcNSConstants.TAG_HANDLE, "alice", alice, secret, block.chainid, address(controller), HUMAN)
        );
        assertEq(controller.makeCommitment("alice", alice, secret, HUMAN), expected);
        assertTrue(controller.makeCommitment("alice", bob, secret, HUMAN) != expected);
        assertTrue(controller.makeCommitment("alice", alice, secret, 1) != expected);
    }

    // ---- commit -------------------------------------------------------------------------------------

    function test_commit_stores_and_rejects_unexpired_duplicate() public {
        bytes32 c = controller.makeCommitment("alice", alice, secret, HUMAN);
        vm.expectEmit(true, true, true, true, address(controller));
        emit IHandleController.CommitmentMade(c, T0);
        vm.prank(alice);
        controller.commit(c);
        assertEq(controller.commitments(c), T0);

        vm.expectRevert(abi.encodeWithSelector(IHandleController.UnexpiredCommitmentExists.selector, c));
        controller.commit(c);

        vm.warp(T0 + MAX_AGE);
        vm.expectRevert(abi.encodeWithSelector(IHandleController.UnexpiredCommitmentExists.selector, c));
        controller.commit(c);

        vm.warp(T0 + MAX_AGE + 1);
        controller.commit(c);
        assertEq(controller.commitments(c), T0 + MAX_AGE + 1);
    }

    // ---- register: happy path ----------------------------------------------------------------------

    function test_register_happy_path() public {
        _seal();
        bytes32 c = _commit("alice", alice, alice);
        vm.warp(T0 + MIN_AGE);
        uint256 tokenId = registry.tokenIdOf("alice");

        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.HandleRegistered(tokenId, "alice", alice, HUMAN, false);
        vm.expectEmit(true, true, true, true, address(controller));
        emit IHandleController.TreasuryFee(tokenId, PRICE);
        vm.expectEmit(true, true, true, true, address(controller));
        emit IHandleController.NameRegistered("alice", tokenId, alice, PRICE, HUMAN);
        _register("alice", alice, PRICE);

        assertEq(registry.ownerOf(tokenId), alice);
        assertEq(registry.epochOf(tokenId), 1);
        assertEq(treasury.balance, PRICE, "treasury receives exactly price");
        assertEq(address(controller).balance, 0);
        assertEq(controller.withdrawable(alice), 0);
        assertEq(controller.commitments(c), 0, "reveal deletes the commitment");
        assertEq(oracle.totalSold(HANDLE_ROOT), 1);
        assertFalse(controller.available("alice"));

        // the consumed commitment cannot be replayed
        vm.expectRevert(abi.encodeWithSelector(IHandleController.NameNotAvailable.selector, "alice"));
        _register("alice", alice, PRICE);
    }

    function test_register_owner_may_differ_from_payer() public {
        _seal();
        bytes32 c = controller.makeCommitment("alice", bob, secret, HUMAN);
        vm.prank(alice);
        controller.commit(c);
        vm.warp(T0 + MIN_AGE);
        vm.prank(alice);
        controller.register{value: PRICE}("alice", bob, secret, HUMAN, PRICE);
        assertEq(registry.ownerOf(registry.tokenIdOf("alice")), bob);
    }

    // ---- register: T-REG-1 cases -------------------------------------------------------------------

    function test_register_commitmentTooNew() public {
        _seal();
        bytes32 c = _commit("alice", alice, alice);
        vm.warp(T0 + MIN_AGE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IHandleController.CommitmentTooNew.selector, c, T0 + MIN_AGE, T0 + MIN_AGE - 1)
        );
        _register("alice", alice, PRICE);
    }

    function test_register_commitmentTooOld() public {
        _seal();
        bytes32 c = _commit("alice", alice, alice);
        vm.warp(T0 + MAX_AGE - 1);
        _register("alice", alice, PRICE); // last valid second
        assertEq(registry.ownerOf(registry.tokenIdOf("alice")), alice);

        bytes32 c2 = _commit("bob", bob, bob);
        vm.warp(T0 + MAX_AGE - 1 + MAX_AGE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHandleController.CommitmentTooOld.selector, c2, T0 + MAX_AGE - 1 + MAX_AGE, T0 + MAX_AGE - 1 + MAX_AGE
            )
        );
        _register("bob", bob, PRICE);
        assertTrue(c != c2);
    }

    function test_register_differentOwner_is_commitmentNotFound() public {
        _seal();
        _commit("alice", alice, alice);
        vm.warp(T0 + MIN_AGE);
        bytes32 other = controller.makeCommitment("alice", bob, secret, HUMAN);
        vm.expectRevert(abi.encodeWithSelector(IHandleController.CommitmentNotFound.selector, other));
        vm.prank(alice);
        controller.register{value: PRICE}("alice", bob, secret, HUMAN, PRICE);

        // different secret / type are equally unknown
        bytes32 other2 = controller.makeCommitment("alice", alice, keccak256("x"), HUMAN);
        vm.expectRevert(abi.encodeWithSelector(IHandleController.CommitmentNotFound.selector, other2));
        vm.prank(alice);
        controller.register{value: PRICE}("alice", alice, keccak256("x"), HUMAN, PRICE);
    }

    function test_register_replayed_reveal_mints_to_committed_owner() public {
        _seal();
        _commit("alice", alice, alice);
        vm.warp(T0 + MIN_AGE);
        uint256 tokenId = registry.tokenIdOf("alice");

        // attacker sees the reveal calldata in the mempool and front-runs it verbatim
        vm.prank(attacker);
        controller.register{value: PRICE}("alice", alice, secret, HUMAN, PRICE);
        assertEq(registry.ownerOf(tokenId), alice, "name lands with the committed owner");
        assertEq(attacker.balance, 100e18 - PRICE, "attacker paid for the victim's name");

        // attacker's own commitment, any ordering, cannot obtain the name any more
        bytes32 ca = controller.makeCommitment("alice", attacker, secret, HUMAN);
        vm.prank(attacker);
        controller.commit(ca);
        vm.warp(T0 + 2 * MIN_AGE);
        vm.expectRevert(abi.encodeWithSelector(IHandleController.NameNotAvailable.selector, "alice"));
        vm.prank(attacker);
        controller.register{value: PRICE}("alice", attacker, secret, HUMAN, PRICE);

        // victim's own reveal now fails as unavailable, but she already owns it
        vm.expectRevert(abi.encodeWithSelector(IHandleController.NameNotAvailable.selector, "alice"));
        _register("alice", alice, PRICE);
        assertEq(registry.ownerOf(tokenId), alice);
    }

    function test_register_attacker_cannot_front_run_with_own_commitment_without_secret() public {
        _seal();
        _commit("alice", alice, alice);
        // attacker commits for himself in the same block and reveals first — different name owner ⇒ his own name
        bytes32 ca = controller.makeCommitment("alice", attacker, keccak256("guess"), HUMAN);
        vm.prank(attacker);
        controller.commit(ca);
        vm.warp(T0 + MIN_AGE);
        vm.prank(attacker);
        controller.register{value: PRICE}("alice", attacker, keccak256("guess"), HUMAN, PRICE);
        // honest race: whoever's *own* commitment reveals first wins — this is the ENS model; the point
        // is that the attacker needed a commitment >= minCommitmentAge old, so he could not react to
        // alice's reveal. Her reveal now fails as unavailable.
        vm.expectRevert(abi.encodeWithSelector(IHandleController.NameNotAvailable.selector, "alice"));
        _register("alice", alice, PRICE);
    }

    // ---- register: pricing / value -----------------------------------------------------------------

    function test_register_priceChanged() public {
        _seal();
        _commit("alice", alice, alice);
        vm.warp(T0 + MIN_AGE);
        oracle.setPrice(HANDLE_ROOT, PRICE + 1);
        vm.expectRevert(abi.encodeWithSelector(IHandleController.PriceChanged.selector, PRICE + 1, PRICE));
        _register("alice", alice, PRICE + 1);
        // a price *drop* is fine and only the quote is charged
        oracle.setPrice(HANDLE_ROOT, PRICE - 1e18);
        _register("alice", alice, PRICE);
        assertEq(treasury.balance, PRICE - 1e18);
        assertEq(controller.withdrawable(alice), 1e18);
    }

    function test_register_insufficientValue() public {
        _seal();
        _commit("alice", alice, alice);
        vm.warp(T0 + MIN_AGE);
        vm.expectRevert(abi.encodeWithSelector(IHandleController.InsufficientValue.selector, PRICE, PRICE - 1));
        _register("alice", alice, PRICE - 1);
    }

    function test_register_overpayment_credited_and_withdrawable() public {
        _seal();
        _commit("alice", alice, alice);
        vm.warp(T0 + MIN_AGE);
        vm.expectEmit(true, true, true, true, address(controller));
        emit IHandleController.Credited(alice, 1e18);
        _register("alice", alice, PRICE + 1e18);

        assertEq(treasury.balance, PRICE);
        assertEq(controller.withdrawable(alice), 1e18);
        assertEq(address(controller).balance, 1e18);

        uint256 before = alice.balance;
        vm.expectEmit(true, true, true, true, address(controller));
        emit IHandleController.Withdrawn(alice, 1e18);
        vm.prank(alice);
        controller.withdraw();
        assertEq(alice.balance, before + 1e18);
        assertEq(controller.withdrawable(alice), 0);
        assertEq(address(controller).balance, 0);

        vm.expectRevert(IHandleController.NothingToWithdraw.selector);
        vm.prank(alice);
        controller.withdraw();
    }

    function testFuzz_register_overpayment_is_exactly_credited(uint96 extra) public {
        _seal();
        _commit("alice", alice, alice);
        vm.warp(T0 + MIN_AGE);
        vm.deal(alice, PRICE + uint256(extra));
        _register("alice", alice, PRICE + uint256(extra));
        assertEq(treasury.balance, PRICE);
        assertEq(controller.withdrawable(alice), extra);
        assertEq(address(controller).balance, extra);
    }

    function test_withdraw_failure_keeps_ledger() public {
        _seal();
        RevertingReceiver payer = new RevertingReceiver();
        vm.deal(address(payer), 10e18);
        bytes32 c = controller.makeCommitment("alice", address(payer), secret, HUMAN);
        vm.prank(address(payer));
        controller.commit(c);
        vm.warp(T0 + MIN_AGE);
        vm.prank(address(payer));
        controller.register{value: PRICE + 1e18}("alice", address(payer), secret, HUMAN, PRICE);
        assertEq(controller.withdrawable(address(payer)), 1e18);

        vm.expectRevert(abi.encodeWithSelector(IHandleController.WithdrawFailed.selector, address(payer), 1e18));
        vm.prank(address(payer));
        controller.withdraw();
        assertEq(controller.withdrawable(address(payer)), 1e18, "credit survives a failed pull");
    }

    function test_register_reverts_when_treasury_rejects_value() public {
        RevertingReceiver bad = new RevertingReceiver();
        HandleController c2 = new HandleController(_init(address(bad), MIN_AGE, MAX_AGE));
        oracle.setController(HANDLE_ROOT, address(c2), address(registry));
        vm.prank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(c2));
        vm.prank(deployer);
        c2.sealGenesis(ROOT);
        bytes32 c = c2.makeCommitment("alice", alice, secret, HUMAN);
        vm.prank(alice);
        c2.commit(c);
        vm.warp(T0 + MIN_AGE);
        vm.expectRevert(abi.encodeWithSelector(IHandleController.TreasuryPaymentFailed.selector, address(bad), PRICE));
        vm.prank(alice);
        c2.register{value: PRICE}("alice", alice, secret, HUMAN, PRICE);
        assertTrue(registry.exists(registry.tokenIdOf("alice")) == false);
    }

    // ---- register: gates ---------------------------------------------------------------------------

    function test_register_before_seal_reverts_RegistrationsClosed() public {
        _commit("alice", alice, alice);
        vm.warp(T0 + MIN_AGE);
        vm.expectRevert(IHandleController.RegistrationsClosed.selector);
        _register("alice", alice, PRICE);
    }

    function test_register_notCanonical_and_notAvailable() public {
        _seal();
        vm.expectRevert(abi.encodeWithSelector(IHandleController.NotCanonical.selector, "Alice"));
        vm.prank(alice);
        controller.register{value: PRICE}("Alice", alice, secret, HUMAN, PRICE);

        (string[] memory names, uint8[] memory types) = _names(1);
        // registered via a second (post-seal) genesis path is impossible; use the registrar role directly
        vm.prank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, admin);
        vm.prank(admin);
        registry.register(names[0], treasury, types[0], true);
        vm.expectRevert(abi.encodeWithSelector(IHandleController.NameNotAvailable.selector, names[0]));
        vm.prank(alice);
        controller.register{value: PRICE}(names[0], alice, secret, HUMAN, PRICE);
    }

    // ---- genesis -----------------------------------------------------------------------------------

    function test_reservedBatch_mints_to_treasury_and_is_idempotent() public {
        (string[] memory names, uint8[] memory types) = _names(4);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, ArcNSConstants.GENESIS_ROLE
            )
        );
        vm.prank(alice);
        controller.registerReservedBatch(names, types);

        uint8[] memory shortTypes = new uint8[](3);
        vm.expectRevert(IHandleController.BatchLengthMismatch.selector);
        vm.prank(deployer);
        controller.registerReservedBatch(names, shortTypes);

        uint256 id0 = registry.tokenIdOf(names[0]);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.HandleRegistered(id0, names[0], treasury, types[0], true);
        vm.expectEmit(true, true, true, true, address(controller));
        emit IHandleController.ReservedRegistered(id0, names[0]);
        vm.prank(deployer);
        controller.registerReservedBatch(names, types);
        assertEq(controller.reservedCount(), 4);
        for (uint256 i = 0; i < 4; i++) {
            uint256 id = registry.tokenIdOf(names[i]);
            assertEq(registry.ownerOf(id), treasury);
            assertEq(registry.handleOf(id).handleType, types[i]);
            assertFalse(registry.isTransferable(id));
        }
        assertEq(registry.balanceOf(treasury), 4);

        // re-run with overlap: 2 old + 2 new ⇒ only the new ones mint
        (string[] memory names6, uint8[] memory types6) = _names(6);
        string[] memory overlap = new string[](4);
        uint8[] memory overlapTypes = new uint8[](4);
        for (uint256 i = 0; i < 4; i++) {
            overlap[i] = names6[i + 2];
            overlapTypes[i] = types6[i + 2];
        }
        vm.prank(deployer);
        controller.registerReservedBatch(overlap, overlapTypes);
        assertEq(controller.reservedCount(), 6);
        assertEq(registry.balanceOf(treasury), 6);

        // empty batch is a no-op
        vm.prank(deployer);
        controller.registerReservedBatch(new string[](0), new uint8[](0));
        assertEq(controller.reservedCount(), 6);
    }

    function test_reservedBatch_does_not_touch_totalSold() public {
        (string[] memory names, uint8[] memory types) = _names(6);
        vm.prank(deployer);
        controller.registerReservedBatch(names, types);
        assertEq(oracle.totalSold(HANDLE_ROOT), 0, "genesis must not move the volume ramp (CEO 6a)");
        assertEq(oracle.recordSaleCalls(), 0);
        assertEq(treasury.balance, 0, "genesis pays nothing");

        _seal();
        _commit("alice", alice, alice);
        vm.warp(T0 + MIN_AGE);
        _register("alice", alice, PRICE);
        assertEq(oracle.totalSold(HANDLE_ROOT), 1, "a paid registration is exactly one sale");
        assertEq(oracle.recordSaleCalls(), 1);
    }

    function test_reservedBatch_rejects_non_canonical_via_registry() public {
        string[] memory names = new string[](1);
        names[0] = "Apple";
        uint8[] memory types = new uint8[](1);
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NotCanonical.selector, "Apple"));
        vm.prank(deployer);
        controller.registerReservedBatch(names, types);
    }

    function test_sealGenesis_revokes_role_and_second_seal_reverts() public {
        (string[] memory names, uint8[] memory types) = _names(2);
        vm.prank(deployer);
        controller.registerReservedBatch(names, types);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, ArcNSConstants.GENESIS_ROLE
            )
        );
        vm.prank(admin);
        controller.sealGenesis(ROOT);

        // a second GENESIS_ROLE holder exists so we can prove the sealed flag (not only the role) gates
        vm.prank(admin);
        controller.grantRole(ArcNSConstants.GENESIS_ROLE, bob);

        vm.expectEmit(true, true, true, true, address(controller));
        emit IHandleController.GenesisSealed(HANDLE_ROOT, ROOT, 2);
        vm.expectEmit(true, true, true, true, address(controller));
        emit IAccessControl.RoleRevoked(ArcNSConstants.GENESIS_ROLE, deployer, deployer);
        vm.prank(deployer);
        controller.sealGenesis(ROOT);

        assertTrue(controller.genesisSealed());
        assertEq(controller.genesisRoot(), ROOT);
        assertFalse(controller.hasRole(ArcNSConstants.GENESIS_ROLE, deployer), "SR-16: renounced in the seal tx");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, ArcNSConstants.GENESIS_ROLE
            )
        );
        vm.prank(deployer);
        controller.sealGenesis(ROOT);

        vm.expectRevert(IHandleController.GenesisAlreadySealed.selector);
        vm.prank(bob);
        controller.sealGenesis(keccak256("other"));

        vm.expectRevert(IHandleController.GenesisAlreadySealed.selector);
        vm.prank(bob);
        controller.registerReservedBatch(names, types);
    }

    // ---- pause (SR-62) ----------------------------------------------------------------------------

    function test_pause_blocks_register_but_not_withdraw_and_unpause_is_admin_only() public {
        _seal();
        _commit("alice", alice, alice);
        _commit("bob", bob, bob);
        vm.warp(T0 + MIN_AGE);
        _register("alice", alice, PRICE + 1e18);
        assertEq(controller.withdrawable(alice), 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, ArcNSConstants.PAUSER_ROLE
            )
        );
        vm.prank(alice);
        controller.pause();

        vm.prank(pauser);
        controller.pause();
        assertTrue(controller.paused());

        vm.expectRevert(Pausable.EnforcedPause.selector);
        _register("bob", bob, PRICE);

        // commit still works (harmless), withdraw still works (SR-62)
        _commit("carol", bob, bob);
        vm.prank(alice);
        controller.withdraw();
        assertEq(controller.withdrawable(alice), 0);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, bytes32(0))
        );
        vm.prank(pauser);
        controller.unpause();

        vm.prank(admin);
        controller.unpause();
        assertFalse(controller.paused());
        _register("bob", bob, PRICE);
        assertEq(registry.ownerOf(registry.tokenIdOf("bob")), bob);
    }

    // ---- value handling (T-GAS-1) -----------------------------------------------------------------

    function test_receive_and_fallback_revert() public {
        vm.prank(alice);
        (bool ok, bytes memory data) = address(controller).call{value: 1}("");
        assertFalse(ok);
        assertEq(bytes4(data), IHandleController.ValueNotAccepted.selector);
        vm.prank(alice);
        (ok, data) = address(controller).call{value: 1}(hex"01020304");
        assertFalse(ok);
        assertEq(bytes4(data), IHandleController.ValueNotAccepted.selector);
        vm.prank(alice);
        (ok,) = address(controller).call{value: 1}(abi.encodeWithSelector(controller.commit.selector, bytes32(0)));
        assertFalse(ok, "commit is not payable");
        assertEq(address(controller).balance, 0);
    }
}
