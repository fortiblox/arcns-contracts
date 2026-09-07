// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IVouchers — WP-130, gift / prepaid vouchers with expiry (onchain-design §1, M3b)
/// @notice Ports x1-handles' create/claim/refund voucher shape as a standalone prepaid-credit
///         certificate: a payer escrows `msg.value` for a specific `recipient`; before `expiresAt`
///         only `claim` works (credits the escrow to the recipient's pull-ledger balance so they can
///         spend it, e.g. on a registration); at/after `expiresAt` only `refund` works (returns the
///         unclaimed escrow to the payer). A voucher that has been claimed or refunded cannot be
///         claimed or refunded again (fail-closed, matches the vouchers-are-fail-closed-like-launch-
///         allowlist pattern in WP-144).
///
/// @dev x1's voucher directly funds a specific name registration in one instruction
///      (`claim_voucher(name)`). Doing the same atomically here needs
///      `HandleController.register`/`TldRegistrarController.register` to accept a voucher argument —
///      those files are in `contracts/src/handle`/`contracts/src/tld`, out of this lane's file scope.
///      This module instead credits the claimed amount into the recipient's own pull-ledger balance
///      (`withdrawable`), which the recipient withdraws and spends normally; wiring a one-tx
///      claim-and-register path is a small follow-up for whichever lane owns those controllers,
///      flagged in the M3 PR description.
interface IVouchers {
    struct Voucher {
        address payer;
        address recipient;
        uint256 amount;
        uint64 expiresAt;
        bool claimed;
        bool refunded;
    }

    event VoucherCreated(
        uint256 indexed voucherId, address indexed payer, address indexed recipient, uint256 amount, uint64 expiresAt
    );
    event VoucherClaimed(uint256 indexed voucherId, address indexed recipient, uint256 amount);
    event VoucherRefunded(uint256 indexed voucherId, address indexed payer, uint256 amount);
    event Credited(address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error ExpiryInPast(uint64 expiresAt, uint64 now_);
    error VoucherUnknown(uint256 voucherId);
    error NotRecipient(uint256 voucherId, address caller);
    error NotPayer(uint256 voucherId, address caller);
    error VoucherExpired(uint256 voucherId, uint64 expiresAt);
    error VoucherNotExpired(uint256 voucherId, uint64 expiresAt);
    error AlreadyClaimed(uint256 voucherId);
    error AlreadyRefunded(uint256 voucherId);
    error NothingToWithdraw();
    error WithdrawFailed(address to, uint256 amount);
    error ValueNotAccepted();

    function voucherOf(uint256 voucherId) external view returns (Voucher memory);
    function withdrawable(address who) external view returns (uint256);
    function nextVoucherId() external view returns (uint256);

    function create(address recipient, uint64 expiresAt) external payable returns (uint256 voucherId);
    /// @notice Recipient only, before `expiresAt`. Credits `amount` to `withdrawable[recipient]`.
    function claim(uint256 voucherId) external;
    /// @notice Payer only, at/after `expiresAt` and only if unclaimed. Credits `amount` back to the payer.
    function refund(uint256 voucherId) external;
    function withdraw() external;
}
