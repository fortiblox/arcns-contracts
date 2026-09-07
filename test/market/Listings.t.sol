// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarketFixture} from "./MarketFixture.sol";
import {IArcNSMarket} from "../../src/interfaces/IArcNSMarket.sol";

/// @notice `list` / `updateListingPrice` / `cancelListing` / `buy` tests (WP-119, SR-30/31/32/33/36).
contract ArcNSMarketListingsTest is MarketFixture {
    uint40 internal expires;

    function setUp() public override {
        super.setUp();
        expires = uint40(block.timestamp + 7 days);
        _approveMarket(address(registry), seller);
        _approveMarket(address(tld), seller);
    }

    // ---- list -----------------------------------------------------------------------------------

    function test_list_happy_path_stores_snapshot_and_emits() public {
        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.Listed(address(registry), aliceHandleId, seller, 1e18, expires, FEE_BPS);
        vm.prank(seller);
        market.list(address(registry), aliceHandleId, 1e18, expires);

        IArcNSMarket.Listing memory l = market.getListing(address(registry), aliceHandleId);
        assertEq(l.seller, seller);
        assertEq(l.price, 1e18);
        assertEq(l.expiresAt, expires);
        assertEq(l.feeBps, FEE_BPS);
        assertEq(l.ownerAtList, seller);
        assertEq(l.epochAtList, registry.epochOf(aliceHandleId));
    }

    function test_list_on_tld_collection_epoch_sentinel_zero() public {
        vm.prank(seller);
        market.list(address(tld), TLD_TOKEN_ID, 1e18, expires);
        IArcNSMarket.Listing memory l = market.getListing(address(tld), TLD_TOKEN_ID);
        assertEq(l.epochAtList, 0);
        assertEq(l.ownerAtList, seller);
    }

    function test_list_reverts_collection_not_allowed() public {
        vm.prank(admin);
        market.setCollectionAllowed(address(registry), false);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.CollectionNotAllowed.selector, address(registry)));
        market.list(address(registry), aliceHandleId, 1e18, expires);
    }

    function test_list_reverts_not_owner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.NotOwner.selector, address(registry), aliceHandleId, stranger)
        );
        market.list(address(registry), aliceHandleId, 1e18, expires);
    }

    function test_list_reverts_not_approved() public {
        vm.prank(seller);
        registry.setApprovalForAll(address(market), false);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.NotApproved.selector, address(registry), aliceHandleId, seller)
        );
        market.list(address(registry), aliceHandleId, 1e18, expires);
    }

    function test_list_reverts_locked_native() public {
        vm.prank(seller);
        registry.lock(aliceHandleId);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.TokenLocked.selector, address(registry), aliceHandleId));
        market.list(address(registry), aliceHandleId, 1e18, expires);
    }

    function test_list_reverts_locked_via_nameLocks_parity() public {
        vm.prank(seller);
        nameLocks.lock(address(tld), TLD_TOKEN_ID);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.TokenLocked.selector, address(tld), TLD_TOKEN_ID));
        market.list(address(tld), TLD_TOKEN_ID, 1e18, expires);
    }

    function test_list_reverts_already_auctioned() public {
        _startAuction(address(registry), aliceHandleId, seller, 1e18, 1 days);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.AlreadyAuctioned.selector, address(registry), aliceHandleId)
        );
        market.list(address(registry), aliceHandleId, 1e18, expires);
    }

    function test_list_reverts_price_too_low() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.PriceTooLow.selector, MIN_PRICE - 1, MIN_PRICE));
        market.list(address(registry), aliceHandleId, MIN_PRICE - 1, expires);
    }

    function test_list_reverts_already_expired() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.ListingExpired.selector, address(registry), aliceHandleId));
        market.list(address(registry), aliceHandleId, 1e18, uint40(block.timestamp));
    }

    function test_list_overwrites_existing_listing() public {
        // Design judgment call (WP-119): re-listing an already-listed token overwrites in place
        // rather than reverting — a Listing never escrows funds, so nothing is stranded.
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        _list(address(registry), aliceHandleId, seller, 2e18, expires + 1);
        IArcNSMarket.Listing memory l = market.getListing(address(registry), aliceHandleId);
        assertEq(l.price, 2e18);
        assertEq(l.expiresAt, expires + 1);
    }

    // ---- updateListingPrice -----------------------------------------------------------------------

    function test_updateListingPrice_happy_path() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.ListingPriceChanged(address(registry), aliceHandleId, 3e18);
        vm.prank(seller);
        market.updateListingPrice(address(registry), aliceHandleId, 3e18);
        assertEq(market.getListing(address(registry), aliceHandleId).price, 3e18);
    }

    function test_updateListingPrice_reverts_not_listed() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.NotListed.selector, address(registry), aliceHandleId));
        market.updateListingPrice(address(registry), aliceHandleId, 3e18);
    }

    function test_updateListingPrice_reverts_not_seller() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.NotSeller.selector, address(registry), aliceHandleId, stranger)
        );
        market.updateListingPrice(address(registry), aliceHandleId, 3e18);
    }

    function test_updateListingPrice_reverts_price_too_low() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.PriceTooLow.selector, 0, MIN_PRICE));
        market.updateListingPrice(address(registry), aliceHandleId, 0);
    }

    function test_updateListingPrice_works_while_paused() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.prank(pauser);
        market.pause();
        vm.prank(seller);
        market.updateListingPrice(address(registry), aliceHandleId, 3e18);
        assertEq(market.getListing(address(registry), aliceHandleId).price, 3e18);
    }

    // ---- cancelListing ----------------------------------------------------------------------------

    function test_cancelListing_by_seller() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.ListingCancelled(address(registry), aliceHandleId);
        vm.prank(seller);
        market.cancelListing(address(registry), aliceHandleId);
        assertEq(market.getListing(address(registry), aliceHandleId).seller, address(0));
    }

    function test_cancelListing_by_current_owner_after_out_of_market_transfer() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.prank(seller);
        registry.transfer(aliceHandleId, stranger);

        vm.prank(stranger);
        market.cancelListing(address(registry), aliceHandleId);
        assertEq(market.getListing(address(registry), aliceHandleId).seller, address(0));
    }

    function test_cancelListing_reverts_neither_seller_nor_owner() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.prank(seller);
        registry.transfer(aliceHandleId, stranger);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.NotSeller.selector, address(registry), aliceHandleId, buyer)
        );
        market.cancelListing(address(registry), aliceHandleId);
    }

    function test_cancelListing_reverts_not_listed() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.NotListed.selector, address(registry), aliceHandleId));
        market.cancelListing(address(registry), aliceHandleId);
    }

    function test_cancelListing_by_recorded_seller_after_release_burns_token() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.prank(seller);
        registry.release(aliceHandleId);

        // ownerOf now reverts (burned); only the recorded seller may still cancel.
        vm.prank(seller);
        market.cancelListing(address(registry), aliceHandleId);
        assertEq(market.getListing(address(registry), aliceHandleId).seller, address(0));
    }

    function test_cancelListing_works_while_paused() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.prank(pauser);
        market.pause();
        vm.prank(seller);
        market.cancelListing(address(registry), aliceHandleId);
    }

    // ---- buy --------------------------------------------------------------------------------------

    function test_buy_happy_path_splits_fee_and_credits_pull_ledger() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        uint256 fee = (uint256(1e18) * uint256(FEE_BPS)) / 10_000;

        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.Sold(address(registry), aliceHandleId, seller, buyer, 1e18, fee);
        vm.prank(buyer);
        market.buy{value: 1e18}(address(registry), aliceHandleId, 1e18);

        assertEq(registry.ownerOf(aliceHandleId), buyer);
        assertEq(market.getListing(address(registry), aliceHandleId).seller, address(0));
        assertEq(market.withdrawable(seller), 1e18 - fee);
        assertEq(market.withdrawable(treasury), fee);
    }

    function test_buy_refunds_overpayment_to_buyer_pull_ledger() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.prank(buyer);
        market.buy{value: 1.5e18}(address(registry), aliceHandleId, 1e18);
        assertEq(market.withdrawable(buyer), 0.5e18);
    }

    function test_buy_reverts_price_changed() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.PriceChanged.selector, 2e18, 1e18));
        market.buy{value: 2e18}(address(registry), aliceHandleId, 2e18);
    }

    function test_buy_reverts_incorrect_payment_underpay() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.IncorrectPayment.selector, 1e18, 0.5e18));
        market.buy{value: 0.5e18}(address(registry), aliceHandleId, 1e18);
    }

    function test_buy_reverts_expired() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.warp(expires + 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.ListingExpired.selector, address(registry), aliceHandleId));
        market.buy{value: 1e18}(address(registry), aliceHandleId, 1e18);
    }

    function test_buy_reverts_locked() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.prank(seller);
        registry.lock(aliceHandleId);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.TokenLocked.selector, address(registry), aliceHandleId));
        market.buy{value: 1e18}(address(registry), aliceHandleId, 1e18);
    }

    function test_buy_reverts_listing_stale_after_out_of_market_transfer() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.prank(seller);
        registry.transfer(aliceHandleId, stranger);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.ListingStale.selector, address(registry), aliceHandleId));
        market.buy{value: 1e18}(address(registry), aliceHandleId, 1e18);
    }

    function test_buy_is_not_blocked_by_pause() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.prank(pauser);
        market.pause();
        vm.prank(buyer);
        market.buy{value: 1e18}(address(registry), aliceHandleId, 1e18);
        assertEq(registry.ownerOf(aliceHandleId), buyer);
    }

    function test_buy_from_reverting_seller_still_succeeds_seller_must_withdraw() public {
        // T-MKT-3: a seller whose `receive()` reverts must never be able to block a sale — proceeds
        // are pull-based.
        vm.prank(seller);
        registry.transfer(aliceHandleId, address(revertingBidder));
        vm.prank(address(revertingBidder));
        registry.setApprovalForAll(address(market), true);
        vm.prank(address(revertingBidder));
        revertingBidder.list(market, address(registry), aliceHandleId, 1e18, expires);

        vm.prank(buyer);
        market.buy{value: 1e18}(address(registry), aliceHandleId, 1e18);
        assertEq(registry.ownerOf(aliceHandleId), buyer);

        uint256 fee = (uint256(1e18) * uint256(FEE_BPS)) / 10_000;
        assertEq(market.withdrawable(address(revertingBidder)), 1e18 - fee);

        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.WithdrawFailed.selector, address(revertingBidder), 1e18 - fee)
        );
        revertingBidder.withdraw(market);
    }

    function test_buy_on_tld_collection_happy_path() public {
        _list(address(tld), TLD_TOKEN_ID, seller, 1e18, expires);
        vm.prank(buyer);
        market.buy{value: 1e18}(address(tld), TLD_TOKEN_ID, 1e18);
        assertEq(tld.ownerOf(TLD_TOKEN_ID), buyer);
    }

    function test_buy_reverts_nonexistent_listing() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.NotListed.selector, address(registry), aliceHandleId));
        market.buy{value: 1e18}(address(registry), aliceHandleId, 1e18);
    }
}
