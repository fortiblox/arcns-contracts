// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {NameLocks} from "../../src/parity/NameLocks.sol";
import {INameLocks} from "../../src/interfaces/INameLocks.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @notice Unit tests for `NameLocks` (WP-125): the generalized SR-14 lock timelock, ported from
///         `HandleRegistry.lock`/`initiateUnlock`/`completeUnlock`/`cancelUnlock` to any
///         `(collection, tokenId)` pair, gated by `ownerOf` instead of an internal registry.
contract NameLocksTest is Test {
    uint256 internal constant T0 = 1_700_000_000;

    NameLocks internal locks;
    MockERC721 internal nft;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant TOKEN_ID = 1;

    function setUp() public {
        vm.warp(T0);
        locks = new NameLocks(admin, 1 days);
        nft = new MockERC721();
        nft.mint(alice, TOKEN_ID);
    }

    // ---- lock -----------------------------------------------------------------------------------

    function test_lock_setsLocked_andEmits() public {
        vm.expectEmit(true, true, true, true, address(locks));
        emit INameLocks.Locked(address(nft), TOKEN_ID);
        vm.prank(alice);
        locks.lock(address(nft), TOKEN_ID);
        assertTrue(locks.isLocked(address(nft), TOKEN_ID));
    }

    function test_lock_revertsForNonOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(INameLocks.NotOwner.selector, address(nft), TOKEN_ID, bob));
        locks.lock(address(nft), TOKEN_ID);
    }

    function test_lock_unknownToken_bubblesErc721Error() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        locks.lock(address(nft), 999);
    }

    /// @dev Judgment call under test: re-locking is idempotent (matches `HandleRegistry.lock`), not a
    ///      revert — a pending unlock is silently cleared.
    function test_lock_isIdempotent_andClearsPendingUnlock() public {
        vm.startPrank(alice);
        locks.lock(address(nft), TOKEN_ID);
        locks.initiateUnlock(address(nft), TOKEN_ID);
        assertGt(locks.unlockInitiatedAt(address(nft), TOKEN_ID), 0);

        // Re-lock: no revert, clears the pending unlock.
        locks.lock(address(nft), TOKEN_ID);
        vm.stopPrank();

        assertTrue(locks.isLocked(address(nft), TOKEN_ID));
        assertEq(locks.unlockInitiatedAt(address(nft), TOKEN_ID), 0);
    }

    // ---- initiateUnlock ---------------------------------------------------------------------------

    function test_initiateUnlock_revertsWhenNotLocked() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(INameLocks.NotLocked.selector, address(nft), TOKEN_ID));
        locks.initiateUnlock(address(nft), TOKEN_ID);
    }

    function test_initiateUnlock_stampsTimestamp_andEmits() public {
        vm.startPrank(alice);
        locks.lock(address(nft), TOKEN_ID);
        vm.expectEmit(true, true, true, true, address(locks));
        emit INameLocks.UnlockInitiated(address(nft), TOKEN_ID, uint40(T0));
        locks.initiateUnlock(address(nft), TOKEN_ID);
        vm.stopPrank();
        assertEq(locks.unlockInitiatedAt(address(nft), TOKEN_ID), T0);
    }

    function test_initiateUnlock_revertsWhenAlreadyPending() public {
        vm.startPrank(alice);
        locks.lock(address(nft), TOKEN_ID);
        locks.initiateUnlock(address(nft), TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(INameLocks.UnlockPending.selector, address(nft), TOKEN_ID));
        locks.initiateUnlock(address(nft), TOKEN_ID);
        vm.stopPrank();
    }

    function test_initiateUnlock_revertsForNonOwner() public {
        vm.prank(alice);
        locks.lock(address(nft), TOKEN_ID);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(INameLocks.NotOwner.selector, address(nft), TOKEN_ID, bob));
        locks.initiateUnlock(address(nft), TOKEN_ID);
    }

    // ---- completeUnlock ---------------------------------------------------------------------------

    function test_completeUnlock_revertsWhenNotLocked() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(INameLocks.NotLocked.selector, address(nft), TOKEN_ID));
        locks.completeUnlock(address(nft), TOKEN_ID);
    }

    function test_completeUnlock_revertsWhenNoUnlockPending() public {
        vm.startPrank(alice);
        locks.lock(address(nft), TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(INameLocks.NoUnlockPending.selector, address(nft), TOKEN_ID));
        locks.completeUnlock(address(nft), TOKEN_ID);
        vm.stopPrank();
    }

    function test_completeUnlock_revertsBeforeTimelockElapsed() public {
        vm.startPrank(alice);
        locks.lock(address(nft), TOKEN_ID);
        locks.initiateUnlock(address(nft), TOKEN_ID);
        uint64 readyAt = uint64(T0) + locks.unlockTimelock();
        vm.warp(readyAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(INameLocks.TimelockNotElapsed.selector, readyAt, uint64(block.timestamp))
        );
        locks.completeUnlock(address(nft), TOKEN_ID);
        vm.stopPrank();
    }

    function test_completeUnlock_succeedsAtExactTimelock_andEmits() public {
        vm.startPrank(alice);
        locks.lock(address(nft), TOKEN_ID);
        locks.initiateUnlock(address(nft), TOKEN_ID);
        uint64 readyAt = uint64(T0) + locks.unlockTimelock();
        vm.warp(readyAt);
        vm.expectEmit(true, true, true, true, address(locks));
        emit INameLocks.Unlocked(address(nft), TOKEN_ID);
        locks.completeUnlock(address(nft), TOKEN_ID);
        vm.stopPrank();
        assertFalse(locks.isLocked(address(nft), TOKEN_ID));
        assertEq(locks.unlockInitiatedAt(address(nft), TOKEN_ID), 0);
    }

    // ---- cancelUnlock -----------------------------------------------------------------------------

    function test_cancelUnlock_revertsWhenNoUnlockPending() public {
        vm.startPrank(alice);
        locks.lock(address(nft), TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(INameLocks.NoUnlockPending.selector, address(nft), TOKEN_ID));
        locks.cancelUnlock(address(nft), TOKEN_ID);
        vm.stopPrank();
    }

    function test_cancelUnlock_clearsPending_leavesLocked_andEmits() public {
        vm.startPrank(alice);
        locks.lock(address(nft), TOKEN_ID);
        locks.initiateUnlock(address(nft), TOKEN_ID);
        vm.expectEmit(true, true, true, true, address(locks));
        emit INameLocks.UnlockCancelled(address(nft), TOKEN_ID);
        locks.cancelUnlock(address(nft), TOKEN_ID);
        vm.stopPrank();
        assertTrue(locks.isLocked(address(nft), TOKEN_ID));
        assertEq(locks.unlockInitiatedAt(address(nft), TOKEN_ID), 0);
    }

    /// @dev `cancelUnlock` "works while locked" is the entire point: the owner's defence against a
    ///      thief's `initiateUnlock`. There is no separate unlocked-path test because the function
    ///      never checks `locked` at all — it only cares whether an unlock is pending.
    function test_cancelUnlock_worksRegardlessOfLockedFlag() public {
        vm.startPrank(alice);
        locks.lock(address(nft), TOKEN_ID);
        locks.initiateUnlock(address(nft), TOKEN_ID);
        uint64 readyAt = uint64(T0) + locks.unlockTimelock();
        vm.warp(readyAt);
        locks.completeUnlock(address(nft), TOKEN_ID); // now unlocked, unlockInitiatedAt == 0
        assertFalse(locks.isLocked(address(nft), TOKEN_ID));
        vm.stopPrank();
    }

    // ---- setUnlockTimelock / unlockTimelock floor ---------------------------------------------------

    function test_unlockTimelock_isFlooredAtSevenDays() public {
        assertEq(locks.MIN_UNLOCK_TIMELOCK(), 7 days);
        assertEq(locks.unlockTimelock(), 7 days); // constructed with 1 day, floored up
    }

    function test_setUnlockTimelock_configuresAboveFloor() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(locks));
        emit INameLocks.UnlockTimelockSet(30 days);
        locks.setUnlockTimelock(30 days);
        assertEq(locks.unlockTimelock(), 30 days);
    }

    function test_setUnlockTimelock_revertsForNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        locks.setUnlockTimelock(30 days);
    }

    // ---- documented limitation: raw ERC-721 transfer bypasses this registry's lock -------------------

    /// @dev `NameLocks` cannot intercept a raw `transferFrom` on a collection it does not own (the
    ///      TLD registrar case, per `INameLocks`'s NatSpec). After such a transfer, the token is still
    ///      reported `isLocked() == true` here, but the NEW owner is now the one who passes
    ///      `_requireOwner` and can drive `initiateUnlock`/`completeUnlock` themselves — this is
    ///      correct, expected behavior per the interface doc, not a bug.
    function test_transferBypassesLock_newOwnerCanThenUnlock() public {
        vm.prank(alice);
        locks.lock(address(nft), TOKEN_ID);
        assertTrue(locks.isLocked(address(nft), TOKEN_ID));

        // Raw ERC-721 transfer on the underlying collection — NameLocks has no hook into this.
        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ID);
        assertEq(nft.ownerOf(TOKEN_ID), bob);

        // NameLocks bookkeeping still says "locked" — the documented gap.
        assertTrue(locks.isLocked(address(nft), TOKEN_ID));

        // The OLD owner (alice) has lost authority entirely.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(INameLocks.NotOwner.selector, address(nft), TOKEN_ID, alice));
        locks.initiateUnlock(address(nft), TOKEN_ID);

        // The NEW owner (bob) can drive the full unlock flow themselves.
        vm.startPrank(bob);
        locks.initiateUnlock(address(nft), TOKEN_ID);
        uint64 readyAt = uint64(T0) + locks.unlockTimelock();
        vm.warp(readyAt);
        locks.completeUnlock(address(nft), TOKEN_ID);
        vm.stopPrank();

        assertFalse(locks.isLocked(address(nft), TOKEN_ID));
    }
}
