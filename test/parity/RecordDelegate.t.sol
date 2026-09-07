// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {RecordDelegate} from "../../src/parity/RecordDelegate.sol";
import {IRecordDelegate} from "../../src/interfaces/IRecordDelegate.sol";
import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @notice Unit tests for `RecordDelegate` (WP-126): single active record delegate per
///         `(collection, tokenId)`, epoch-gated via `EpochGuard`, ported from x1-handles
///         `set_record_delegate`/`revoke_record_delegate`.
contract RecordDelegateTest is Test {
    uint256 internal constant T0 = 1_700_000_000;
    uint256 internal constant TOKEN_ID = 1;

    RecordDelegate internal rd;
    MockERC721 internal nft;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal operator = makeAddr("operator");

    // HandleRegistry fixture (epoch-precision path).
    HandleRegistry internal registry;
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal registrar = makeAddr("registrar");
    uint256 internal handleId;

    function setUp() public {
        vm.warp(T0);
        rd = new RecordDelegate();
        nft = new MockERC721();
        nft.mint(alice, TOKEN_ID);

        // Oracle is never called by `register`/`transfer` — a non-zero placeholder is enough.
        registry = new HandleRegistry(admin, treasury, IArcNSPriceOracle(address(0xBEEF)), 7 days);
        vm.prank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, registrar);
        vm.prank(registrar);
        handleId = registry.register("alice", alice, uint8(IHandleRegistry.HandleType.Human), false);
    }

    // ---- setDelegate ------------------------------------------------------------------------------

    function test_setDelegate_byOwner_setsAndEmits() public {
        vm.expectEmit(true, true, true, true, address(rd));
        emit IRecordDelegate.DelegateSet(address(nft), TOKEN_ID, bob);
        vm.prank(alice);
        rd.setDelegate(address(nft), TOKEN_ID, bob);

        assertEq(rd.delegateOf(address(nft), TOKEN_ID), bob);
        assertTrue(rd.isActiveDelegate(address(nft), TOKEN_ID, bob));
        assertFalse(rd.isActiveDelegate(address(nft), TOKEN_ID, carol));

        IRecordDelegate.Delegation memory d = rd.delegationOf(address(nft), TOKEN_ID);
        assertEq(d.delegate, bob);
        assertEq(d.ownerAtDelegation, alice);
        assertEq(d.epochAtDelegation, 0); // MockERC721 has no epochOf → sentinel 0
        assertEq(d.delegatedAt, T0);
    }

    function test_setDelegate_byApprovedOperator_succeeds() public {
        vm.prank(alice);
        nft.setApprovalForAll(operator, true);
        vm.prank(operator);
        rd.setDelegate(address(nft), TOKEN_ID, bob);
        assertEq(rd.delegateOf(address(nft), TOKEN_ID), bob);
    }

    function test_setDelegate_byTokenApprovedOperator_succeeds() public {
        vm.prank(alice);
        nft.approve(operator, TOKEN_ID);
        vm.prank(operator);
        rd.setDelegate(address(nft), TOKEN_ID, bob);
        assertEq(rd.delegateOf(address(nft), TOKEN_ID), bob);
    }

    function test_setDelegate_revertsForStranger() public {
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IRecordDelegate.NotCurrentAuthority.selector, address(nft), TOKEN_ID, carol)
        );
        rd.setDelegate(address(nft), TOKEN_ID, bob);
    }

    function test_setDelegate_revertsOnZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(IRecordDelegate.ZeroAddress.selector);
        rd.setDelegate(address(nft), TOKEN_ID, address(0));
    }

    function test_setDelegate_revertsOnSelfDelegation() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRecordDelegate.SelfDelegation.selector, address(nft), TOKEN_ID));
        rd.setDelegate(address(nft), TOKEN_ID, alice);
    }

    function test_setDelegate_revertsWhileActiveDelegationExists() public {
        vm.startPrank(alice);
        rd.setDelegate(address(nft), TOKEN_ID, bob);
        vm.expectRevert(abi.encodeWithSelector(IRecordDelegate.DelegationActive.selector, address(nft), TOKEN_ID, bob));
        rd.setDelegate(address(nft), TOKEN_ID, carol);
        vm.stopPrank();
    }

    function test_setDelegate_allowedOnceExistingDelegationIsRevoked() public {
        vm.startPrank(alice);
        rd.setDelegate(address(nft), TOKEN_ID, bob);
        rd.revokeDelegate(address(nft), TOKEN_ID);
        rd.setDelegate(address(nft), TOKEN_ID, carol);
        vm.stopPrank();
        assertEq(rd.delegateOf(address(nft), TOKEN_ID), carol);
    }

    // ---- revokeDelegate ---------------------------------------------------------------------------

    function test_revokeDelegate_byOwner_clearsAndEmits() public {
        vm.startPrank(alice);
        rd.setDelegate(address(nft), TOKEN_ID, bob);
        vm.expectEmit(true, true, true, true, address(rd));
        emit IRecordDelegate.DelegateRevoked(address(nft), TOKEN_ID, bob);
        rd.revokeDelegate(address(nft), TOKEN_ID);
        vm.stopPrank();
        assertEq(rd.delegateOf(address(nft), TOKEN_ID), address(0));
    }

    function test_revokeDelegate_revertsWhenNoActiveDelegation() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRecordDelegate.NoActiveDelegation.selector, address(nft), TOKEN_ID));
        rd.revokeDelegate(address(nft), TOKEN_ID);
    }

    /// @dev "The delegate itself cannot revoke or renounce" (interface NatSpec) — bob is neither the
    ///      owner nor an approved operator, so he fails the same authority check anyone else would.
    function test_revokeDelegate_delegateItselfCannotRevoke() public {
        vm.prank(alice);
        rd.setDelegate(address(nft), TOKEN_ID, bob);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IRecordDelegate.NotCurrentAuthority.selector, address(nft), TOKEN_ID, bob)
        );
        rd.revokeDelegate(address(nft), TOKEN_ID);
    }

    // ---- epoch-gated auto-invalidation: MockERC721 (owner-address precision) -----------------------

    function test_ownerTransfer_onPlainErc721_autoInvalidatesDelegate_noExplicitRevoke() public {
        vm.prank(alice);
        rd.setDelegate(address(nft), TOKEN_ID, bob);
        assertEq(rd.delegateOf(address(nft), TOKEN_ID), bob);

        vm.prank(alice);
        nft.transferFrom(alice, carol, TOKEN_ID);

        // No explicit revoke call — staleness is caught purely at read time via EpochGuard.
        assertEq(rd.delegateOf(address(nft), TOKEN_ID), address(0));
        assertFalse(rd.isActiveDelegate(address(nft), TOKEN_ID, bob));

        // The raw struct is still readable (debugging/UI), just not treated as active.
        IRecordDelegate.Delegation memory raw = rd.delegationOf(address(nft), TOKEN_ID);
        assertEq(raw.delegate, bob);
        assertEq(raw.ownerAtDelegation, alice);

        // The old owner has lost authority entirely.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IRecordDelegate.NotCurrentAuthority.selector, address(nft), TOKEN_ID, alice)
        );
        rd.revokeDelegate(address(nft), TOKEN_ID);

        // The new owner can set a fresh delegate without hitting DelegationActive (the old one is
        // stale, not active).
        vm.prank(carol);
        rd.setDelegate(address(nft), TOKEN_ID, bob);
        assertEq(rd.delegateOf(address(nft), TOKEN_ID), bob);
    }

    // ---- epoch-gated auto-invalidation: HandleRegistry (epoch precision) ----------------------------

    function test_handleTransfer_bumpsEpoch_autoInvalidatesDelegate() public {
        vm.prank(alice);
        rd.setDelegate(address(registry), handleId, bob);
        assertEq(rd.delegateOf(address(registry), handleId), bob);

        vm.prank(alice);
        registry.transfer(handleId, carol); // owner-initiated move; bumps epoch (SR-12)

        assertEq(rd.delegateOf(address(registry), handleId), address(0));
        assertFalse(rd.isActiveDelegate(address(registry), handleId, bob));

        // New owner can grant a fresh delegate immediately.
        vm.prank(carol);
        rd.setDelegate(address(registry), handleId, bob);
        assertEq(rd.delegateOf(address(registry), handleId), bob);
    }

    function test_revokeDelegate_worksOnStaleDelegation_byNewOwner() public {
        vm.prank(alice);
        rd.setDelegate(address(registry), handleId, bob);
        vm.prank(alice);
        registry.transfer(handleId, carol);

        // The stale delegation is not "active" per delegateOf, so an explicit revoke by the new
        // owner still correctly reports NoActiveDelegation — there is nothing live to revoke.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IRecordDelegate.NoActiveDelegation.selector, address(registry), handleId)
        );
        rd.revokeDelegate(address(registry), handleId);
    }
}
