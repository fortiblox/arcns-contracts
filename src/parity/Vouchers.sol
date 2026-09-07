// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IVouchers} from "../interfaces/IVouchers.sol";

/// @title Vouchers — WP-130, gift / prepaid vouchers with expiry (onchain-design §1, M3b)
/// @notice Port of x1-handles' create/claim/refund voucher shape as a standalone prepaid-credit
///         certificate (see `IVouchers` NatSpec for the full design and the deliberate deviation
///         from x1: `claim` credits the recipient's pull-ledger balance here instead of atomically
///         funding a registration, since wiring into `HandleController`/`TldRegistrarController` is
///         out of this lane's file scope).
///
/// @dev No admin surface: every action is payer/recipient-gated. `id = 0` is never assigned
///      (`nextVoucherId` starts at 1) and is treated as "no such voucher"; existence of a stored
///      voucher is tested via `payer != address(0)`, which a real `create` always sets. Pull ledger
///      (`withdrawable` + `withdraw`) is the exact pattern used by `HandleController.withdraw`
///      (SR-31): zero-then-transfer, `nonReentrant`, a failed push reverts without corrupting the
///      ledger (T-MKT-3-class pull-payment safety, verified by test for a reverting recipient).
contract Vouchers is IVouchers, ReentrancyGuardTransient {
    mapping(uint256 voucherId => Voucher) internal _vouchers;

    /// @inheritdoc IVouchers
    mapping(address who => uint256 amount) public withdrawable;

    /// @inheritdoc IVouchers
    uint256 public nextVoucherId = 1;

    /// @dev Dust / mis-sent value is refused; only `create` accepts value.
    receive() external payable {
        revert ValueNotAccepted();
    }

    fallback() external payable {
        revert ValueNotAccepted();
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IVouchers
    function voucherOf(uint256 voucherId) external view returns (Voucher memory) {
        return _vouchers[voucherId];
    }

    // ---------------------------------------------------------------------------------------------
    // Create / claim / refund
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IVouchers
    function create(address recipient, uint64 expiresAt) external payable returns (uint256 voucherId) {
        if (recipient == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert ZeroAmount();
        if (expiresAt <= block.timestamp) revert ExpiryInPast(expiresAt, uint64(block.timestamp));

        voucherId = nextVoucherId++;
        _vouchers[voucherId] = Voucher({
            payer: msg.sender,
            recipient: recipient,
            amount: msg.value,
            expiresAt: expiresAt,
            claimed: false,
            refunded: false
        });
        emit VoucherCreated(voucherId, msg.sender, recipient, msg.value, expiresAt);
    }

    /// @inheritdoc IVouchers
    /// @dev Valid strictly before `expiresAt` (`block.timestamp < expiresAt`); at/after expiry only
    ///      `refund` works, so the two windows never overlap.
    function claim(uint256 voucherId) external {
        Voucher storage v = _vouchers[voucherId];
        if (v.payer == address(0)) revert VoucherUnknown(voucherId);
        if (msg.sender != v.recipient) revert NotRecipient(voucherId, msg.sender);
        if (v.claimed) revert AlreadyClaimed(voucherId);
        if (v.refunded) revert AlreadyRefunded(voucherId);
        if (block.timestamp >= v.expiresAt) revert VoucherExpired(voucherId, v.expiresAt);

        v.claimed = true;
        withdrawable[v.recipient] += v.amount;
        emit VoucherClaimed(voucherId, v.recipient, v.amount);
        emit Credited(v.recipient, v.amount);
    }

    /// @inheritdoc IVouchers
    /// @dev Valid at/after `expiresAt` (`block.timestamp >= expiresAt`) — the boundary itself is
    ///      refund-eligible, not claim-eligible, mirroring `claim`'s exclusive upper bound.
    function refund(uint256 voucherId) external {
        Voucher storage v = _vouchers[voucherId];
        if (v.payer == address(0)) revert VoucherUnknown(voucherId);
        if (msg.sender != v.payer) revert NotPayer(voucherId, msg.sender);
        if (v.claimed) revert AlreadyClaimed(voucherId);
        if (v.refunded) revert AlreadyRefunded(voucherId);
        if (block.timestamp < v.expiresAt) revert VoucherNotExpired(voucherId, v.expiresAt);

        v.refunded = true;
        withdrawable[v.payer] += v.amount;
        emit VoucherRefunded(voucherId, v.payer, v.amount);
        emit Credited(v.payer, v.amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Withdraw
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IVouchers
    function withdraw() external nonReentrant {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert WithdrawFailed(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }
}
