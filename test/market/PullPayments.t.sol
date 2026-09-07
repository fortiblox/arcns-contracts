// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarketFixture} from "./MarketFixture.sol";
import {IArcNSMarket} from "../../src/interfaces/IArcNSMarket.sol";

/// @notice Cross-cutting pull-payment tests (SR-31, T-MKT-3, INV-4): `withdraw()` itself, and proof
///         that a reverting-`receive()` counterparty can never block a bid, a sale, or a settlement —
///         only its own eventual `withdraw()` can fail, and even then every OTHER participant's funds
///         remain safe and reclaimable.
contract ArcNSMarketPullPaymentsTest is MarketFixture {
    function setUp() public override {
        super.setUp();
        _approveMarket(address(registry), seller);
    }

    function test_withdraw_happy_path() public {
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, uint40(block.timestamp + 1 days));
        vm.prank(offerer1);
        market.cancelOffer(address(registry), aliceHandleId);
        assertEq(market.withdrawable(offerer1), 1e18);

        uint256 before = offerer1.balance;
        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.Withdrawn(offerer1, 1e18);
        vm.prank(offerer1);
        market.withdraw();
        assertEq(offerer1.balance, before + 1e18);
        assertEq(market.withdrawable(offerer1), 0);
    }

    function test_withdraw_reverts_nothing_to_withdraw() public {
        vm.prank(offerer1);
        vm.expectRevert(IArcNSMarket.NothingToWithdraw.selector);
        market.withdraw();
    }

    function test_withdraw_reverts_when_receiver_reverts_but_ledger_is_untouched() public {
        vm.prank(address(revertingBidder));
        revertingBidder.placeOffer(market, address(registry), aliceHandleId, 1e18, uint40(block.timestamp + 1 days));
        vm.prank(address(revertingBidder));
        market.cancelOffer(address(registry), aliceHandleId);

        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.WithdrawFailed.selector, address(revertingBidder), 1e18));
        revertingBidder.withdraw(market);
        // The failed withdraw must not have zeroed the ledger (no funds lost).
        assertEq(market.withdrawable(address(revertingBidder)), 1e18);
    }

    function test_withdraw_not_blocked_by_pause() public {
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, uint40(block.timestamp + 1 days));
        vm.prank(offerer1);
        market.cancelOffer(address(registry), aliceHandleId);

        vm.prank(pauser);
        market.pause();
        vm.prank(offerer1);
        market.withdraw();
        assertEq(market.withdrawable(offerer1), 0);
    }

    /// @notice T-MKT-3 / INV-4: a reverting auction seller cannot block settlement, and every other
    ///         participant's credited balance is unaffected by the seller's inability to withdraw.
    function test_reverting_seller_does_not_block_auction_settlement_or_other_balances() public {
        vm.prank(seller);
        registry.transfer(aliceHandleId, address(revertingBidder));
        vm.prank(address(revertingBidder));
        registry.setApprovalForAll(address(market), true);
        vm.prank(address(revertingBidder));
        revertingBidder.startAuction(market, address(registry), aliceHandleId, 1e18, 1 days);

        vm.prank(bidder1);
        market.placeBid{value: 2e18}(address(registry), aliceHandleId);
        vm.prank(bidder2);
        market.placeBid{value: 2.5e18}(address(registry), aliceHandleId);
        // bidder1 was outbid and refunded to the pull ledger — unaffected by the seller's revert.
        assertEq(market.withdrawable(bidder1), 2e18);

        vm.warp(block.timestamp + 1 days);
        market.settleAuction(address(registry), aliceHandleId);

        assertEq(registry.ownerOf(aliceHandleId), bidder2);
        uint256 fee = (uint256(2.5e18) * uint256(FEE_BPS)) / 10_000;
        assertEq(market.withdrawable(treasury), fee);
        assertEq(market.withdrawable(address(revertingBidder)), 2.5e18 - fee);

        // bidder1's unrelated balance withdraws fine even though the seller's own withdraw fails.
        vm.prank(bidder1);
        market.withdraw();
        assertEq(bidder1.balance, 1000e18); // unchanged net of the refunded bid it started with

        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.WithdrawFailed.selector, address(revertingBidder), 2.5e18 - fee)
        );
        revertingBidder.withdraw(market);
    }

    /// @notice INV-4: `marketplace.balance == Σ live bids + Σ live offers + Σ withdrawable` across a
    ///         mixed sequence of listings, offers, and an auction.
    function test_invariant_balance_equals_live_bids_plus_offers_plus_withdrawable() public {
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, uint40(block.timestamp + 7 days));

        tld.mint(seller, 2);
        vm.prank(seller);
        tld.setApprovalForAll(address(market), true);
        vm.prank(seller);
        market.startAuction(address(tld), 2, 1e18, 1 days);
        vm.prank(bidder1);
        market.placeBid{value: 1e18}(address(tld), 2);
        vm.prank(bidder2);
        market.placeBid{value: 1.05e18}(address(tld), 2);

        // bidder1 was outbid -> credited to withdrawable; live state is offer(1e18) + highestBid(1.05e18).
        uint256 liveOffers = market.getOffer(address(registry), aliceHandleId, offerer1).amount;
        uint256 liveBids = market.getAuction(address(tld), 2).highestBid;
        uint256 totalWithdrawable = market.withdrawable(bidder1);
        assertEq(address(market).balance, liveOffers + liveBids + totalWithdrawable);

        // Settle the auction and cancel the offer; the invariant must still hold with the new totals.
        vm.warp(block.timestamp + 1 days);
        market.settleAuction(address(tld), 2);
        vm.prank(offerer1);
        market.cancelOffer(address(registry), aliceHandleId);

        uint256 fee = (uint256(1.05e18) * uint256(FEE_BPS)) / 10_000;
        uint256 expectedWithdrawable = market.withdrawable(bidder1) + market.withdrawable(seller)
            + market.withdrawable(treasury) + market.withdrawable(offerer1);
        assertEq(
            expectedWithdrawable,
            1e18 /* bidder1 refund */ + (1.05e18 - fee) /* seller net */ + fee + 1e18 /* offer refund */
        );
        assertEq(address(market).balance, expectedWithdrawable);
    }
}
