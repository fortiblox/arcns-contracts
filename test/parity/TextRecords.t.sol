// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {TextRecords} from "../../src/parity/TextRecords.sol";
import {ITextRecords} from "../../src/interfaces/ITextRecords.sol";
import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @notice Unit tests for `TextRecords` (WP-127): create/update/close text records with an
///         informational live-record counter, epoch-gated via `EpochGuard`, ported from x1-handles
///         `create_text_record`/`update_text_record`/`close_text_record`.
contract TextRecordsTest is Test {
    uint256 internal constant T0 = 1_700_000_000;
    uint256 internal constant TOKEN_ID = 1;
    string internal constant KEY = "avatar";
    string internal constant VALUE = "ipfs://cid-1";

    TextRecords internal tr;
    MockERC721 internal nft;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal operator = makeAddr("operator");

    HandleRegistry internal registry;
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal registrar = makeAddr("registrar");
    uint256 internal handleId;

    function setUp() public {
        vm.warp(T0);
        tr = new TextRecords();
        nft = new MockERC721();
        nft.mint(alice, TOKEN_ID);

        registry = new HandleRegistry(admin, treasury, IArcNSPriceOracle(address(0xBEEF)), 7 days);
        vm.prank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, registrar);
        vm.prank(registrar);
        handleId = registry.register("alice", alice, uint8(IHandleRegistry.HandleType.Human), false);
    }

    // ---- createTextRecord ---------------------------------------------------------------------------

    function test_create_setsValue_countsRecord_andEmits() public {
        vm.expectEmit(true, true, true, true, address(tr));
        emit ITextRecords.TextRecordCreated(address(nft), TOKEN_ID, KEY, VALUE);
        vm.prank(alice);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, VALUE);

        assertEq(tr.textOf(address(nft), TOKEN_ID, KEY), VALUE);
        assertTrue(tr.exists(address(nft), TOKEN_ID, KEY));
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 1);
    }

    function test_create_revertsOnEmptyKey() public {
        vm.prank(alice);
        vm.expectRevert(ITextRecords.EmptyKey.selector);
        tr.createTextRecord(address(nft), TOKEN_ID, "", VALUE);
    }

    function test_create_revertsForStranger() public {
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ITextRecords.NotCurrentAuthority.selector, address(nft), TOKEN_ID, carol)
        );
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, VALUE);
    }

    function test_create_byApprovedOperator_succeeds() public {
        vm.prank(alice);
        nft.setApprovalForAll(operator, true);
        vm.prank(operator);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, VALUE);
        assertTrue(tr.exists(address(nft), TOKEN_ID, KEY));
    }

    function test_create_revertsWhenLiveRecordAlreadyExists() public {
        vm.startPrank(alice);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, VALUE);
        bytes32 keyHash = keccak256(bytes(KEY));
        vm.expectRevert(abi.encodeWithSelector(ITextRecords.RecordExists.selector, address(nft), TOKEN_ID, keyHash));
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, "other-value");
        vm.stopPrank();
    }

    /// @dev A stale existing record (name changed hands since) is silently overwritten by a fresh
    ///      create — no explicit close needed, matching the interface's promised behavior.
    function test_create_overwritesStaleRecord_silently() public {
        vm.prank(alice);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, VALUE);

        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ID); // record for KEY is now stale

        assertEq(tr.textOf(address(nft), TOKEN_ID, KEY), ""); // reads as empty
        assertFalse(tr.exists(address(nft), TOKEN_ID, KEY));

        string memory newValue = "ipfs://cid-2";
        vm.prank(bob);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, newValue); // no revert — stale, not live

        assertEq(tr.textOf(address(nft), TOKEN_ID, KEY), newValue);
        assertTrue(tr.exists(address(nft), TOKEN_ID, KEY));
    }

    // ---- updateTextRecord ---------------------------------------------------------------------------

    function test_update_changesValue_keepsSnapshot_andEmits() public {
        vm.startPrank(alice);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, VALUE);
        vm.warp(T0 + 100);
        string memory newValue = "ipfs://cid-updated";
        vm.expectEmit(true, true, true, true, address(tr));
        emit ITextRecords.TextRecordUpdated(address(nft), TOKEN_ID, KEY, newValue);
        tr.updateTextRecord(address(nft), TOKEN_ID, KEY, newValue);
        vm.stopPrank();
        assertEq(tr.textOf(address(nft), TOKEN_ID, KEY), newValue);
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 1); // update never touches the counter
    }

    function test_update_revertsWhenRecordNeverCreated() public {
        bytes32 keyHash = keccak256(bytes(KEY));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITextRecords.RecordNotFound.selector, address(nft), TOKEN_ID, keyHash));
        tr.updateTextRecord(address(nft), TOKEN_ID, KEY, VALUE);
    }

    /// @dev A stale record is not updatable — only recreatable via `createTextRecord`.
    function test_update_revertsOnStaleRecord() public {
        vm.prank(alice);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, VALUE);
        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ID);

        bytes32 keyHash = keccak256(bytes(KEY));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ITextRecords.RecordNotFound.selector, address(nft), TOKEN_ID, keyHash));
        tr.updateTextRecord(address(nft), TOKEN_ID, KEY, "new-value");
    }

    function test_update_revertsForStranger() public {
        vm.prank(alice);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, VALUE);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ITextRecords.NotCurrentAuthority.selector, address(nft), TOKEN_ID, carol)
        );
        tr.updateTextRecord(address(nft), TOKEN_ID, KEY, "x");
    }

    // ---- closeTextRecord ---------------------------------------------------------------------------

    function test_close_deletesRecord_decrementsCount_andEmits() public {
        vm.startPrank(alice);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, VALUE);
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 1);

        vm.expectEmit(true, true, true, true, address(tr));
        emit ITextRecords.TextRecordClosed(address(nft), TOKEN_ID, KEY);
        tr.closeTextRecord(address(nft), TOKEN_ID, KEY);
        vm.stopPrank();

        assertFalse(tr.exists(address(nft), TOKEN_ID, KEY));
        assertEq(tr.textOf(address(nft), TOKEN_ID, KEY), "");
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 0);
    }

    function test_close_revertsWhenNeverCreated() public {
        bytes32 keyHash = keccak256(bytes(KEY));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITextRecords.RecordNotFound.selector, address(nft), TOKEN_ID, keyHash));
        tr.closeTextRecord(address(nft), TOKEN_ID, KEY);
    }

    function test_close_revertsWhenAlreadyClosed() public {
        vm.startPrank(alice);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, VALUE);
        tr.closeTextRecord(address(nft), TOKEN_ID, KEY);
        bytes32 keyHash = keccak256(bytes(KEY));
        vm.expectRevert(abi.encodeWithSelector(ITextRecords.RecordNotFound.selector, address(nft), TOKEN_ID, keyHash));
        tr.closeTextRecord(address(nft), TOKEN_ID, KEY);
        vm.stopPrank();
    }

    /// @dev Closing a stale record is fine — it's just cleanup. New owner does the closing here.
    function test_close_worksOnStaleRecord_byNewOwner() public {
        vm.prank(alice);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, VALUE);
        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ID);

        vm.prank(bob);
        tr.closeTextRecord(address(nft), TOKEN_ID, KEY);
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 0);
    }

    function test_close_revertsForStranger() public {
        vm.prank(alice);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, VALUE);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ITextRecords.NotCurrentAuthority.selector, address(nft), TOKEN_ID, carol)
        );
        tr.closeTextRecord(address(nft), TOKEN_ID, KEY);
    }

    // ---- recordCountOf: the trickiest edge case — no underflow across churn -------------------------

    /// @dev The exact sequence called out in the brief: create → (external transfer makes it stale)
    ///      → close → create → close. Must never underflow (`uint32` arithmetic would revert with a
    ///      Solidity panic on underflow — this test proves it never gets there) and must land back at
    ///      zero once every physically-created slot has been closed.
    function test_recordCount_survivesCreateStaleCloseCreateClose_withoutUnderflow() public {
        vm.prank(alice);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, VALUE);
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 1);

        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ID); // stale now, count still 1 (no hook to decrement)
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 1);

        vm.prank(bob);
        tr.closeTextRecord(address(nft), TOKEN_ID, KEY); // closing a stale record is fine
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 0);

        vm.prank(bob);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, "ipfs://cid-3");
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 1);

        vm.prank(bob);
        tr.closeTextRecord(address(nft), TOKEN_ID, KEY);
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 0);
    }

    /// @dev Independent multi-key stress of the same invariant: several keys created, some closed
    ///      while stale after a transfer, some recreated after — count must track the number of
    ///      physically-present slots at every step and never underflow.
    function test_recordCount_multiKey_neverUnderflows() public {
        vm.startPrank(alice);
        tr.createTextRecord(address(nft), TOKEN_ID, "k1", "v1");
        tr.createTextRecord(address(nft), TOKEN_ID, "k2", "v2");
        tr.createTextRecord(address(nft), TOKEN_ID, "k3", "v3");
        vm.stopPrank();
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 3);

        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ID); // all three go stale at once, count still 3

        vm.startPrank(bob);
        tr.closeTextRecord(address(nft), TOKEN_ID, "k1");
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 2);
        tr.closeTextRecord(address(nft), TOKEN_ID, "k2");
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 1);
        tr.closeTextRecord(address(nft), TOKEN_ID, "k3");
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 0);
        vm.stopPrank();
    }

    /// @dev Documented, accepted limitation of an informational, no-enumeration counter (see
    ///      `TextRecords` contract NatSpec): a stale-overwrite create (no intervening close)
    ///      increments again, so `recordCountOf` can overcount relative to true live records until
    ///      the key is finally closed. Never an underflow — just an accepted imprecision.
    function test_recordCount_documentedOvercount_onRepeatedStaleOverwriteWithoutClose() public {
        vm.prank(alice);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, VALUE);
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 1);

        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ID); // stale
        vm.prank(bob);
        tr.createTextRecord(address(nft), TOKEN_ID, KEY, "ipfs://cid-2"); // overwrite w/o close

        // Only one physical slot exists, but the counter reports 2 — the documented overcount.
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 2);
        assertTrue(tr.exists(address(nft), TOKEN_ID, KEY));

        vm.prank(bob);
        tr.closeTextRecord(address(nft), TOKEN_ID, KEY);
        assertEq(tr.recordCountOf(address(nft), TOKEN_ID), 1); // stuck at 1, never negative
    }

    // ---- epoch precision via HandleRegistry ----------------------------------------------------------

    function test_handleTransfer_bumpsEpoch_autoInvalidatesTextRecord() public {
        vm.prank(alice);
        tr.createTextRecord(address(registry), handleId, KEY, VALUE);
        assertTrue(tr.exists(address(registry), handleId, KEY));

        vm.prank(alice);
        registry.transfer(handleId, carol); // bumps epoch (SR-12), same owner-address wouldn't be enough

        assertEq(tr.textOf(address(registry), handleId, KEY), "");
        assertFalse(tr.exists(address(registry), handleId, KEY));

        vm.prank(carol);
        tr.createTextRecord(address(registry), handleId, KEY, "ipfs://cid-new");
        assertEq(tr.textOf(address(registry), handleId, KEY), "ipfs://cid-new");
    }
}
