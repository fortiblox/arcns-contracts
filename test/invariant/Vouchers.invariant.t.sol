// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {Vouchers} from "../../src/parity/Vouchers.sol";
import {IVouchers} from "../../src/interfaces/IVouchers.sol";

/// @notice WP-130 escrow-accounting invariant for `Vouchers` (`test/invariant/README.md` conventions):
///         the contract never owes more than it holds, and never silently drops a wei.
///         - INV-VOUCHER-1: `address(vouchers).balance == Σ withdrawable[actor] + Σ amount of every
///           voucher still neither claimed nor refunded` — the pull-payment accounting identity
///           (SR-31 class: escrow is fungible ETH, not per-voucher earmarked balances, but the sum
///           must always reconcile).
///         - INV-VOUCHER-2: a claimed-or-refunded voucher never becomes claimable/refundable again
///           (checked by construction below: `claim`/`refund` each require exactly one of
///           `!claimed && !refunded`, so a handler successfully calling either a second time on the
///           same id would itself prove the contract broken — tracked as a ghost, asserted directly).
contract VouchersHandler is Test {
    Vouchers public vouchers;

    address[4] public actors;
    uint256[] public voucherIds;
    mapping(uint256 => bool) public claimedTwice;
    mapping(uint256 => bool) public refundedTwice;

    uint256 public calls;
    uint256 public successes;
    uint256 public createOk;
    uint256 public claimOk;
    uint256 public refundOk;
    uint256 public withdrawOk;

    constructor(Vouchers vouchers_, address[4] memory actors_) {
        vouchers = vouchers_;
        actors = actors_;
        for (uint256 i = 0; i < 4; i++) {
            vm.deal(actors[i], 10_000_000 ether);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 60 days));
        successes++;
    }

    function create(uint256 payerSeed, uint256 recipientSeed, uint256 amount, uint256 delay) external {
        calls++;
        address payer = _actor(payerSeed);
        address recipient = _actor(recipientSeed);
        amount = bound(amount, 1, 1000 ether);
        uint64 expiresAt = uint64(block.timestamp + bound(delay, 1, 3650 days));
        vm.deal(payer, payer.balance + amount);
        vm.prank(payer);
        try vouchers.create{value: amount}(recipient, expiresAt) returns (uint256 id) {
            voucherIds.push(id);
            createOk++;
            successes++;
        } catch {}
    }

    function claim(uint256 idxSeed) external {
        calls++;
        if (voucherIds.length == 0) return;
        uint256 id = voucherIds[idxSeed % voucherIds.length];
        IVouchers.Voucher memory voucherBefore = vouchers.voucherOf(id);
        bool wasTerminal = voucherBefore.claimed || voucherBefore.refunded;
        vm.prank(voucherBefore.recipient);
        try vouchers.claim(id) {
            claimOk++;
            successes++;
            if (wasTerminal) claimedTwice[id] = true;
        } catch {}
    }

    function refund(uint256 idxSeed) external {
        calls++;
        if (voucherIds.length == 0) return;
        uint256 id = voucherIds[idxSeed % voucherIds.length];
        IVouchers.Voucher memory voucherBefore = vouchers.voucherOf(id);
        bool wasTerminal = voucherBefore.claimed || voucherBefore.refunded;
        vm.prank(voucherBefore.payer);
        try vouchers.refund(id) {
            refundOk++;
            successes++;
            if (wasTerminal) refundedTwice[id] = true;
        } catch {}
    }

    function withdraw(uint256 actorSeed) external {
        calls++;
        vm.prank(_actor(actorSeed));
        try vouchers.withdraw() {
            withdrawOk++;
            successes++;
        } catch {}
    }

    function voucherCount() external view returns (uint256) {
        return voucherIds.length;
    }

    /// @dev Sum of every voucher's escrowed amount that is still neither claimed nor refunded.
    function stillEscrowed() external view returns (uint256 total) {
        for (uint256 i = 0; i < voucherIds.length; i++) {
            IVouchers.Voucher memory voucher = vouchers.voucherOf(voucherIds[i]);
            if (!voucher.claimed && !voucher.refunded) total += voucher.amount;
        }
    }

    /// @dev Sum of every actor's outstanding pull-ledger balance.
    function totalWithdrawable() external view returns (uint256 total) {
        for (uint256 i = 0; i < 4; i++) {
            total += vouchers.withdrawable(actors[i]);
        }
    }

    function anyDoubleClaimOrRefund() external view returns (bool) {
        for (uint256 i = 0; i < voucherIds.length; i++) {
            if (claimedTwice[voucherIds[i]] || refundedTwice[voucherIds[i]]) return true;
        }
        return false;
    }
}

contract VouchersInvariantTest is StdInvariant, Test {
    Vouchers internal vouchers;
    VouchersHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        vouchers = new Vouchers();
        address[4] memory actors = [
            makeAddr("voucherActor0"), makeAddr("voucherActor1"), makeAddr("voucherActor2"), makeAddr("voucherActor3")
        ];
        handler = new VouchersHandler(vouchers, actors);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = VouchersHandler.warp.selector;
        selectors[1] = VouchersHandler.create.selector;
        selectors[2] = VouchersHandler.claim.selector;
        selectors[3] = VouchersHandler.refund.selector;
        selectors[4] = VouchersHandler.withdraw.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_VOUCHER1_escrow_accounting_holds() public view {
        assertEq(
            address(vouchers).balance,
            handler.stillEscrowed() + handler.totalWithdrawable(),
            "contract balance != still-escrowed vouchers + outstanding withdrawable"
        );
    }

    function invariant_VOUCHER2_no_voucher_claimed_or_refunded_twice() public view {
        assertFalse(handler.anyDoubleClaimOrRefund(), "a voucher was claimed or refunded after already being terminal");
    }

    function afterInvariant() public view {
        if (handler.calls() < 12) return;
        assertGt(handler.successes(), 0, "handler never succeeded");
    }
}
