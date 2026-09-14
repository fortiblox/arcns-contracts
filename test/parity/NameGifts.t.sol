// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

// Verbatim ens-contracts v1.7.0 registry (OZ 4.9.3 through the `lib/ens-contracts/:` remapping).
import {ENSRegistry} from "@ensdomains/ens-contracts/registry/ENSRegistry.sol";

import {NameGifts} from "../../src/parity/NameGifts.sol";
import {INameGifts} from "../../src/interfaces/INameGifts.sol";
import {NameLocks} from "../../src/parity/NameLocks.sol";
import {INameLocks} from "../../src/interfaces/INameLocks.sol";
import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";
import {TldRegistrar} from "../../src/tld/TldRegistrar.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {MockOracle} from "../handle/mocks/MockOracle.sol";
import {MaliciousNameGiftsCollection} from "./mocks/MaliciousNameGiftsCollection.sol";

/// @notice Unit tests for `NameGifts` (M3b): create/claim/refund lifecycle against BOTH namespaces —
///         a real soulbound `HandleRegistry` handle (proves the `MARKET_ROLE` grant actually works,
///         the test that would have caught a missed role grant) and a real `TldRegistrar` name (the
///         registration-expiry guard's real `nameExpires`) — mirroring `Vouchers.t.sol`'s setUp /
///         `_create` / boundary-testing conventions.
contract NameGiftsTest is Test {
    uint256 internal constant T0 = 1_700_000_000;
    uint64 internal constant MIN_BUFFER = 14 days;

    NameGifts internal gifts;
    NameLocks internal nameLocks;
    HandleRegistry internal handles;
    MockOracle internal oracle;

    ENSRegistry internal ens;
    TldRegistrar internal tld;
    bytes32 internal constant TLD_NODE = keccak256(abi.encodePacked(bytes32(0), keccak256("arc")));

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal registrar = makeAddr("registrar");
    address internal sender = makeAddr("sender");
    address internal recipient = makeAddr("recipient");
    address internal other = makeAddr("other");

    uint256 internal handleId;
    uint256 internal constant TLD_ID = uint256(keccak256("gifted"));

    function setUp() public {
        vm.warp(T0);

        // ---- HandleRegistry (handle namespace, soulbound by default) ----
        oracle = new MockOracle();
        handles = new HandleRegistry(admin, treasury, oracle, 7 days);
        vm.prank(admin);
        handles.grantRole(ArcNSConstants.REGISTRAR_ROLE, registrar);
        vm.prank(registrar);
        handleId = handles.register("gifted", sender, uint8(IHandleRegistry.HandleType.Human), false);

        // ---- TldRegistrar (TLD namespace, plain ERC-721, real nameExpires) ----
        ens = new ENSRegistry();
        tld = new TldRegistrar(ens, TLD_NODE, "arc", address(0), address(this));
        ens.setSubnodeOwner(bytes32(0), keccak256("arc"), address(tld));
        tld.addController(address(this));
        tld.register(TLD_ID, sender, 365 days);

        // ---- NameLocks parity module (TLD-namespace locking) ----
        nameLocks = new NameLocks(admin, 7 days);

        // ---- NameGifts ----
        gifts = new NameGifts(NameGifts.Init({admin: admin, nameLocks: address(nameLocks)}));
        vm.startPrank(admin);
        gifts.setCollectionAllowed(address(handles), true);
        gifts.setCollectionAllowed(address(tld), true);
        vm.stopPrank();

        // ---- Handle-namespace requirement: NameGifts must hold MARKET_ROLE on HandleRegistry ----
        vm.prank(admin);
        handles.grantRole(ArcNSConstants.MARKET_ROLE, address(gifts));

        // ---- Approvals (sender owns both fixtures' tokens) ----
        vm.prank(sender);
        handles.approve(address(gifts), handleId);
        vm.prank(sender);
        tld.approve(address(gifts), TLD_ID);
    }

    // ---- helpers ------------------------------------------------------------------------------

    function _create(address collection, uint256 tokenId, address recip, uint64 expiresAt)
        internal
        returns (uint256 id)
    {
        vm.prank(sender);
        id = gifts.create(collection, tokenId, recip, expiresAt);
    }

    // ---------------------------------------------------------------------------------------------
    // receive/fallback
    // ---------------------------------------------------------------------------------------------

    function test_receive_and_fallback_reject_value() public {
        vm.expectRevert(INameGifts.ValueNotAccepted.selector);
        (bool ok,) = address(gifts).call{value: 1 ether}("");
        ok;

        vm.expectRevert(INameGifts.ValueNotAccepted.selector);
        (bool ok2,) = address(gifts).call{value: 1 ether}(abi.encodeWithSignature("nope()"));
        ok2;
    }

    // ---------------------------------------------------------------------------------------------
    // create — shared / handle-namespace
    // ---------------------------------------------------------------------------------------------

    function test_create_collectionNotAllowed_reverts() public {
        address notAllowed = makeAddr("notAllowed");
        vm.expectRevert(abi.encodeWithSelector(INameGifts.CollectionNotAllowed.selector, notAllowed));
        vm.prank(sender);
        gifts.create(notAllowed, handleId, recipient, uint64(T0 + 1 days));
    }

    function test_create_zeroAddress_recipient_reverts() public {
        vm.expectRevert(INameGifts.ZeroAddress.selector);
        vm.prank(sender);
        gifts.create(address(handles), handleId, address(0), uint64(T0 + 1 days));
    }

    function test_create_notOwner_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(INameGifts.NotOwner.selector, address(handles), handleId, other));
        vm.prank(other);
        gifts.create(address(handles), handleId, recipient, uint64(T0 + 1 days));
    }

    function test_create_notApproved_reverts() public {
        // Fresh handle the sender owns but never approved.
        vm.prank(registrar);
        uint256 id2 = handles.register("unapproved", sender, uint8(IHandleRegistry.HandleType.Human), false);
        vm.expectRevert(abi.encodeWithSelector(INameGifts.NotApproved.selector, address(handles), id2, sender));
        vm.prank(sender);
        gifts.create(address(handles), id2, recipient, uint64(T0 + 1 days));
    }

    function test_create_notApproved_reverts_isApprovedForAll_path_also_satisfies() public {
        vm.prank(registrar);
        uint256 id2 = handles.register("blanket", sender, uint8(IHandleRegistry.HandleType.Human), false);
        vm.prank(sender);
        handles.setApprovalForAll(address(gifts), true);
        // does not revert
        uint256 giftId = _create(address(handles), id2, recipient, uint64(T0 + 1 days));
        assertEq(giftId, gifts.activeGiftId(address(handles), id2));
    }

    function test_create_expiry_in_past_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(INameGifts.ExpiryInPast.selector, uint64(T0), uint64(T0)));
        vm.prank(sender);
        gifts.create(address(handles), handleId, recipient, uint64(T0));

        vm.expectRevert(abi.encodeWithSelector(INameGifts.ExpiryInPast.selector, uint64(T0 - 1), uint64(T0)));
        vm.prank(sender);
        gifts.create(address(handles), handleId, recipient, uint64(T0 - 1));
    }

    /// @dev Native lock (HandleRegistry.lock, SR-14) must block `create`.
    function test_create_handle_locked_reverts() public {
        vm.prank(sender);
        handles.lock(handleId);
        vm.expectRevert(abi.encodeWithSelector(INameGifts.TokenLocked.selector, address(handles), handleId));
        vm.prank(sender);
        gifts.create(address(handles), handleId, recipient, uint64(T0 + 1 days));
    }

    /// @dev Parity `INameLocks` lock (WP-125) must block `create` for a TLD name.
    function test_create_tld_nameLocks_locked_reverts() public {
        vm.prank(sender);
        nameLocks.lock(address(tld), TLD_ID);
        vm.expectRevert(abi.encodeWithSelector(INameGifts.TokenLocked.selector, address(tld), TLD_ID));
        vm.prank(sender);
        gifts.create(address(tld), TLD_ID, recipient, uint64(T0 + 30 days));
    }

    /// @dev HandleRegistry-specific: `create` must not bypass a pending recovery.
    function test_create_handle_recoveryPending_reverts() public {
        address recoveryKey = makeAddr("recoveryKey");
        vm.prank(sender);
        handles.setRecovery(handleId, recoveryKey);
        vm.prank(recoveryKey);
        handles.initiateRecovery(handleId, other);

        vm.expectRevert(abi.encodeWithSelector(IHandleRegistry.RecoveryPending.selector, handleId));
        vm.prank(sender);
        gifts.create(address(handles), handleId, recipient, uint64(T0 + 1 days));
    }

    /// @dev The test that would have caught a missed MARKET_ROLE grant: a soulbound (non-tokenized)
    ///      handle must actually move into escrow.
    function test_create_handle_succeeds_soulbound_and_emits() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        assertFalse(handles.isLocked(handleId));

        vm.expectEmit(true, true, true, true, address(gifts));
        emit INameGifts.GiftCreated(1, address(handles), handleId, sender, recipient, expiresAt);
        uint256 id = _create(address(handles), handleId, recipient, expiresAt);

        assertEq(id, 1);
        assertEq(gifts.nextGiftId(), 2);
        assertEq(gifts.activeGiftId(address(handles), handleId), 1);
        assertEq(handles.ownerOf(handleId), address(gifts), "MARKET_ROLE grant must let escrow pull a soulbound handle");

        INameGifts.Gift memory g = gifts.giftOf(1);
        assertEq(g.collection, address(handles));
        assertEq(g.tokenId, handleId);
        assertEq(g.sender, sender);
        assertEq(g.recipient, recipient);
        assertEq(g.expiresAt, expiresAt);
        assertFalse(g.claimed);
        assertFalse(g.refunded);
    }

    /// @dev HandleRegistry has no `nameExpires` — the registration-expiry staticcall probe degrades
    ///      to a no-op, so even a far-future `expiresAt` (which would fail the TLD check) succeeds.
    function test_create_handle_ignores_registration_expiry_guard() public {
        uint64 farFuture = uint64(T0 + 3650 days);
        uint256 id = _create(address(handles), handleId, recipient, farFuture);
        assertEq(gifts.giftOf(id).expiresAt, farFuture);
    }

    // ---------------------------------------------------------------------------------------------
    // create — TLD namespace
    // ---------------------------------------------------------------------------------------------

    function test_create_tld_succeeds_plain_erc721() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        vm.expectEmit(true, true, true, true, address(gifts));
        emit INameGifts.GiftCreated(1, address(tld), TLD_ID, sender, recipient, expiresAt);
        uint256 id = _create(address(tld), TLD_ID, recipient, expiresAt);

        assertEq(id, 1);
        assertEq(tld.ownerOf(TLD_ID), address(gifts));
        assertEq(gifts.activeGiftId(address(tld), TLD_ID), 1);
    }

    function test_create_tld_expiryTooCloseToRegistrationExpiry_reverts() public {
        uint256 nameExpiresAt = tld.nameExpires(TLD_ID);
        uint64 tooClose = uint64(nameExpiresAt - MIN_BUFFER + 1); // buffer check is `+ buffer > nameExpiresAt`
        vm.expectRevert(
            abi.encodeWithSelector(INameGifts.ExpiryTooCloseToRegistrationExpiry.selector, tooClose, nameExpiresAt)
        );
        vm.prank(sender);
        gifts.create(address(tld), TLD_ID, recipient, tooClose);
    }

    function test_create_tld_expiry_exactly_at_boundary_minus_one_second_succeeds() public {
        uint256 nameExpiresAt = tld.nameExpires(TLD_ID);
        uint64 atBoundary = uint64(nameExpiresAt - MIN_BUFFER); // expiresAt + buffer == nameExpiresAt: NOT > , succeeds
        uint256 id = _create(address(tld), TLD_ID, recipient, atBoundary);
        assertEq(gifts.giftOf(id).expiresAt, atBoundary);
    }

    // ---------------------------------------------------------------------------------------------
    // claim
    // ---------------------------------------------------------------------------------------------

    function test_claim_unknown_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(INameGifts.GiftUnknown.selector, 999));
        gifts.claim(999);
    }

    function test_claim_notRecipient_reverts() public {
        uint256 id = _create(address(handles), handleId, recipient, uint64(T0 + 1 days));
        vm.expectRevert(abi.encodeWithSelector(INameGifts.NotRecipient.selector, id, other));
        vm.prank(other);
        gifts.claim(id);
    }

    function test_claim_exactly_at_expiry_reverts_expired() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(address(handles), handleId, recipient, expiresAt);
        vm.warp(expiresAt);
        vm.expectRevert(abi.encodeWithSelector(INameGifts.GiftExpired.selector, id, expiresAt));
        vm.prank(recipient);
        gifts.claim(id);
    }

    function test_claim_one_second_before_expiry_succeeds() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(address(handles), handleId, recipient, expiresAt);
        vm.warp(expiresAt - 1);
        vm.prank(recipient);
        gifts.claim(id);
        assertEq(handles.ownerOf(handleId), recipient);
    }

    function test_claim_handle_succeeds_transfers_and_clears_and_emits() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(address(handles), handleId, recipient, expiresAt);

        vm.expectEmit(true, true, true, true, address(gifts));
        emit INameGifts.GiftClaimed(id, recipient);
        vm.prank(recipient);
        gifts.claim(id);

        assertEq(handles.ownerOf(handleId), recipient);
        assertEq(gifts.activeGiftId(address(handles), handleId), 0);
        INameGifts.Gift memory g = gifts.giftOf(id);
        assertTrue(g.claimed);
        assertFalse(g.refunded);
    }

    function test_claim_tld_succeeds_transfers_and_clears() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(address(tld), TLD_ID, recipient, expiresAt);

        vm.expectEmit(true, true, true, true, address(gifts));
        emit INameGifts.GiftClaimed(id, recipient);
        vm.prank(recipient);
        gifts.claim(id);

        assertEq(tld.ownerOf(TLD_ID), recipient);
        assertEq(gifts.activeGiftId(address(tld), TLD_ID), 0);
    }

    function test_double_claim_reverts() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(address(handles), handleId, recipient, expiresAt);
        vm.prank(recipient);
        gifts.claim(id);

        vm.expectRevert(abi.encodeWithSelector(INameGifts.AlreadyClaimed.selector, id));
        vm.prank(recipient);
        gifts.claim(id);
    }

    function test_claim_after_refund_reverts_alreadyRefunded() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(address(handles), handleId, recipient, expiresAt);
        vm.warp(expiresAt);
        vm.prank(sender);
        gifts.refund(id);

        vm.expectRevert(abi.encodeWithSelector(INameGifts.AlreadyRefunded.selector, id));
        vm.prank(recipient);
        gifts.claim(id);
    }

    // ---------------------------------------------------------------------------------------------
    // refund
    // ---------------------------------------------------------------------------------------------

    function test_refund_unknown_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(INameGifts.GiftUnknown.selector, 999));
        gifts.refund(999);
    }

    function test_refund_notSender_reverts() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(address(handles), handleId, recipient, expiresAt);
        vm.warp(expiresAt);
        vm.expectRevert(abi.encodeWithSelector(INameGifts.NotSender.selector, id, other));
        vm.prank(other);
        gifts.refund(id);
    }

    function test_refund_before_expiry_reverts_notExpired() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(address(handles), handleId, recipient, expiresAt);
        vm.warp(expiresAt - 1);
        vm.expectRevert(abi.encodeWithSelector(INameGifts.GiftNotExpired.selector, id, expiresAt));
        vm.prank(sender);
        gifts.refund(id);
    }

    function test_refund_exactly_at_expiry_succeeds() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(address(handles), handleId, recipient, expiresAt);
        vm.warp(expiresAt);

        vm.expectEmit(true, true, true, true, address(gifts));
        emit INameGifts.GiftRefunded(id, sender);
        vm.prank(sender);
        gifts.refund(id);

        assertEq(handles.ownerOf(handleId), sender);
        assertEq(gifts.activeGiftId(address(handles), handleId), 0);
        INameGifts.Gift memory g = gifts.giftOf(id);
        assertTrue(g.refunded);
        assertFalse(g.claimed);
    }

    function test_refund_tld_succeeds_returns_to_sender() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(address(tld), TLD_ID, recipient, expiresAt);
        vm.warp(expiresAt);
        vm.prank(sender);
        gifts.refund(id);
        assertEq(tld.ownerOf(TLD_ID), sender);
        assertEq(gifts.activeGiftId(address(tld), TLD_ID), 0);
    }

    function test_refund_after_claim_reverts_alreadyClaimed() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(address(handles), handleId, recipient, expiresAt);
        vm.prank(recipient);
        gifts.claim(id);
        vm.warp(expiresAt);

        vm.expectRevert(abi.encodeWithSelector(INameGifts.AlreadyClaimed.selector, id));
        vm.prank(sender);
        gifts.refund(id);
    }

    function test_double_refund_reverts() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(address(handles), handleId, recipient, expiresAt);
        vm.warp(expiresAt);
        vm.prank(sender);
        gifts.refund(id);

        vm.expectRevert(abi.encodeWithSelector(INameGifts.AlreadyRefunded.selector, id));
        vm.prank(sender);
        gifts.refund(id);
    }

    // ---------------------------------------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------------------------------------

    function test_setCollectionAllowed_admin_only() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, bytes32(0))
        );
        vm.prank(other);
        gifts.setCollectionAllowed(address(handles), true);
    }

    function test_setCollectionAllowed_zeroAddress_reverts() public {
        vm.expectRevert(INameGifts.ZeroAddress.selector);
        vm.prank(admin);
        gifts.setCollectionAllowed(address(0), true);
    }

    function test_setCollectionAllowed_toggles_and_emits() public {
        address c = makeAddr("newCollection");
        vm.expectEmit(true, true, true, true, address(gifts));
        emit INameGifts.CollectionAllowed(c, true);
        vm.prank(admin);
        gifts.setCollectionAllowed(c, true);
        assertTrue(gifts.isCollectionAllowed(c));

        vm.prank(admin);
        gifts.setCollectionAllowed(c, false);
        assertFalse(gifts.isCollectionAllowed(c));
    }

    // ---------------------------------------------------------------------------------------------
    // Reentrancy — nonReentrant must close a malicious collection's reentry attempt
    // ---------------------------------------------------------------------------------------------

    /// @dev Neither `HandleRegistry` (`_mint`, not `_safeMint`) nor `TldRegistrar`
    ///      (`BaseRegistrarImplementation` uses plain OZ4 `ERC721._transfer`, no receiver hook) ever
    ///      invokes an `onERC721Received`-style callback on a plain `transferFrom` — so real gift
    ///      collections cannot themselves trigger a reentrant call into `NameGifts`. The only way a
    ///      collection can call back into this contract mid-transfer is if the *collection itself* is
    ///      malicious (a hostile allow-listed contract), which is exactly what this fixture is: its
    ///      `transferFrom` calls back into `claim`/`refund`/`create` before returning. `nonReentrant`
    ///      must block that reentry — this is the test that would fail without it.
    function test_claim_reentrancy_blocked() public {
        MaliciousNameGiftsCollection evil = new MaliciousNameGiftsCollection();
        evil.mint(sender, 1);
        vm.prank(admin);
        gifts.setCollectionAllowed(address(evil), true);
        vm.prank(sender);
        evil.approve(address(gifts), 1);

        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(address(evil), 1, recipient, expiresAt);

        evil.arm(gifts, id, MaliciousNameGiftsCollection.Reentry.Claim);
        vm.prank(recipient);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        gifts.claim(id);
    }

    function test_refund_reentrancy_blocked() public {
        MaliciousNameGiftsCollection evil = new MaliciousNameGiftsCollection();
        evil.mint(sender, 1);
        vm.prank(admin);
        gifts.setCollectionAllowed(address(evil), true);
        vm.prank(sender);
        evil.approve(address(gifts), 1);

        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(address(evil), 1, recipient, expiresAt);
        vm.warp(expiresAt);

        evil.arm(gifts, id, MaliciousNameGiftsCollection.Reentry.Refund);
        vm.prank(sender);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        gifts.refund(id);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    /// @dev Every allow-listed collection, any future expiry, any recipient: `create` stores the
    ///      fields verbatim and escrows the exact token.
    function testFuzz_create_stores_exact_fields(uint32 delay, address recipient_, bool useTld) public {
        vm.assume(recipient_ != address(0));
        delay = uint32(bound(delay, 1, 300 days));
        uint64 expiresAt = uint64(T0 + delay);

        address collection = useTld ? address(tld) : address(handles);
        uint256 tokenId = useTld ? TLD_ID : handleId;
        if (useTld) {
            uint256 nameExpiresAt = tld.nameExpires(tokenId);
            vm.assume(uint256(expiresAt) + MIN_BUFFER <= nameExpiresAt);
        }

        uint256 id = _create(collection, tokenId, recipient_, expiresAt);

        INameGifts.Gift memory g = gifts.giftOf(id);
        assertEq(g.collection, collection);
        assertEq(g.tokenId, tokenId);
        assertEq(g.sender, sender);
        assertEq(g.recipient, recipient_);
        assertEq(g.expiresAt, expiresAt);
        assertEq(IERC721(collection).ownerOf(tokenId), address(gifts));
    }

    /// @dev The claim/refund windows are exact complements of `block.timestamp < expiresAt`: for any
    ///      warp target, exactly one of {claim succeeds, refund succeeds} is possible (never both,
    ///      never neither), matching `Vouchers.t.sol`'s equivalent fuzz test.
    function testFuzz_claim_and_refund_windows_are_exact_complements(uint32 delay, uint32 warpTo) public {
        delay = uint32(bound(delay, 1, 300 days));
        uint64 expiresAt = uint64(T0 + delay);
        uint256 id = _create(address(handles), handleId, recipient, expiresAt);
        vm.warp(bound(warpTo, T0, T0 + uint256(delay) + 300 days));

        bool canClaim = block.timestamp < expiresAt;
        if (canClaim) {
            vm.prank(recipient);
            gifts.claim(id);
            assertEq(handles.ownerOf(handleId), recipient);
        } else {
            vm.expectRevert(abi.encodeWithSelector(INameGifts.GiftExpired.selector, id, expiresAt));
            vm.prank(recipient);
            gifts.claim(id);

            vm.prank(sender);
            gifts.refund(id);
            assertEq(handles.ownerOf(handleId), sender);
        }
    }
}
