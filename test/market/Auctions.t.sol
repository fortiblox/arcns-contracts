// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarketFixture} from "./MarketFixture.sol";
import {IArcNSMarket} from "../../src/interfaces/IArcNSMarket.sol";

/// @notice `startAuction` / `placeBid` / `settleAuction` / `cancelAuction` tests (WP-121,
///         SR-30/31/32/33/34/35/36; INV-4/5/6).
contract ArcNSMarketAuctionsTest is MarketFixture {
    uint32 internal constant DURATION = 1 days;

    function setUp() public override {
        super.setUp();
        _approveMarket(address(registry), seller);
        _approveMarket(address(tld), seller);
    }

    // ---- startAuction -------------------------------------------------------------------------------

    function test_startAuction_happy_path_snapshots() public {
        uint40 expectedEndsAt = uint40(block.timestamp + DURATION);
        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.AuctionStarted(address(registry), aliceHandleId, seller, 1e18, expectedEndsAt, FEE_BPS);
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);

        IArcNSMarket.Auction memory a = market.getAuction(address(registry), aliceHandleId);
        assertEq(a.seller, seller);
        assertEq(a.reserve, 1e18);
        assertEq(a.highestBid, 0);
        assertEq(a.highestBidder, address(0));
        assertEq(a.endsAt, expectedEndsAt);
        assertEq(a.feeBps, FEE_BPS);
        assertEq(a.ownerAtStart, seller);
        assertEq(a.epochAtStart, registry.epochOf(aliceHandleId));
    }

    function test_startAuction_reverts_collection_not_allowed() public {
        vm.prank(admin);
        market.setCollectionAllowed(address(registry), false);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.CollectionNotAllowed.selector, address(registry)));
        market.startAuction(address(registry), aliceHandleId, 1e18, DURATION);
    }

    function test_startAuction_reverts_not_owner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.NotOwner.selector, address(registry), aliceHandleId, stranger)
        );
        market.startAuction(address(registry), aliceHandleId, 1e18, DURATION);
    }

    function test_startAuction_reverts_not_approved() public {
        vm.prank(seller);
        registry.setApprovalForAll(address(market), false);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.NotApproved.selector, address(registry), aliceHandleId, seller)
        );
        market.startAuction(address(registry), aliceHandleId, 1e18, DURATION);
    }

    function test_startAuction_reverts_locked() public {
        vm.prank(seller);
        registry.lock(aliceHandleId);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.TokenLocked.selector, address(registry), aliceHandleId));
        market.startAuction(address(registry), aliceHandleId, 1e18, DURATION);
    }

    function test_startAuction_reverts_already_listed() public {
        _list(address(registry), aliceHandleId, seller, 1e18, uint40(block.timestamp + 7 days));
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.AlreadyListed.selector, address(registry), aliceHandleId));
        market.startAuction(address(registry), aliceHandleId, 1e18, DURATION);
    }

    function test_startAuction_reverts_already_auctioned() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.AlreadyAuctioned.selector, address(registry), aliceHandleId)
        );
        market.startAuction(address(registry), aliceHandleId, 2e18, DURATION);
    }

    function test_startAuction_reverts_duration_out_of_range() public {
        uint32 minDuration = market.MIN_AUCTION_DURATION();
        uint32 maxDuration = market.MAX_AUCTION_DURATION();

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.DurationOutOfRange.selector, 599, minDuration, maxDuration));
        market.startAuction(address(registry), aliceHandleId, 1e18, 599);

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.DurationOutOfRange.selector, 30 days + 1, minDuration, maxDuration)
        );
        market.startAuction(address(registry), aliceHandleId, 1e18, uint32(30 days + 1));
    }

    function test_startAuction_allows_zero_reserve() public {
        // Design judgment call (WP-121, parity with the X1 program): `reserve` has no `minPrice`
        // floor — a 0-reserve auction is meaningful, and `placeBid`'s first-bid `> 0` rule already
        // forecloses a free/dust auction on its own.
        _startAuction(address(registry), aliceHandleId, seller, 0, DURATION);
        assertEq(market.getAuction(address(registry), aliceHandleId).reserve, 0);
    }

    function test_startAuction_reverts_while_paused() public {
        vm.prank(pauser);
        market.pause();
        vm.prank(seller);
        vm.expectRevert(); // Pausable.EnforcedPause
        market.startAuction(address(registry), aliceHandleId, 1e18, DURATION);
    }

    // ---- placeBid -------------------------------------------------------------------------------

    function test_placeBid_first_bid_must_meet_reserve() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.ReserveNotMet.selector, 1e18, 0.5e18));
        market.placeBid{value: 0.5e18}(address(registry), aliceHandleId);
    }

    function test_placeBid_first_bid_zero_reserve_still_requires_gt_zero() public {
        _startAuction(address(registry), aliceHandleId, seller, 0, DURATION);
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.BidTooLow.selector, 1, 0));
        market.placeBid{value: 0}(address(registry), aliceHandleId);

        vm.prank(bidder1);
        market.placeBid{value: 1}(address(registry), aliceHandleId);
        assertEq(market.getAuction(address(registry), aliceHandleId).highestBidder, bidder1);
    }

    function test_placeBid_happy_path_and_refunds_previous_bidder() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);

        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.BidPlaced(address(registry), aliceHandleId, bidder1, 1e18, uint40(block.timestamp + DURATION));
        vm.prank(bidder1);
        market.placeBid{value: 1e18}(address(registry), aliceHandleId);

        // 5% min increment: 1e18 * 1.05 = 1.05e18
        vm.prank(bidder2);
        market.placeBid{value: 1.05e18}(address(registry), aliceHandleId);

        IArcNSMarket.Auction memory a = market.getAuction(address(registry), aliceHandleId);
        assertEq(a.highestBidder, bidder2);
        assertEq(a.highestBid, 1.05e18);
        assertEq(market.withdrawable(bidder1), 1e18);
    }

    function test_placeBid_reverts_below_min_increment() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(bidder1);
        market.placeBid{value: 1e18}(address(registry), aliceHandleId);

        vm.prank(bidder2);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.BidTooLow.selector, 1.05e18, 1.04e18));
        market.placeBid{value: 1.04e18}(address(registry), aliceHandleId);
    }

    function test_placeBid_reverts_no_active_auction() public {
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.NoActiveAuction.selector, address(registry), aliceHandleId));
        market.placeBid{value: 1e18}(address(registry), aliceHandleId);
    }

    function test_placeBid_reverts_seller_cannot_bid() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.SellerCannotBid.selector, address(registry), aliceHandleId));
        market.placeBid{value: 1e18}(address(registry), aliceHandleId);
    }

    function test_placeBid_reverts_after_ends_at() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.warp(block.timestamp + DURATION);
        vm.prank(bidder1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArcNSMarket.AuctionEnded.selector, address(registry), aliceHandleId, uint40(block.timestamp)
            )
        );
        market.placeBid{value: 1e18}(address(registry), aliceHandleId);
    }

    function test_placeBid_reverts_while_paused() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(pauser);
        market.pause();
        vm.prank(bidder1);
        vm.expectRevert(); // Pausable.EnforcedPause
        market.placeBid{value: 1e18}(address(registry), aliceHandleId);
    }

    function test_placeBid_anti_snipe_extends_endsAt_never_shrinks() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        uint40 originalEndsAt = uint40(block.timestamp + DURATION);

        // Bid outside the anti-snipe window: no extension.
        vm.prank(bidder1);
        market.placeBid{value: 1e18}(address(registry), aliceHandleId);
        assertEq(market.getAuction(address(registry), aliceHandleId).endsAt, originalEndsAt);

        // Warp inside the anti-snipe window (300s of the end) and bid again.
        vm.warp(originalEndsAt - 100);
        vm.prank(bidder2);
        market.placeBid{value: 1.05e18}(address(registry), aliceHandleId);
        uint40 expectedExtended = uint40(block.timestamp + ANTI_SNIPE_EXTEND);
        assertEq(market.getAuction(address(registry), aliceHandleId).endsAt, expectedExtended);
        assertGt(expectedExtended, originalEndsAt);

        // A later bid, still inside the window but whose naive `now + extend` would be EARLIER than
        // the already-extended endsAt, must never shrink endsAt (INV-6).
        uint40 endsAtBeforeThisBid = market.getAuction(address(registry), aliceHandleId).endsAt;
        vm.warp(block.timestamp + 1);
        vm.prank(bidder3);
        market.placeBid{value: 1.1025e18}(address(registry), aliceHandleId);
        assertGe(market.getAuction(address(registry), aliceHandleId).endsAt, endsAtBeforeThisBid);
    }

    function test_placeBid_from_reverting_bidder_can_still_be_outbid_and_refunded() public {
        // T-MKT-3: a bidder whose `receive()` reverts must never be able to block a higher bid.
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(address(revertingBidder));
        revertingBidder.bid(market, address(registry), aliceHandleId, 1e18);

        vm.prank(bidder2);
        market.placeBid{value: 1.05e18}(address(registry), aliceHandleId);

        assertEq(market.getAuction(address(registry), aliceHandleId).highestBidder, bidder2);
        assertEq(market.withdrawable(address(revertingBidder)), 1e18);
    }

    // ---- settleAuction ------------------------------------------------------------------------------

    function test_settleAuction_reverts_not_ended() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArcNSMarket.AuctionNotEnded.selector,
                address(registry),
                aliceHandleId,
                uint40(block.timestamp + DURATION)
            )
        );
        market.settleAuction(address(registry), aliceHandleId);
    }

    function test_settleAuction_reverts_no_active_auction() public {
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.NoActiveAuction.selector, address(registry), aliceHandleId));
        market.settleAuction(address(registry), aliceHandleId);
    }

    function test_settleAuction_zero_bids_clears_with_no_transfer() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.warp(block.timestamp + DURATION);

        // Design judgment call (WP-121): a zero-bid auction past its end just clears state, reusing
        // the `AuctionCancelled` event shape — there is nothing to settle and nobody to refund.
        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.AuctionCancelled(address(registry), aliceHandleId);
        market.settleAuction(address(registry), aliceHandleId);

        assertEq(registry.ownerOf(aliceHandleId), seller);
        assertEq(market.getAuction(address(registry), aliceHandleId).seller, address(0));
    }

    function test_settleAuction_happy_path_transfers_and_splits_fee() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(bidder1);
        market.placeBid{value: 2e18}(address(registry), aliceHandleId);
        vm.warp(block.timestamp + DURATION);

        uint256 fee = (uint256(2e18) * uint256(FEE_BPS)) / 10_000;
        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.AuctionSettled(address(registry), aliceHandleId, bidder1, 2e18, fee);
        market.settleAuction(address(registry), aliceHandleId);

        assertEq(registry.ownerOf(aliceHandleId), bidder1);
        assertEq(market.withdrawable(seller), 2e18 - fee);
        assertEq(market.withdrawable(treasury), fee);
        assertEq(market.getAuction(address(registry), aliceHandleId).seller, address(0));
    }

    function test_settleAuction_permissionless_anyone_can_call() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(bidder1);
        market.placeBid{value: 2e18}(address(registry), aliceHandleId);
        vm.warp(block.timestamp + DURATION);

        vm.prank(stranger);
        market.settleAuction(address(registry), aliceHandleId);
        assertEq(registry.ownerOf(aliceHandleId), bidder1);
    }

    function test_settleAuction_never_blocked_by_pause() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(bidder1);
        market.placeBid{value: 2e18}(address(registry), aliceHandleId);
        vm.warp(block.timestamp + DURATION);

        vm.prank(pauser);
        market.pause();
        market.settleAuction(address(registry), aliceHandleId);
        assertEq(registry.ownerOf(aliceHandleId), bidder1);
    }

    function test_settleAuction_voids_when_owner_transferred_out_of_market_mid_auction() public {
        // T-MKT-1 / INV-5: seller moves the handle out-of-market (or e.g. HandleRegistry recovery
        // completes) while an auction is live. `settleAuction` must VOID (full refund, no fee, no
        // transfer) rather than deliver a name the seller no longer holds, and must never revert —
        // a keeper must always be able to clean this up.
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(bidder1);
        market.placeBid{value: 2e18}(address(registry), aliceHandleId);

        vm.prank(seller);
        registry.transfer(aliceHandleId, stranger);
        vm.warp(block.timestamp + DURATION);

        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.AuctionVoided(address(registry), aliceHandleId, bidder1, 2e18);
        market.settleAuction(address(registry), aliceHandleId);

        assertEq(registry.ownerOf(aliceHandleId), stranger);
        assertEq(market.withdrawable(bidder1), 2e18);
        assertEq(market.withdrawable(seller), 0);
        assertEq(market.withdrawable(treasury), 0);
    }

    function test_settleAuction_voids_when_locked_mid_auction() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(bidder1);
        market.placeBid{value: 2e18}(address(registry), aliceHandleId);

        vm.prank(seller);
        registry.lock(aliceHandleId);
        vm.warp(block.timestamp + DURATION);

        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.AuctionVoided(address(registry), aliceHandleId, bidder1, 2e18);
        market.settleAuction(address(registry), aliceHandleId);

        assertEq(registry.ownerOf(aliceHandleId), seller);
        assertEq(market.withdrawable(bidder1), 2e18);
    }

    function test_settleAuction_voids_when_transfer_reverts_recovery_pending() public {
        // A HandleRegistry recovery in flight doesn't change `ownerOf` or `epoch` (only
        // `completeRecovery` does), so the pre-transfer deliverability check reports deliverable —
        // but the `transferFrom` itself then reverts inside HandleRegistry's `_update`
        // (`RecoveryPending`). `settleAuction` must still VOID cleanly instead of reverting.
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(bidder1);
        market.placeBid{value: 2e18}(address(registry), aliceHandleId);

        vm.prank(seller);
        registry.setRecovery(aliceHandleId, stranger);
        vm.prank(stranger);
        registry.initiateRecovery(aliceHandleId, buyer);

        vm.warp(block.timestamp + DURATION);

        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.AuctionVoided(address(registry), aliceHandleId, bidder1, 2e18);
        market.settleAuction(address(registry), aliceHandleId);

        assertEq(registry.ownerOf(aliceHandleId), seller);
        assertEq(market.withdrawable(bidder1), 2e18);
    }

    function test_settleAuction_voids_on_tld_when_lockedViaNameLocks() public {
        _startAuction(address(tld), TLD_TOKEN_ID, seller, 1e18, DURATION);
        vm.prank(bidder1);
        market.placeBid{value: 2e18}(address(tld), TLD_TOKEN_ID);

        vm.prank(seller);
        nameLocks.lock(address(tld), TLD_TOKEN_ID);
        vm.warp(block.timestamp + DURATION);

        market.settleAuction(address(tld), TLD_TOKEN_ID);
        assertEq(tld.ownerOf(TLD_TOKEN_ID), seller);
        assertEq(market.withdrawable(bidder1), 2e18);
    }

    function test_settleAuction_on_tld_collection_happy_path() public {
        _startAuction(address(tld), TLD_TOKEN_ID, seller, 1e18, DURATION);
        vm.prank(bidder1);
        market.placeBid{value: 2e18}(address(tld), TLD_TOKEN_ID);
        vm.warp(block.timestamp + DURATION);
        market.settleAuction(address(tld), TLD_TOKEN_ID);
        assertEq(tld.ownerOf(TLD_TOKEN_ID), bidder1);
    }

    // ---- cancelAuction --------------------------------------------------------------------------------

    function test_cancelAuction_seller_zero_bids() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.AuctionCancelled(address(registry), aliceHandleId);
        vm.prank(seller);
        market.cancelAuction(address(registry), aliceHandleId);
        assertEq(market.getAuction(address(registry), aliceHandleId).seller, address(0));
    }

    function test_cancelAuction_reverts_not_seller() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.NotSeller.selector, address(registry), aliceHandleId, stranger)
        );
        market.cancelAuction(address(registry), aliceHandleId);
    }

    function test_cancelAuction_reverts_has_bids() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(bidder1);
        market.placeBid{value: 1e18}(address(registry), aliceHandleId);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.AuctionHasBids.selector, address(registry), aliceHandleId));
        market.cancelAuction(address(registry), aliceHandleId);
    }

    function test_cancelAuction_reverts_no_active_auction() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.NoActiveAuction.selector, address(registry), aliceHandleId));
        market.cancelAuction(address(registry), aliceHandleId);
    }

    function test_cancelAuction_never_blocked_by_pause() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        vm.prank(pauser);
        market.pause();
        vm.prank(seller);
        market.cancelAuction(address(registry), aliceHandleId);
    }

    // ---- fuzz -----------------------------------------------------------------------------------

    /// @notice Fuzz: every bid that clears `max(reserve, highestBid * (1 + minBidIncrementBps))`
    ///         succeeds and becomes the new highest bid; every bid below it reverts `BidTooLow`.
    function testFuzz_placeBid_increment_guard(uint96 firstBidRaw, uint96 secondBidDeltaRaw) public {
        uint256 reserve = 1e18;
        uint256 cap = 500_000e18; // comfortably inside both uint96 and the dealt balance below
        uint256 firstBid = bound(uint256(firstBidRaw), reserve, cap);
        _startAuction(address(registry), aliceHandleId, seller, reserve, DURATION);

        vm.deal(bidder1, cap * 2);
        vm.deal(bidder2, cap * 2);

        vm.prank(bidder1);
        market.placeBid{value: firstBid}(address(registry), aliceHandleId);

        uint256 increment = (firstBid * MIN_BID_INCREMENT_BPS) / 10_000;
        if (increment == 0) increment = 1;
        uint256 minRequired = firstBid + increment;

        uint256 tooLow = bound(uint256(secondBidDeltaRaw), 0, minRequired - 1);

        vm.prank(bidder2);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.BidTooLow.selector, minRequired, tooLow));
        market.placeBid{value: tooLow}(address(registry), aliceHandleId);

        // A bid at exactly minRequired always succeeds.
        vm.prank(bidder2);
        market.placeBid{value: minRequired}(address(registry), aliceHandleId);
        assertEq(market.getAuction(address(registry), aliceHandleId).highestBidder, bidder2);
        assertEq(market.withdrawable(bidder1), firstBid);
    }

    /// @notice Fuzz: `list` and `placeOffer` both enforce the same `minPrice` dust floor (`startAuction`
    ///         deliberately does not — see `test_startAuction_allows_zero_reserve`).
    function testFuzz_minPrice_floor_enforced(uint96 price) public {
        vm.assume(price < MIN_PRICE);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.PriceTooLow.selector, price, MIN_PRICE));
        market.list(address(registry), aliceHandleId, price, uint40(block.timestamp + 1 days));

        if (price > 0) {
            vm.deal(offerer1, price);
            vm.prank(offerer1);
            vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.PriceTooLow.selector, price, MIN_PRICE));
            market.placeOffer{value: price}(address(registry), aliceHandleId, uint40(block.timestamp + 1 days));
        }
    }

    /// @notice Fuzz: anti-snipe extension never decreases `endsAt` (INV-6), for any bid time inside
    ///         the window.
    function testFuzz_antiSnipe_never_shrinks_endsAt(uint32 secondsBeforeEnd) public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, DURATION);
        uint40 endsAt = uint40(block.timestamp + DURATION);
        secondsBeforeEnd = uint32(bound(secondsBeforeEnd, 1, DURATION - 1));

        vm.prank(bidder1);
        market.placeBid{value: 1e18}(address(registry), aliceHandleId);

        vm.warp(endsAt - secondsBeforeEnd);
        uint40 endsAtBefore = market.getAuction(address(registry), aliceHandleId).endsAt;
        vm.prank(bidder2);
        market.placeBid{value: 1.05e18}(address(registry), aliceHandleId);
        uint40 endsAtAfter = market.getAuction(address(registry), aliceHandleId).endsAt;

        assertGe(endsAtAfter, endsAtBefore);
    }
}
