// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarketFixture} from "./MarketFixture.sol";
import {IArcNSMarket} from "../../src/interfaces/IArcNSMarket.sol";
import {ArcNSMarket} from "../../src/market/ArcNSMarket.sol";

/// @notice `placeOffer` / `cancelOffer` / `acceptOffer` tests (WP-120, SR-30/31/32/33/36).
contract ArcNSMarketOffersTest is MarketFixture {
    uint40 internal expires;

    function setUp() public override {
        super.setUp();
        expires = uint40(block.timestamp + 7 days);
        // `acceptOffer`'s `transferFrom` still runs the collection's standard ERC-721 authorization
        // check (MARKET_ROLE only bypasses HandleRegistry's soulbound gate, not `_checkAuthorized`) —
        // sellers must approve the market the same way `list`/`startAuction` require.
        _approveMarket(address(registry), seller);
        _approveMarket(address(tld), seller);
    }

    // ---- placeOffer -------------------------------------------------------------------------------

    function test_placeOffer_happy_path_escrows_and_snapshots_fee() public {
        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.OfferPlaced(address(registry), aliceHandleId, offerer1, 1e18, expires);
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, expires);

        IArcNSMarket.Offer memory o = market.getOffer(address(registry), aliceHandleId, offerer1);
        assertEq(o.offerer, offerer1);
        assertEq(o.amount, 1e18);
        assertEq(o.expiresAt, expires);
        assertEq(o.feeBps, FEE_BPS);
        assertEq(address(market).balance, 1e18);
    }

    function test_placeOffer_reverts_collection_not_allowed() public {
        vm.prank(admin);
        market.setCollectionAllowed(address(registry), false);
        vm.prank(offerer1);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.CollectionNotAllowed.selector, address(registry)));
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, expires);
    }

    function test_placeOffer_reverts_zero_value() public {
        vm.prank(offerer1);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.PriceTooLow.selector, 0, MIN_PRICE));
        market.placeOffer{value: 0}(address(registry), aliceHandleId, expires);
    }

    function test_placeOffer_reverts_below_minPrice() public {
        vm.prank(offerer1);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.PriceTooLow.selector, MIN_PRICE - 1, MIN_PRICE));
        market.placeOffer{value: MIN_PRICE - 1}(address(registry), aliceHandleId, expires);
    }

    function test_placeOffer_reverts_already_expired() public {
        vm.prank(offerer1);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.OfferExpired.selector, address(registry), aliceHandleId, offerer1)
        );
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, uint40(block.timestamp));
    }

    function test_placeOffer_reverts_while_paused() public {
        vm.prank(pauser);
        market.pause();
        vm.prank(offerer1);
        vm.expectRevert(); // Pausable.EnforcedPause
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, expires);
    }

    function test_placeOffer_reverts_second_offer_same_offerer_without_cancel() public {
        // Design judgment call (WP-120): a second live `placeOffer` from the same offerer reverts
        // rather than silently replacing the first — closest EVM analog of the X1 program's
        // `init`-constrained PDA, which fails the same way.
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, expires);

        vm.prank(offerer1);
        vm.expectRevert(
            abi.encodeWithSelector(ArcNSMarket.OfferAlreadyExists.selector, address(registry), aliceHandleId, offerer1)
        );
        market.placeOffer{value: 2e18}(address(registry), aliceHandleId, expires);
    }

    function test_placeOffer_allows_replacement_after_cancel() public {
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, expires);
        vm.prank(offerer1);
        market.cancelOffer(address(registry), aliceHandleId);
        vm.prank(offerer1);
        market.placeOffer{value: 2e18}(address(registry), aliceHandleId, expires);
        assertEq(market.getOffer(address(registry), aliceHandleId, offerer1).amount, 2e18);
    }

    function test_placeOffer_independent_of_a_live_listing() public {
        vm.prank(seller);
        registry.setApprovalForAll(address(market), true);
        _list(address(registry), aliceHandleId, seller, 1e18, expires);

        vm.prank(offerer1);
        market.placeOffer{value: 0.5e18}(address(registry), aliceHandleId, expires);
        assertEq(market.getOffer(address(registry), aliceHandleId, offerer1).amount, 0.5e18);
    }

    // ---- cancelOffer --------------------------------------------------------------------------------

    function test_cancelOffer_refunds_to_pull_ledger() public {
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, expires);

        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.OfferCancelled(address(registry), aliceHandleId, offerer1);
        vm.prank(offerer1);
        market.cancelOffer(address(registry), aliceHandleId);

        assertEq(market.withdrawable(offerer1), 1e18);
        assertEq(market.getOffer(address(registry), aliceHandleId, offerer1).amount, 0);
    }

    function test_cancelOffer_reverts_no_offer() public {
        vm.prank(offerer1);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.NoOffer.selector, address(registry), aliceHandleId, offerer1)
        );
        market.cancelOffer(address(registry), aliceHandleId);
    }

    function test_cancelOffer_always_works_while_paused() public {
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, expires);
        vm.prank(pauser);
        market.pause();
        vm.prank(offerer1);
        market.cancelOffer(address(registry), aliceHandleId);
        assertEq(market.withdrawable(offerer1), 1e18);
    }

    function test_cancelOffer_by_reverting_offerer_credits_but_does_not_push() public {
        // T-MKT-3: cancelling never pushes value directly — it only credits the ledger, so a
        // reverting-`receive()` offerer can always cancel.
        vm.prank(address(revertingBidder));
        revertingBidder.placeOffer(market, address(registry), aliceHandleId, 1e18, expires);
        vm.prank(address(revertingBidder));
        market.cancelOffer(address(registry), aliceHandleId);
        assertEq(market.withdrawable(address(revertingBidder)), 1e18);
    }

    // ---- acceptOffer --------------------------------------------------------------------------------

    function test_acceptOffer_happy_path_transfers_and_splits_fee() public {
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, expires);

        uint256 fee = (uint256(1e18) * uint256(FEE_BPS)) / 10_000;
        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.OfferAccepted(address(registry), aliceHandleId, offerer1, seller, 1e18, fee);
        vm.prank(seller);
        market.acceptOffer(address(registry), aliceHandleId, offerer1, 1e18);

        assertEq(registry.ownerOf(aliceHandleId), offerer1);
        assertEq(market.withdrawable(seller), 1e18 - fee);
        assertEq(market.withdrawable(treasury), fee);
        assertEq(market.getOffer(address(registry), aliceHandleId, offerer1).amount, 0);
    }

    function test_acceptOffer_reverts_no_offer() public {
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.NoOffer.selector, address(registry), aliceHandleId, offerer1)
        );
        market.acceptOffer(address(registry), aliceHandleId, offerer1, 1e18);
    }

    function test_acceptOffer_reverts_amount_changed() public {
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, expires);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.AmountChanged.selector, 2e18, 1e18));
        market.acceptOffer(address(registry), aliceHandleId, offerer1, 2e18);
    }

    function test_acceptOffer_reverts_expired() public {
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, expires);
        vm.warp(expires + 1);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.OfferExpired.selector, address(registry), aliceHandleId, offerer1)
        );
        market.acceptOffer(address(registry), aliceHandleId, offerer1, 1e18);
    }

    function test_acceptOffer_reverts_not_owner() public {
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, expires);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSMarket.NotOwner.selector, address(registry), aliceHandleId, stranger)
        );
        market.acceptOffer(address(registry), aliceHandleId, offerer1, 1e18);
    }

    function test_acceptOffer_reverts_locked() public {
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, expires);
        vm.prank(seller);
        registry.lock(aliceHandleId);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.TokenLocked.selector, address(registry), aliceHandleId));
        market.acceptOffer(address(registry), aliceHandleId, offerer1, 1e18);
    }

    function test_acceptOffer_reverts_locked_via_nameLocks_on_tld() public {
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(tld), TLD_TOKEN_ID, expires);
        vm.prank(seller);
        nameLocks.lock(address(tld), TLD_TOKEN_ID);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.TokenLocked.selector, address(tld), TLD_TOKEN_ID));
        market.acceptOffer(address(tld), TLD_TOKEN_ID, offerer1, 1e18);
    }

    function test_acceptOffer_not_blocked_by_pause() public {
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, expires);
        vm.prank(pauser);
        market.pause();
        vm.prank(seller);
        market.acceptOffer(address(registry), aliceHandleId, offerer1, 1e18);
        assertEq(registry.ownerOf(aliceHandleId), offerer1);
    }

    function test_acceptOffer_leaves_coexisting_listing_stale_cancellable_by_new_owner() public {
        vm.prank(seller);
        registry.setApprovalForAll(address(market), true);
        _list(address(registry), aliceHandleId, seller, 5e18, expires);

        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, expires);
        vm.prank(seller);
        market.acceptOffer(address(registry), aliceHandleId, offerer1, 1e18);

        // The listing is now stale (recorded seller no longer owns it); buy must refuse it, and the
        // new owner can clean it up via cancelListing.
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.ListingStale.selector, address(registry), aliceHandleId));
        market.buy{value: 5e18}(address(registry), aliceHandleId, 5e18);

        vm.prank(offerer1);
        market.cancelListing(address(registry), aliceHandleId);
    }

    function test_acceptOffer_on_tld_collection_happy_path() public {
        vm.prank(offerer1);
        market.placeOffer{value: 1e18}(address(tld), TLD_TOKEN_ID, expires);
        vm.prank(seller);
        market.acceptOffer(address(tld), TLD_TOKEN_ID, offerer1, 1e18);
        assertEq(tld.ownerOf(TLD_TOKEN_ID), offerer1);
    }
}
