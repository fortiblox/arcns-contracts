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

    // ---------------------------------------------------------------------------------------------
    // Fuzz (WP-130 audit: parity + full coverage)
    // ---------------------------------------------------------------------------------------------

    /// @dev Every non-zero amount, any future expiry, any recipient: `create` escrows exactly
    ///      `msg.value` and stores the fields verbatim.
    function testFuzz_create_stores_exact_amount_and_expiry(uint96 amount, uint32 delay, address recipient_) public {
        vm.assume(recipient_ != address(0));
        amount = uint96(bound(amount, 1, 1000 ether));
        delay = uint32(bound(delay, 1, 3650 days));
        uint64 expiresAt = uint64(T0 + delay);

        vm.deal(payer, amount);
        vm.prank(payer);
        uint256 id = v.create{value: amount}(recipient_, expiresAt);

        IVouchers.Voucher memory voucher = v.voucherOf(id);
        assertEq(voucher.payer, payer);
        assertEq(voucher.recipient, recipient_);
        assertEq(voucher.amount, amount);
        assertEq(voucher.expiresAt, expiresAt);
        assertEq(address(v).balance, amount);
    }

    /// @dev The claim/refund windows are exact complements of `block.timestamp < expiresAt`: for any
    ///      warp target, exactly one of {claim succeeds, refund succeeds} is possible at that moment
    ///      (never both, never neither), matching the x1 `claim_voucher`/`refund_voucher` boundary.
    function testFuzz_claim_and_refund_windows_are_exact_complements(uint32 delay, uint32 warpTo) public {
        delay = uint32(bound(delay, 1, 365 days));
        uint64 expiresAt = uint64(T0 + delay);
        uint256 id = _create(recipient, expiresAt, AMOUNT);
        vm.warp(bound(warpTo, T0, T0 + uint256(delay) + 365 days));

        bool canClaim = block.timestamp < expiresAt;
        if (canClaim) {
            vm.prank(recipient);
            v.claim(id);
            assertEq(v.withdrawable(recipient), AMOUNT);
        } else {
            vm.expectRevert(abi.encodeWithSelector(IVouchers.VoucherExpired.selector, id, expiresAt));
            vm.prank(recipient);
            v.claim(id);

            vm.prank(payer);
            v.refund(id);
            assertEq(v.withdrawable(payer), AMOUNT);
        }
    }

    /// @dev Whatever mix of amounts a payer escrows across many vouchers to many recipients, the
    ///      contract's own balance always equals the sum of every voucher's escrowed amount that
    ///      has not yet been claimed or refunded, plus every address's outstanding `withdrawable`
    ///      balance — the deterministic-sequence sibling of the invariant campaign below.
    function testFuzz_many_vouchers_escrow_accounting_holds(uint8 n, uint256 seed) public {
        n = uint8(bound(n, 1, 12));
        vm.deal(payer, 10000 ether);
        uint256 totalEscrowed;
        uint256[] memory ids = new uint256[](n);
        uint64[] memory expiries = new uint64[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 amount = 1 + (uint256(keccak256(abi.encode(seed, i, "amt"))) % 10 ether);
            uint64 expiresAt = uint64(T0 + 1 + (uint256(keccak256(abi.encode(seed, i, "exp"))) % 30 days));
            address recip = uint256(keccak256(abi.encode(seed, i, "recip"))) % 2 == 0 ? recipient : other;
            ids[i] = _create(recip, expiresAt, amount);
            expiries[i] = expiresAt;
            totalEscrowed += amount;
        }
        assertEq(address(v).balance, totalEscrowed);

        for (uint256 i = 0; i < n; i++) {
            bool claimIt = uint256(keccak256(abi.encode(seed, i, "action"))) % 2 == 0;
            if (claimIt && block.timestamp < expiries[i]) {
                IVouchers.Voucher memory voucher = v.voucherOf(ids[i]);
                vm.prank(voucher.recipient);
                v.claim(ids[i]);
            } else if (block.timestamp >= expiries[i]) {
                vm.prank(payer);
                v.refund(ids[i]);
            }
            // else: left outstanding, still backed by escrow.
        }
        // Every wei is still accounted for: contract balance == Σ withdrawable (claim/refund credit
        // is never pushed) + Σ amount of vouchers still neither claimed nor refunded.
        uint256 stillEscrowed;
        for (uint256 i = 0; i < n; i++) {
            IVouchers.Voucher memory voucher = v.voucherOf(ids[i]);
            if (!voucher.claimed && !voucher.refunded) stillEscrowed += voucher.amount;
        }
        assertEq(
            address(v).balance,
            stillEscrowed + v.withdrawable(recipient) + v.withdrawable(other) + v.withdrawable(payer)
        );
    }
}
