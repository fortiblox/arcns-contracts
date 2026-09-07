// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Vouchers} from "../../src/parity/Vouchers.sol";
import {IVouchers} from "../../src/interfaces/IVouchers.sol";
import {RevertingReceiver} from "./mocks/RevertingReceiver.sol";

/// @notice Unit tests for `Vouchers` (WP-130): create/claim/refund lifecycle, the exclusive
///         claim-before / refund-at-or-after `expiresAt` boundary, double-action guards, and the
///         pull-ledger safety property for a reverting recipient.
contract VouchersTest is Test {
    Vouchers internal v;

    address internal payer = makeAddr("payer");
    address internal recipient = makeAddr("recipient");
    address internal other = makeAddr("other");

    uint256 internal constant T0 = 1_700_000_000;
    uint256 internal constant AMOUNT = 1 ether;

    function setUp() public {
        vm.warp(T0);
        v = new Vouchers();
        vm.deal(payer, 100 ether);
    }

    function _create(address recip, uint64 expiresAt, uint256 amount) internal returns (uint256 id) {
        vm.prank(payer);
        id = v.create{value: amount}(recip, expiresAt);
    }

    // ---------------------------------------------------------------------------------------------
    // receive/fallback
    // ---------------------------------------------------------------------------------------------

    function test_receive_and_fallback_reject_value() public {
        vm.expectRevert(IVouchers.ValueNotAccepted.selector);
        (bool ok,) = address(v).call{value: 1 ether}("");
        ok; // silence unused-var warning; expectRevert already asserted the revert

        vm.expectRevert(IVouchers.ValueNotAccepted.selector);
        (bool ok2,) = address(v).call{value: 1 ether}(abi.encodeWithSignature("nope()"));
        ok2;
    }

    // ---------------------------------------------------------------------------------------------
    // create
    // ---------------------------------------------------------------------------------------------

    function test_create_zero_address_reverts() public {
        vm.expectRevert(IVouchers.ZeroAddress.selector);
        vm.prank(payer);
        v.create{value: AMOUNT}(address(0), uint64(T0 + 1 days));
    }

    function test_create_zero_amount_reverts() public {
        vm.expectRevert(IVouchers.ZeroAmount.selector);
        vm.prank(payer);
        v.create{value: 0}(recipient, uint64(T0 + 1 days));
    }

    function test_create_expiry_in_past_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IVouchers.ExpiryInPast.selector, uint64(T0), uint64(T0)));
        vm.prank(payer);
        v.create{value: AMOUNT}(recipient, uint64(T0));

        vm.expectRevert(abi.encodeWithSelector(IVouchers.ExpiryInPast.selector, uint64(T0 - 1), uint64(T0)));
        vm.prank(payer);
        v.create{value: AMOUNT}(recipient, uint64(T0 - 1));
    }

    function test_create_stores_and_emits_and_increments_id() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        vm.expectEmit(true, true, true, true, address(v));
        emit IVouchers.VoucherCreated(1, payer, recipient, AMOUNT, expiresAt);
        uint256 id = _create(recipient, expiresAt, AMOUNT);
        assertEq(id, 1);
        assertEq(v.nextVoucherId(), 2);

        IVouchers.Voucher memory voucher = v.voucherOf(1);
        assertEq(voucher.payer, payer);
        assertEq(voucher.recipient, recipient);
        assertEq(voucher.amount, AMOUNT);
        assertEq(voucher.expiresAt, expiresAt);
        assertFalse(voucher.claimed);
        assertFalse(voucher.refunded);

        uint256 id2 = _create(other, expiresAt, AMOUNT);
        assertEq(id2, 2);
    }

    // ---------------------------------------------------------------------------------------------
    // claim
    // ---------------------------------------------------------------------------------------------

    function test_claim_unknown_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IVouchers.VoucherUnknown.selector, 999));
        v.claim(999);
    }

    function test_claim_not_recipient_reverts() public {
        uint256 id = _create(recipient, uint64(T0 + 1 days), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IVouchers.NotRecipient.selector, id, other));
        vm.prank(other);
        v.claim(id);
    }

    function test_claim_full_lifecycle_credits_and_withdraws() public {
        uint256 id = _create(recipient, uint64(T0 + 1 days), AMOUNT);

        vm.expectEmit(true, true, true, true, address(v));
        emit IVouchers.VoucherClaimed(id, recipient, AMOUNT);
        vm.expectEmit(true, true, true, true, address(v));
        emit IVouchers.Credited(recipient, AMOUNT);
        vm.prank(recipient);
        v.claim(id);

        assertEq(v.withdrawable(recipient), AMOUNT);
        IVouchers.Voucher memory voucher = v.voucherOf(id);
        assertTrue(voucher.claimed);
        assertFalse(voucher.refunded);

        uint256 balBefore = recipient.balance;
        vm.expectEmit(true, true, true, true, address(v));
        emit IVouchers.Withdrawn(recipient, AMOUNT);
        vm.prank(recipient);
        v.withdraw();
        assertEq(recipient.balance, balBefore + AMOUNT);
        assertEq(v.withdrawable(recipient), 0);
    }

    function test_claim_exactly_at_expiry_reverts_expired() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(recipient, expiresAt, AMOUNT);
        vm.warp(expiresAt); // block.timestamp == expiresAt: claim window is strictly `<`
        vm.expectRevert(abi.encodeWithSelector(IVouchers.VoucherExpired.selector, id, expiresAt));
        vm.prank(recipient);
        v.claim(id);
    }

    function test_claim_one_second_before_expiry_succeeds() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(recipient, expiresAt, AMOUNT);
        vm.warp(expiresAt - 1);
        vm.prank(recipient);
        v.claim(id);
        assertEq(v.withdrawable(recipient), AMOUNT);
    }

    function test_claim_after_refund_reverts_alreadyRefunded() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(recipient, expiresAt, AMOUNT);
        vm.warp(expiresAt);
        vm.prank(payer);
        v.refund(id);

        vm.expectRevert(abi.encodeWithSelector(IVouchers.AlreadyRefunded.selector, id));
        vm.prank(recipient);
        v.claim(id);
    }

    function test_double_claim_reverts() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(recipient, expiresAt, AMOUNT);
        vm.prank(recipient);
        v.claim(id);

        vm.expectRevert(abi.encodeWithSelector(IVouchers.AlreadyClaimed.selector, id));
        vm.prank(recipient);
        v.claim(id);
    }

    // ---------------------------------------------------------------------------------------------
    // refund
    // ---------------------------------------------------------------------------------------------

    function test_refund_unknown_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IVouchers.VoucherUnknown.selector, 999));
        v.refund(999);
    }

    function test_refund_not_payer_reverts() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(recipient, expiresAt, AMOUNT);
        vm.warp(expiresAt);
        vm.expectRevert(abi.encodeWithSelector(IVouchers.NotPayer.selector, id, other));
        vm.prank(other);
        v.refund(id);
    }

    function test_refund_before_expiry_reverts_notExpired() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(recipient, expiresAt, AMOUNT);
        vm.warp(expiresAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IVouchers.VoucherNotExpired.selector, id, expiresAt));
        vm.prank(payer);
        v.refund(id);
    }

    function test_refund_exactly_at_expiry_succeeds() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(recipient, expiresAt, AMOUNT);
        vm.warp(expiresAt); // block.timestamp == expiresAt: refund window is `>=`

        vm.expectEmit(true, true, true, true, address(v));
        emit IVouchers.VoucherRefunded(id, payer, AMOUNT);
        vm.expectEmit(true, true, true, true, address(v));
        emit IVouchers.Credited(payer, AMOUNT);
        vm.prank(payer);
        v.refund(id);

        assertEq(v.withdrawable(payer), AMOUNT);
        IVouchers.Voucher memory voucher = v.voucherOf(id);
        assertTrue(voucher.refunded);
        assertFalse(voucher.claimed);
    }

    function test_refund_full_lifecycle_withdraws() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(payer, expiresAt, AMOUNT); // payer == recipient is allowed
        vm.warp(expiresAt + 1);
        vm.prank(payer);
        v.refund(id);

        uint256 balBefore = payer.balance;
        vm.prank(payer);
        v.withdraw();
        assertEq(payer.balance, balBefore + AMOUNT);
    }

    function test_refund_after_claim_reverts_alreadyClaimed() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(recipient, expiresAt, AMOUNT);
        vm.prank(recipient);
        v.claim(id);
        vm.warp(expiresAt);

        vm.expectRevert(abi.encodeWithSelector(IVouchers.AlreadyClaimed.selector, id));
        vm.prank(payer);
        v.refund(id);
    }

    function test_double_refund_reverts() public {
        uint64 expiresAt = uint64(T0 + 1 days);
        uint256 id = _create(recipient, expiresAt, AMOUNT);
        vm.warp(expiresAt);
        vm.prank(payer);
        v.refund(id);

        vm.expectRevert(abi.encodeWithSelector(IVouchers.AlreadyRefunded.selector, id));
        vm.prank(payer);
        v.refund(id);
    }

    // ---------------------------------------------------------------------------------------------
    // withdraw
    // ---------------------------------------------------------------------------------------------

    function test_withdraw_nothing_reverts() public {
        vm.expectRevert(IVouchers.NothingToWithdraw.selector);
        vm.prank(recipient);
        v.withdraw();
    }

    /// @dev T-MKT-3-class pull-payment safety: a malicious/broken recipient contract can still
    ///      `claim()` (the credit is a storage write, no value moves), but a subsequent `withdraw()`
    ///      from it must revert `WithdrawFailed` without corrupting the ledger — and, crucially,
    ///      without corrupting or blocking any *other* user's balance/withdraw.
    function test_reverting_recipient_can_claim_but_not_withdraw_and_ledger_stays_correct_for_others() public {
        RevertingReceiver bad = new RevertingReceiver();
        uint64 expiresAt = uint64(T0 + 1 days);

        uint256 idBad = _create(address(bad), expiresAt, AMOUNT);
        uint256 idGood = _create(recipient, expiresAt, 2 * AMOUNT);

        vm.prank(address(bad));
        v.claim(idBad);
        assertEq(v.withdrawable(address(bad)), AMOUNT);

        vm.prank(recipient);
        v.claim(idGood);
        assertEq(v.withdrawable(recipient), 2 * AMOUNT);

        // bad's withdraw fails and does not touch its own ledger entry or anyone else's.
        vm.expectRevert(abi.encodeWithSelector(IVouchers.WithdrawFailed.selector, address(bad), AMOUNT));
        vm.prank(address(bad));
        v.withdraw();
        assertEq(v.withdrawable(address(bad)), AMOUNT, "credit survives a failed pull");
        assertEq(v.withdrawable(recipient), 2 * AMOUNT, "other user's ledger untouched");

        // the good recipient can still withdraw normally afterwards.
        uint256 balBefore = recipient.balance;
        vm.prank(recipient);
        v.withdraw();
        assertEq(recipient.balance, balBefore + 2 * AMOUNT);
        assertEq(v.withdrawable(recipient), 0);

        // contract balance still holds exactly bad's un-withdrawable credit.
        assertEq(address(v).balance, AMOUNT);
    }
}
