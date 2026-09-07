// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, stdError} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {HandleNormalize} from "../../src/lib/HandleNormalize.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {Base64Decoder, RevertingReceiver} from "./mocks/TestHelpers.sol";

/// @notice Unit tests for `HandleRegistry` (WP-105 / WP-108 recovery / WP-109 metadata).
contract HandleRegistryTest is Test {
    bytes32 internal constant HANDLE_ROOT = ArcNSConstants.HANDLE_ROOT;
    uint256 internal constant TOKENIZE_PRICE = 2e18;
    uint256 internal constant T0 = 1_700_000_000;

    HandleRegistry internal registry;
    MockOracle internal oracle;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal registrar = makeAddr("registrar");
    address internal market = makeAddr("market");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal recoveryKey = makeAddr("recoveryKey");
    address internal operator = makeAddr("operator");

    uint256 internal aliceId;

    function setUp() public {
        vm.warp(T0);
        oracle = new MockOracle();
        registry = new HandleRegistry(admin, treasury, IArcNSPriceOracle(address(oracle)), 1 days);
        oracle.init(HANDLE_ROOT, registrar, address(registry), 5e18, TOKENIZE_PRICE);
        vm.startPrank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, registrar);
        registry.grantRole(ArcNSConstants.MARKET_ROLE, market);
        vm.stopPrank();
        aliceId = registry.tokenIdOf("alice");
    }

    // ---- helpers ------------------------------------------------------------------------------

    function _register(string memory name, address owner) internal returns (uint256 tokenId) {
        vm.prank(registrar);
        tokenId = registry.register(name, owner, uint8(IHandleRegistry.HandleType.Human), false);
    }

    function _tokenize(uint256 tokenId, address owner) internal {
        vm.deal(owner, TOKENIZE_PRICE);
        vm.prank(owner);
        registry.tokenize{value: TOKENIZE_PRICE}(tokenId, TOKENIZE_PRICE);
    }

    function _expectEpoch(uint256 tokenId, uint64 epoch, uint8 reason) internal {
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.EpochBumped(tokenId, epoch, uint64(block.timestamp + 1), reason);
    }

    function _decodeJson(string memory uri) internal pure returns (string memory) {
        return string(Base64Decoder.decodeDataUri(uri));
    }

    // ---- register -----------------------------------------------------------------------------

    function test_register_mints_and_indexes() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit IERC721.Transfer(address(0), alice, aliceId);
        _expectEpoch(aliceId, 1, 0);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.HandleRegistered(aliceId, "alice", alice, 0, false);
        uint256 id = _register("alice", alice);

        assertEq(id, aliceId);
        assertEq(id, uint256(keccak256("alice")));
        assertEq(registry.ownerOf(id), alice);
        assertEq(registry.balanceOf(alice), 1);
        assertTrue(registry.exists(id));
        assertEq(registry.nameOf(id), "alice");
        assertEq(registry.epochOf(id), 1);
        assertEq(registry.nodeToToken(registry.nodeOf("alice")), id);
        assertEq(registry.nodeOf("alice"), keccak256(abi.encodePacked(HANDLE_ROOT, keccak256("alice"))));

        IHandleRegistry.Handle memory h = registry.handleOf(id);
        (bytes32 seed,) = HandleNormalize.seedBytes("alice");
        assertEq(h.name, seed);
        assertEq(h.registeredAt, uint64(T0 + 1));
        assertEq(h.epoch, 1);
        assertEq(h.handleType, 0);
        assertFalse(h.transferable);
        assertFalse(h.locked);
        assertEq(h.unlockInitiatedAt, 0);
        assertEq(h.recoveryInitiatedAt, 0);
    }

    function test_register_canonical_only() public {
        string[6] memory bad = ["Alice", "@alice", "-alice", "a--b", "1234", " alice"];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NotCanonical.selector, bad[i]));
            vm.prank(registrar);
            registry.register(bad[i], alice, 0, false);
        }
        _register("a-b1", alice);
        _register("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", bob);
        assertEq(
            registry.nameOf(registry.tokenIdOf("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        );
    }

    function test_register_alreadyRegistered() public {
        _register("alice", alice);
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.AlreadyRegistered.selector, aliceId));
        _register("alice", bob);
    }

    function test_register_onlyRegistrarRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, ArcNSConstants.REGISTRAR_ROLE
            )
        );
        vm.prank(alice);
        registry.register("alice", alice, 0, false);
    }

    function test_register_zeroOwner_and_badType() public {
        vm.expectRevert(IHandleRegistry.ZeroAddress.selector);
        vm.prank(registrar);
        registry.register("alice", address(0), 0, false);

        vm.expectRevert(stdError.enumConversionError);
        vm.prank(registrar);
        registry.register("alice", alice, 4, false);

        vm.prank(registrar);
        registry.register("alice", alice, uint8(IHandleRegistry.HandleType.Agent), true);
        assertEq(registry.handleOf(aliceId).handleType, 3);
    }

    // ---- epoch / registeredAt ---------------------------------------------------------------------

    function test_epoch_and_registeredAt_bump_on_every_ownership_change() public {
        uint256 id = _register("alice", alice);
        assertEq(registry.epochOf(id), 1);
        assertEq(registry.handleOf(id).registeredAt, T0 + 1);

        // 1. owner transfer (soulbound path)
        vm.warp(T0 + 10);
        _expectEpoch(id, 2, 1);
        vm.prank(alice);
        registry.transfer(id, bob);
        assertEq(registry.ownerOf(id), bob);
        assertEq(registry.handleOf(id).registeredAt, T0 + 11);

        // 2. recovery completion
        vm.prank(bob);
        registry.setRecovery(id, recoveryKey);
        vm.prank(recoveryKey);
        registry.initiateRecovery(id, carol);
        vm.warp(T0 + 10 + 7 days);
        _expectEpoch(id, 3, 2);
        vm.prank(recoveryKey);
        registry.completeRecovery(id);
        assertEq(registry.ownerOf(id), carol);
        assertEq(registry.handleOf(id).registeredAt, T0 + 11 + 7 days);

        // 3. market move of a soulbound handle (MARKET_ROLE, approved)
        vm.warp(T0 + 20 + 7 days);
        vm.prank(carol);
        registry.approve(market, id);
        _expectEpoch(id, 4, 3);
        vm.prank(market);
        registry.transferFrom(carol, alice, id);
        assertEq(registry.ownerOf(id), alice);

        // 4. ERC-721 transfer after tokenize
        _tokenize(id, alice);
        vm.warp(T0 + 30 + 7 days);
        _expectEpoch(id, 5, 1);
        vm.prank(alice);
        registry.safeTransferFrom(alice, bob, id);
        assertEq(registry.ownerOf(id), bob);

        // 5. burn
        vm.warp(T0 + 40 + 7 days);
        _expectEpoch(id, 6, 4);
        vm.prank(bob);
        registry.release(id);
        assertFalse(registry.exists(id));
        assertEq(registry.epochOf(id), 6);

        // 6. re-register starts above every previous epoch (SR-13)
        _expectEpoch(id, 7, 0);
        _register("alice", carol);
        assertEq(registry.epochOf(id), 7);
        assertEq(registry.handleOf(id).registeredAt, T0 + 41 + 7 days);
    }

    function testFuzz_epoch_bumps_by_exactly_one_on_every_update(uint8 hops, uint64 gap) public {
        gap = uint64(bound(gap, 0, 365 days));
        uint256 id = _register("alice", alice);
        _tokenize(id, alice);
        address[3] memory ring = [alice, bob, carol];
        uint64 expected = 1;
        for (uint256 i = 0; i < hops; i++) {
            address from = ring[i % 3];
            address to = ring[(i + 1) % 3];
            vm.warp(block.timestamp + gap);
            uint64 before = registry.epochOf(id);
            if (i % 2 == 0) {
                vm.prank(from);
                registry.transfer(id, to);
            } else {
                vm.prank(from);
                registry.transferFrom(from, to, id);
            }
            expected++;
            assertEq(registry.epochOf(id), before + 1);
            assertEq(registry.epochOf(id), expected);
            assertEq(registry.handleOf(id).registeredAt, uint64(block.timestamp + 1));
            assertEq(registry.ownerOf(id), to);
        }
    }

    // ---- soulbound / transfers --------------------------------------------------------------------

    function test_soulbound_erc721_transfers_revert_before_tokenize_and_work_after() public {
        uint256 id = _register("alice", alice);

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.TransfersLocked.selector, id));
        vm.prank(alice);
        registry.transferFrom(alice, bob, id);

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.TransfersLocked.selector, id));
        vm.prank(alice);
        registry.safeTransferFrom(alice, bob, id);

        vm.prank(alice);
        registry.setApprovalForAll(operator, true);
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.TransfersLocked.selector, id));
        vm.prank(operator);
        registry.transferFrom(alice, bob, id);

        _tokenize(id, alice);
        assertTrue(registry.isTransferable(id));
        vm.prank(operator);
        registry.transferFrom(alice, bob, id);
        assertEq(registry.ownerOf(id), bob);
        vm.prank(bob);
        registry.safeTransferFrom(bob, carol, id, "");
        assertEq(registry.ownerOf(id), carol);
    }

    function test_transfer_owner_only_zero_and_nonexistent() public {
        uint256 id = _register("alice", alice);
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NotOwner.selector, id, bob));
        vm.prank(bob);
        registry.transfer(id, bob);

        vm.expectRevert(IHandleRegistry.ZeroAddress.selector);
        vm.prank(alice);
        registry.transfer(id, address(0));

        uint256 unknown = registry.tokenIdOf("nobody");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, unknown));
        vm.prank(alice);
        registry.transfer(unknown, bob);
    }

    function test_transfer_clears_approval_and_recovery() public {
        uint256 id = _register("alice", alice);
        vm.startPrank(alice);
        registry.approve(operator, id);
        registry.setRecovery(id, recoveryKey);
        registry.transfer(id, bob);
        vm.stopPrank();
        assertEq(registry.getApproved(id), address(0));
        assertEq(registry.recoveryOf(id), address(0));
        assertFalse(registry.recoveryPending(id));
    }

    function test_market_role_moves_soulbound_handle_with_approval_only() public {
        uint256 id = _register("alice", alice);
        // without ERC-721 approval the market is still not authorised
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, market, id));
        vm.prank(market);
        registry.transferFrom(alice, bob, id);

        vm.prank(alice);
        registry.approve(market, id);
        vm.prank(market);
        registry.transferFrom(alice, bob, id);
        assertEq(registry.ownerOf(id), bob);
        assertEq(registry.epochOf(id), 2);
    }

    // ---- lock / unlock (SR-14, T-NFT-4) -----------------------------------------------------------

    function test_lock_blocks_every_move_including_operators() public {
        uint256 id = _register("alice", alice);
        _tokenize(id, alice);
        vm.startPrank(alice);
        registry.setApprovalForAll(operator, true);
        registry.approve(market, id);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.Locked(id);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IERC4906.MetadataUpdate(id);
        registry.lock(id);
        vm.stopPrank();
        assertTrue(registry.isLocked(id));

        bytes memory lockedErr = abi.encodeWithSelector(IHandleRegistry.HandleLocked.selector, id);

        vm.expectRevert(lockedErr);
        vm.prank(operator);
        registry.transferFrom(alice, bob, id);

        vm.expectRevert(lockedErr);
        vm.prank(market);
        registry.transferFrom(alice, bob, id);

        vm.startPrank(alice);
        vm.expectRevert(lockedErr);
        registry.transferFrom(alice, bob, id);
        vm.expectRevert(lockedErr);
        registry.safeTransferFrom(alice, bob, id);
        vm.expectRevert(lockedErr);
        registry.transfer(id, bob);
        vm.expectRevert(lockedErr);
        registry.release(id);
        vm.expectRevert(lockedErr);
        registry.createSubname(id, "pay");
        vm.expectRevert(lockedErr);
        registry.revokeSubname(id, "pay");
        vm.stopPrank();
        assertEq(registry.ownerOf(id), alice);
    }

    function test_lock_blocks_tokenize_and_recovery_config() public {
        uint256 id = _register("alice", alice);
        vm.prank(alice);
        registry.setRecovery(id, recoveryKey);
        vm.prank(alice);
        registry.lock(id);
        bytes memory lockedErr = abi.encodeWithSelector(IHandleRegistry.HandleLocked.selector, id);

        vm.deal(alice, TOKENIZE_PRICE);
        vm.expectRevert(lockedErr);
        vm.prank(alice);
        registry.tokenize{value: TOKENIZE_PRICE}(id, TOKENIZE_PRICE);

        vm.expectRevert(lockedErr);
        vm.prank(alice);
        registry.setRecovery(id, bob);

        vm.expectRevert(lockedErr);
        vm.prank(recoveryKey);
        registry.initiateRecovery(id, bob);
    }

    function test_unlock_timelock_floor_is_seven_days() public {
        // constructor config was 1 day; effective must be 7 days
        assertEq(registry.recoveryTimelock(), 7 days);
        assertEq(registry.MIN_UNLOCK_TIMELOCK(), 7 days);
        assertEq(registry.MIN_RECOVERY_TIMELOCK(), 7 days);

        uint256 id = _register("alice", alice);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.HandleNotLocked.selector, id));
        registry.initiateUnlock(id);
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.HandleNotLocked.selector, id));
        registry.completeUnlock(id);

        registry.lock(id);
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NoUnlockPending.selector, id));
        registry.completeUnlock(id);
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NoUnlockPending.selector, id));
        registry.cancelUnlock(id);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.UnlockInitiated(id, uint64(block.timestamp));
        registry.initiateUnlock(id);
        assertEq(registry.handleOf(id).unlockInitiatedAt, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.UnlockPending.selector, id));
        registry.initiateUnlock(id);

        uint64 readyAt = uint64(T0 + 7 days);
        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.TimelockNotElapsed.selector, readyAt, readyAt - 1));
        registry.completeUnlock(id);

        vm.warp(readyAt);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.Unlocked(id);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IERC4906.MetadataUpdate(id);
        registry.completeUnlock(id);
        vm.stopPrank();
        assertFalse(registry.isLocked(id));
        assertEq(registry.handleOf(id).unlockInitiatedAt, 0);
        // free to move again
        vm.prank(alice);
        registry.transfer(id, bob);
        assertEq(registry.ownerOf(id), bob);
    }

    function test_unlock_uses_configured_timelock_above_floor() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.RecoveryTimelockSet(10 days);
        registry.setRecoveryTimelock(10 days);
        assertEq(registry.recoveryTimelock(), 10 days);

        uint256 id = _register("alice", alice);
        vm.startPrank(alice);
        registry.lock(id);
        registry.initiateUnlock(id);
        vm.warp(T0 + 7 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHandleRegistry.TimelockNotElapsed.selector, uint64(T0 + 10 days), uint64(T0 + 7 days)
            )
        );
        registry.completeUnlock(id);
        vm.warp(T0 + 10 days);
        registry.completeUnlock(id);
        vm.stopPrank();
        assertFalse(registry.isLocked(id));
    }

    function testFuzz_recoveryTimelock_is_floored(uint64 cfg) public {
        vm.prank(admin);
        registry.setRecoveryTimelock(cfg);
        uint64 expected = cfg > 7 days ? cfg : 7 days;
        assertEq(registry.recoveryTimelock(), expected);
    }

    function test_setRecoveryTimelock_admin_only() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        registry.setRecoveryTimelock(30 days);
    }

    function test_relock_clears_pending_unlock_and_cancelUnlock_keeps_lock() public {
        uint256 id = _register("alice", alice);
        vm.startPrank(alice);
        registry.lock(id);
        registry.initiateUnlock(id);
        registry.lock(id); // idempotent re-lock
        assertTrue(registry.isLocked(id));
        assertEq(registry.handleOf(id).unlockInitiatedAt, 0);

        registry.initiateUnlock(id);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.UnlockCancelled(id);
        registry.cancelUnlock(id);
        assertTrue(registry.isLocked(id));
        assertEq(registry.handleOf(id).unlockInitiatedAt, 0);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NotOwner.selector, id, bob));
        vm.prank(bob);
        registry.lock(id);
    }

    // ---- recovery (SR-15, T-NFT-3) ----------------------------------------------------------------

    function test_recovery_full_cycle() public {
        uint256 id = _register("alice", alice);

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NoRecoverySet.selector, id));
        vm.prank(recoveryKey);
        registry.initiateRecovery(id, bob);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.RecoverySet(id, recoveryKey);
        vm.prank(alice);
        registry.setRecovery(id, recoveryKey);
        assertEq(registry.recoveryOf(id), recoveryKey);

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NotRecoveryKey.selector, id, bob));
        vm.prank(bob);
        registry.initiateRecovery(id, bob);

        vm.expectRevert(IHandleRegistry.ZeroAddress.selector);
        vm.prank(recoveryKey);
        registry.initiateRecovery(id, address(0));

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NoRecoveryPending.selector, id));
        vm.prank(recoveryKey);
        registry.completeRecovery(id);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.RecoveryInitiated(id, bob, uint64(block.timestamp));
        vm.prank(recoveryKey);
        registry.initiateRecovery(id, bob);
        assertTrue(registry.recoveryPending(id));
        assertEq(registry.recoveryTargetOf(id), bob);
        assertEq(registry.handleOf(id).recoveryInitiatedAt, uint64(T0));

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.RecoveryPending.selector, id));
        vm.prank(recoveryKey);
        registry.initiateRecovery(id, carol);

        // pending recovery blocks transfer / tokenize / release
        bytes memory pendingErr = abi.encodeWithSelector(IHandleRegistry.RecoveryPending.selector, id);
        vm.deal(alice, TOKENIZE_PRICE);
        vm.startPrank(alice);
        vm.expectRevert(pendingErr);
        registry.transfer(id, carol);
        vm.expectRevert(pendingErr);
        registry.tokenize{value: TOKENIZE_PRICE}(id, TOKENIZE_PRICE);
        vm.expectRevert(pendingErr);
        registry.release(id);
        vm.stopPrank();

        // market path is blocked too
        vm.prank(alice);
        registry.approve(market, id);
        vm.expectRevert(pendingErr);
        vm.prank(market);
        registry.transferFrom(alice, carol, id);

        uint64 readyAt = uint64(T0 + 7 days);
        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.TimelockNotElapsed.selector, readyAt, readyAt - 1));
        vm.prank(recoveryKey);
        registry.completeRecovery(id);

        vm.warp(readyAt);
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NotRecoveryKey.selector, id, alice));
        vm.prank(alice);
        registry.completeRecovery(id);

        _expectEpoch(id, 2, 2);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.RecoveryCompleted(id, alice, bob);
        vm.prank(recoveryKey);
        registry.completeRecovery(id);

        assertEq(registry.ownerOf(id), bob);
        assertEq(registry.epochOf(id), 2);
        assertEq(registry.recoveryOf(id), address(0), "key cleared by the epoch rule");
        assertEq(registry.recoveryTargetOf(id), address(0));
        assertFalse(registry.recoveryPending(id));
        assertFalse(registry.isTransferable(id), "recovery does not tokenize");
    }

    function test_recovery_cancel_by_owner_even_while_locked() public {
        uint256 id = _register("alice", alice);
        vm.prank(alice);
        registry.setRecovery(id, recoveryKey);

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NoRecoveryPending.selector, id));
        vm.prank(alice);
        registry.cancelRecovery(id);

        vm.prank(recoveryKey);
        registry.initiateRecovery(id, bob);
        vm.prank(alice);
        registry.lock(id);

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NotOwner.selector, id, recoveryKey));
        vm.prank(recoveryKey);
        registry.cancelRecovery(id);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.RecoveryCancelled(id);
        vm.prank(alice);
        registry.cancelRecovery(id);
        assertFalse(registry.recoveryPending(id));
        assertEq(registry.recoveryTargetOf(id), address(0));
        assertEq(registry.recoveryOf(id), recoveryKey, "key survives a cancel");

        // recovery cannot land on a locked handle either
        vm.prank(alice);
        registry.initiateUnlock(id); // still locked, just pending
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.HandleLocked.selector, id));
        vm.prank(recoveryKey);
        registry.completeRecovery(id);
    }

    function test_recovery_cleared_after_every_transfer_path() public {
        // owner transfer
        uint256 id = _register("alice", alice);
        vm.prank(alice);
        registry.setRecovery(id, recoveryKey);
        vm.prank(alice);
        registry.transfer(id, bob);
        assertEq(registry.recoveryOf(id), address(0));

        // market transfer
        vm.prank(bob);
        registry.setRecovery(id, recoveryKey);
        vm.prank(bob);
        registry.approve(market, id);
        vm.prank(market);
        registry.transferFrom(bob, carol, id);
        assertEq(registry.recoveryOf(id), address(0));

        // burn
        vm.prank(carol);
        registry.setRecovery(id, recoveryKey);
        vm.prank(carol);
        registry.release(id);
        assertEq(registry.recoveryOf(id), address(0));
        assertFalse(registry.recoveryPending(id));
    }

    function test_setRecovery_refused_after_tokenize_and_clears_pending() public {
        uint256 id = _register("alice", alice);
        vm.prank(alice);
        registry.setRecovery(id, recoveryKey);
        vm.prank(recoveryKey);
        registry.initiateRecovery(id, bob);

        // re-setting the key drops the pending recovery (X1 parity)
        vm.prank(alice);
        registry.setRecovery(id, carol);
        assertFalse(registry.recoveryPending(id));
        assertEq(registry.recoveryOf(id), carol);

        // zero clears
        vm.prank(alice);
        registry.setRecovery(id, address(0));
        assertEq(registry.recoveryOf(id), address(0));

        _tokenize(id, alice);
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.RecoveryDisabledWhenTokenized.selector, id));
        vm.prank(alice);
        registry.setRecovery(id, recoveryKey);
    }

    // ---- tokenize -----------------------------------------------------------------------------------

    function test_tokenize_exact_price_treasury_push_and_counter() public {
        uint256 id = _register("alice", alice);
        vm.deal(alice, 10e18);

        vm.expectRevert(
            abi.encodeWithSelector(IHandleRegistry.IncorrectPayment.selector, TOKENIZE_PRICE, TOKENIZE_PRICE - 1)
        );
        vm.prank(alice);
        registry.tokenize{value: TOKENIZE_PRICE}(id, TOKENIZE_PRICE - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IHandleRegistry.IncorrectPayment.selector, TOKENIZE_PRICE, TOKENIZE_PRICE - 1)
        );
        vm.prank(alice);
        registry.tokenize{value: TOKENIZE_PRICE - 1}(id, TOKENIZE_PRICE);

        vm.expectRevert(
            abi.encodeWithSelector(IHandleRegistry.IncorrectPayment.selector, TOKENIZE_PRICE, TOKENIZE_PRICE + 1)
        );
        vm.prank(alice);
        registry.tokenize{value: TOKENIZE_PRICE + 1}(id, TOKENIZE_PRICE + 1);

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NotOwner.selector, id, bob));
        vm.prank(bob);
        registry.tokenize{value: 0}(id, TOKENIZE_PRICE);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.TreasuryFee(id, TOKENIZE_PRICE);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.Tokenized(id, TOKENIZE_PRICE);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IERC4906.MetadataUpdate(id);
        vm.prank(alice);
        registry.tokenize{value: TOKENIZE_PRICE}(id, type(uint256).max);

        assertTrue(registry.isTransferable(id));
        assertEq(treasury.balance, TOKENIZE_PRICE);
        assertEq(address(registry).balance, 0);
        assertEq(oracle.tokenized(HANDLE_ROOT), 1);
        assertEq(oracle.recordTokenizeCalls(), 1);
        assertEq(registry.epochOf(id), 1, "tokenize is not an ownership change");

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.AlreadyTransferable.selector, id));
        vm.prank(alice);
        registry.tokenize{value: TOKENIZE_PRICE}(id, TOKENIZE_PRICE);
    }

    function test_tokenize_zero_price_skips_treasury_call() public {
        oracle.setTokenizePrice(HANDLE_ROOT, 0);
        uint256 id = _register("alice", alice);
        vm.prank(alice);
        registry.tokenize{value: 0}(id, 0);
        assertTrue(registry.isTransferable(id));
        assertEq(oracle.tokenized(HANDLE_ROOT), 1);
    }

    function test_tokenize_reverts_when_treasury_rejects_value() public {
        RevertingReceiver bad = new RevertingReceiver();
        HandleRegistry r2 = new HandleRegistry(admin, address(bad), IArcNSPriceOracle(address(oracle)), 0);
        oracle.setController(HANDLE_ROOT, registrar, address(r2));
        vm.prank(admin);
        r2.grantRole(ArcNSConstants.REGISTRAR_ROLE, registrar);
        vm.prank(registrar);
        uint256 id = r2.register("alice", alice, 0, false);
        vm.deal(alice, TOKENIZE_PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(IHandleRegistry.TreasuryPaymentFailed.selector, address(bad), TOKENIZE_PRICE)
        );
        vm.prank(alice);
        r2.tokenize{value: TOKENIZE_PRICE}(id, TOKENIZE_PRICE);
        assertFalse(r2.isTransferable(id));
    }

    // ---- release ------------------------------------------------------------------------------------

    function test_release_burns_and_reregister_starts_higher_epoch() public {
        uint256 id = _register("alice", alice);
        vm.prank(alice);
        registry.createSubname(id, "pay");

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NotOwner.selector, id, bob));
        vm.prank(bob);
        registry.release(id);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IERC721.Transfer(alice, address(0), id);
        _expectEpoch(id, 2, 4);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.Released(id);
        vm.prank(alice);
        registry.release(id);

        assertFalse(registry.exists(id));
        assertEq(registry.balanceOf(alice), 0);
        assertEq(registry.nodeToToken(registry.nodeOf("alice")), 0);
        assertEq(registry.nameOf(id), "");
        assertEq(registry.epochOf(id), 2, "epoch persists across the burn");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        registry.ownerOf(id);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        registry.tokenURI(id);

        _register("alice", bob);
        assertEq(registry.epochOf(id), 3);
        assertEq(registry.ownerOf(id), bob);
        assertFalse(registry.isTransferable(id));
        assertEq(registry.nodeToToken(registry.nodeOf("alice")), id);
    }

    function test_release_allowed_for_tokenized_handle() public {
        uint256 id = _register("alice", alice);
        _tokenize(id, alice);
        vm.prank(alice);
        registry.release(id);
        assertFalse(registry.exists(id));
        _register("alice", alice);
        assertFalse(registry.isTransferable(id), "re-registration is soulbound again");
    }

    // ---- sub-handles --------------------------------------------------------------------------------

    function test_subnames_create_revoke_gated() public {
        uint256 id = _register("alice", alice);
        bytes32 node = registry.nodeOf("alice");
        bytes32 labelhash = keccak256("pay");
        bytes32 subnode = keccak256(abi.encodePacked(node, labelhash));

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NotOwner.selector, id, bob));
        vm.prank(bob);
        registry.createSubname(id, "pay");

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.NotCanonical.selector, "Pay"));
        vm.prank(alice);
        registry.createSubname(id, "Pay");

        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.SubnameCreated(id, labelhash, "pay");
        vm.prank(alice);
        registry.createSubname(id, "pay");
        assertEq(registry.subnameCreatedAt(id, labelhash), uint64(T0));
        assertEq(registry.subnodeToToken(subnode), id);

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.SubnameExists.selector, id, labelhash));
        vm.prank(alice);
        registry.createSubname(id, "pay");

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.SubnameUnknown.selector, id, keccak256("shop")));
        vm.prank(alice);
        registry.revokeSubname(id, "shop");

        vm.prank(alice);
        registry.lock(id);
        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.HandleLocked.selector, id));
        vm.prank(alice);
        registry.revokeSubname(id, "pay");
        vm.prank(alice);
        registry.initiateUnlock(id);
        vm.warp(T0 + 7 days);
        vm.prank(alice);
        registry.completeUnlock(id);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IHandleRegistry.SubnameRevoked(id, labelhash);
        vm.prank(alice);
        registry.revokeSubname(id, "pay");
        assertEq(registry.subnameCreatedAt(id, labelhash), 0);
        assertEq(registry.subnodeToToken(subnode), 0);
    }

    // ---- views --------------------------------------------------------------------------------------

    function test_isOwnerOrOperator() public {
        uint256 id = _register("alice", alice);
        assertTrue(registry.isOwnerOrOperator(id, alice));
        assertFalse(registry.isOwnerOrOperator(id, bob));
        assertFalse(registry.isOwnerOrOperator(id, address(0)));
        vm.prank(alice);
        registry.setApprovalForAll(operator, true);
        assertTrue(registry.isOwnerOrOperator(id, operator));
        vm.prank(alice);
        registry.approve(bob, id);
        assertTrue(registry.isOwnerOrOperator(id, bob));
        assertFalse(registry.isOwnerOrOperator(registry.tokenIdOf("nobody"), alice));
    }

    function test_constants_and_constructor_guards() public {
        assertEq(registry.HANDLE_ROOT(), HANDLE_ROOT);
        assertEq(registry.treasury(), treasury);
        assertEq(address(registry.oracle()), address(oracle));
        assertEq(registry.name(), "arcns handles");
        assertEq(registry.symbol(), "ARCNS");
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(registry.tokenIdOf("alice"), uint256(keccak256("alice")));

        vm.expectRevert(IHandleRegistry.ZeroAddress.selector);
        new HandleRegistry(address(0), treasury, IArcNSPriceOracle(address(oracle)), 0);
        vm.expectRevert(IHandleRegistry.ZeroAddress.selector);
        new HandleRegistry(admin, address(0), IArcNSPriceOracle(address(oracle)), 0);
        vm.expectRevert(IHandleRegistry.ZeroAddress.selector);
        new HandleRegistry(admin, treasury, IArcNSPriceOracle(address(0)), 0);
    }

    // ---- metadata (T-NFT-5) -------------------------------------------------------------------------

    function test_tokenURI_json_decodes() public {
        uint256 id = _register("alice", alice);
        string memory json = _decodeJson(registry.tokenURI(id));
        assertTrue(vm.contains(json, '"name":"@alice"'));
        assertEq(vm.parseJsonString(json, ".name"), "@alice");
        assertEq(vm.parseJsonString(json, ".attributes[0].trait_type"), "namespace");
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "handle");
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), 5);
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), "Human");
        assertEq(vm.parseJsonString(json, ".attributes[3].value"), "no");
        assertEq(vm.parseJsonString(json, ".attributes[4].value"), "no");
        assertEq(vm.parseJsonUint(json, ".attributes[5].value"), 1);
        string memory image = vm.parseJsonString(json, ".image");
        string memory svg = string(Base64Decoder.decodeDataUri(image));
        assertTrue(vm.contains(svg, "<svg"));
        assertTrue(vm.contains(svg, ">@alice</text>"));
        assertTrue(vm.contains(svg, "#3b82f6"));

        _tokenize(id, alice);
        vm.prank(alice);
        registry.lock(id);
        json = _decodeJson(registry.tokenURI(id));
        assertEq(vm.parseJsonString(json, ".attributes[3].value"), "yes");
        assertEq(vm.parseJsonString(json, ".attributes[4].value"), "yes");
    }

    function test_contractURI_json_decodes() public view {
        string memory json = _decodeJson(registry.contractURI());
        assertEq(vm.parseJsonString(json, ".name"), "arcns handles");
        assertTrue(bytes(vm.parseJsonString(json, ".image")).length > 0);
    }

    function test_tokenURI_type_names() public {
        string[4] memory names = ["alice", "bob", "carol", "dave"];
        string[4] memory types = ["Human", "Merchant", "Org", "Agent"];
        for (uint8 t = 0; t < 4; t++) {
            vm.prank(registrar);
            uint256 id = registry.register(names[t], alice, t, false);
            string memory json = _decodeJson(registry.tokenURI(id));
            assertEq(vm.parseJsonString(json, ".attributes[2].value"), types[t]);
        }
    }

    // ---- value handling / interfaces / pausability (SR-36, SR-62, T-GAS-1) --------------------------

    function test_receive_and_fallback_revert() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, bytes memory data) = address(registry).call{value: 1}("");
        assertFalse(ok);
        assertEq(bytes4(data), IHandleRegistry.ValueNotAccepted.selector);

        vm.prank(alice);
        (ok, data) = address(registry).call{value: 1}(hex"deadbeef");
        assertFalse(ok);
        assertEq(bytes4(data), IHandleRegistry.ValueNotAccepted.selector);

        // value to a non-payable function is rejected by the ABI guard
        uint256 id = _register("alice", alice);
        vm.prank(alice);
        (ok,) = address(registry).call{value: 1}(abi.encodeWithSelector(registry.lock.selector, id));
        assertFalse(ok);
        assertEq(address(registry).balance, 0);
    }

    function test_no_pausable_surface() public {
        (bool ok, bytes memory data) = address(registry).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok);
        assertEq(bytes4(data), IHandleRegistry.ValueNotAccepted.selector, "no pause() selector: fallback hit");
        (ok, data) = address(registry).call(abi.encodeWithSignature("paused()"));
        assertFalse(ok);
        (ok, data) = address(registry).call(abi.encodeWithSignature("unpause()"));
        assertFalse(ok);
    }

    function test_supportsInterface() public view {
        assertTrue(registry.supportsInterface(0x01ffc9a7), "ERC165");
        assertTrue(registry.supportsInterface(0x80ac58cd), "ERC721");
        assertTrue(registry.supportsInterface(0x5b5e139f), "ERC721Metadata");
        assertTrue(registry.supportsInterface(0x7965db0b), "AccessControl");
        assertTrue(registry.supportsInterface(0x49064906), "ERC4906");
        assertFalse(registry.supportsInterface(0xffffffff));
        assertFalse(registry.supportsInterface(0x780e9d63), "not enumerable");
    }
}
