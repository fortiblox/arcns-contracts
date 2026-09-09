// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarketFixture} from "./MarketFixture.sol";
import {IArcNSMarket} from "../../src/interfaces/IArcNSMarket.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";

/// @notice `batchBuy` tests (#7611): best-effort multi-name purchase in one tx. Every "this item
///         cannot be bought right now" condition is a per-item SKIP (`bought[i] == false`), never a
///         revert of the whole batch; unspent value always comes back via the pull ledger (SR-31).
contract ArcNSMarketBatchBuyTest is MarketFixture {
    uint40 internal expires;
    uint256 internal bobHandleId;
    uint256 internal carolHandleId;
    uint256 internal constant TLD_TOKEN_ID_2 = 2;

    function setUp() public override {
        super.setUp();
        expires = uint40(block.timestamp + 7 days);

        vm.startPrank(registrar);
        bobHandleId = registry.register("bob", seller, uint8(IHandleRegistry.HandleType.Human), false);
        carolHandleId = registry.register("carol", seller, uint8(IHandleRegistry.HandleType.Human), false);
        vm.stopPrank();
        tld.mint(seller, TLD_TOKEN_ID_2);

        _approveMarket(address(registry), seller);
        _approveMarket(address(tld), seller);
    }

    function _item(address collection, uint256 tokenId, uint256 expectedPrice)
        internal
        pure
        returns (IArcNSMarket.BatchBuyItem memory)
    {
        return IArcNSMarket.BatchBuyItem({collection: collection, tokenId: tokenId, expectedPrice: expectedPrice});
    }

    // ---- happy path -------------------------------------------------------------------------------

    function test_batchBuy_happy_path_buys_every_item_and_splits_fees() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        _list(address(registry), bobHandleId, seller, 2e18, expires);
        _list(address(tld), TLD_TOKEN_ID, seller, 3e18, expires);

        IArcNSMarket.BatchBuyItem[] memory items = new IArcNSMarket.BatchBuyItem[](3);
        items[0] = _item(address(registry), aliceHandleId, 1e18);
        items[1] = _item(address(registry), bobHandleId, 2e18);
        items[2] = _item(address(tld), TLD_TOKEN_ID, 3e18);

        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.BatchBuyExecuted(buyer, 3, 3, 6e18);
        vm.prank(buyer);
        (bool[] memory bought, uint256 totalCharged) = market.batchBuy{value: 6e18}(items);

        assertEq(bought.length, 3);
        assertTrue(bought[0] && bought[1] && bought[2]);
        assertEq(totalCharged, 6e18);

        assertEq(registry.ownerOf(aliceHandleId), buyer);
        assertEq(registry.ownerOf(bobHandleId), buyer);
        assertEq(tld.ownerOf(TLD_TOKEN_ID), buyer);

        // fee split identical to three separate `buy` calls: 2.5% (FEE_BPS) of each price to treasury,
        // the rest to the seller — accumulated across all three items.
        uint256 p1 = 1e18;
        uint256 p2 = 2e18;
        uint256 p3 = 3e18;
        uint256 feeBps = FEE_BPS;
        uint256 fee = (p1 * feeBps) / 10_000 + (p2 * feeBps) / 10_000 + (p3 * feeBps) / 10_000;
        assertEq(market.withdrawable(treasury), fee);
        assertEq(market.withdrawable(seller), 6e18 - fee);
        assertEq(market.withdrawable(buyer), 0, "exact payment: nothing left over");

        // every listing consumed
        assertEq(market.getListing(address(registry), aliceHandleId).seller, address(0));
        assertEq(market.getListing(address(registry), bobHandleId).seller, address(0));
        assertEq(market.getListing(address(tld), TLD_TOKEN_ID).seller, address(0));
    }

    function test_batchBuy_overpayment_credits_the_buyer() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        _list(address(registry), bobHandleId, seller, 2e18, expires);

        IArcNSMarket.BatchBuyItem[] memory items = new IArcNSMarket.BatchBuyItem[](2);
        items[0] = _item(address(registry), aliceHandleId, 1e18);
        items[1] = _item(address(registry), bobHandleId, 2e18);

        vm.prank(buyer);
        (bool[] memory bought, uint256 totalCharged) = market.batchBuy{value: 5e18}(items);
        assertTrue(bought[0] && bought[1]);
        assertEq(totalCharged, 3e18);
        assertEq(market.withdrawable(buyer), 2e18, "the 2e18 not needed for either item comes back");
    }

    // ---- partial failure ---------------------------------------------------------------------------

    function test_batchBuy_skips_a_gone_listing_and_still_buys_the_rest() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        _list(address(registry), bobHandleId, seller, 2e18, expires);

        // bob's listing is cancelled after the buyer built their batch (classic race).
        vm.prank(seller);
        market.cancelListing(address(registry), bobHandleId);

        IArcNSMarket.BatchBuyItem[] memory items = new IArcNSMarket.BatchBuyItem[](2);
        items[0] = _item(address(registry), aliceHandleId, 1e18);
        items[1] = _item(address(registry), bobHandleId, 2e18);

        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.BatchBuyExecuted(buyer, 2, 1, 1e18);
        vm.prank(buyer);
        (bool[] memory bought, uint256 totalCharged) = market.batchBuy{value: 3e18}(items);

        assertTrue(bought[0]);
        assertFalse(bought[1], "bob's listing is gone, not reverted");
        assertEq(totalCharged, 1e18);
        assertEq(registry.ownerOf(aliceHandleId), buyer);
        assertEq(registry.ownerOf(bobHandleId), seller, "bob's handle never moved");
        // the 2e18 earmarked for bob comes back to the buyer, not stranded.
        assertEq(market.withdrawable(buyer), 2e18);
    }

    function test_batchBuy_skips_price_changed_locked_expired_and_stale_items_independently() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        _list(address(registry), bobHandleId, seller, 2e18, expires);
        _list(address(registry), carolHandleId, seller, 1e18, uint40(block.timestamp + 1));
        _list(address(tld), TLD_TOKEN_ID, seller, 1e18, expires);

        // alice becomes locked (TokenLocked)
        vm.prank(seller);
        registry.lock(aliceHandleId);
        // bob's price changes out from under the buyer's quote (PriceChanged)
        vm.prank(seller);
        market.updateListingPrice(address(registry), bobHandleId, 5e18);
        // carol's listing expires (ListingExpired); the tld item is left untouched
        vm.warp(block.timestamp + 2);

        IArcNSMarket.BatchBuyItem[] memory items = new IArcNSMarket.BatchBuyItem[](4);
        items[0] = _item(address(registry), aliceHandleId, 1e18); // locked -> skip
        items[1] = _item(address(registry), bobHandleId, 2e18); // stale expectedPrice -> skip
        items[2] = _item(address(registry), carolHandleId, 1e18); // expired -> skip
        items[3] = _item(address(tld), TLD_TOKEN_ID, 1e18); // still fine -> bought

        vm.prank(buyer);
        (bool[] memory bought, uint256 totalCharged) = market.batchBuy{value: 4e18}(items);

        assertFalse(bought[0], "locked");
        assertFalse(bought[1], "price changed");
        assertFalse(bought[2], "expired");
        assertTrue(bought[3], "unaffected item still buys");
        assertEq(totalCharged, 1e18);
        assertEq(market.withdrawable(buyer), 3e18, "everything not spent comes back");
    }

    function test_batchBuy_skips_stale_listing_after_out_of_market_transfer() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        // out-of-market transfer makes the listing stale (ownerAtList != current owner / epoch bumped)
        vm.prank(seller);
        registry.transfer(aliceHandleId, stranger);

        IArcNSMarket.BatchBuyItem[] memory items = new IArcNSMarket.BatchBuyItem[](1);
        items[0] = _item(address(registry), aliceHandleId, 1e18);
        vm.prank(buyer);
        (bool[] memory bought,) = market.batchBuy{value: 1e18}(items);
        assertFalse(bought[0]);
        assertEq(market.withdrawable(buyer), 1e18);
    }

    /// @dev Value runs out partway through the batch: earlier items consume it first (processing
    ///      order == array order), so a later item can be skipped purely for being unaffordable from
    ///      what's left, even though its OWN price alone would have fit in the total sent.
    function test_batchBuy_later_item_skipped_when_earlier_items_exhaust_the_value() public {
        _list(address(registry), aliceHandleId, seller, 3e18, expires);
        _list(address(registry), bobHandleId, seller, 3e18, expires);

        IArcNSMarket.BatchBuyItem[] memory items = new IArcNSMarket.BatchBuyItem[](2);
        items[0] = _item(address(registry), aliceHandleId, 3e18);
        items[1] = _item(address(registry), bobHandleId, 3e18);

        vm.prank(buyer);
        // only 4e18 sent: covers item 0 (3e18) but not item 1 (3e18, only 1e18 remains)
        (bool[] memory bought, uint256 totalCharged) = market.batchBuy{value: 4e18}(items);
        assertTrue(bought[0]);
        assertFalse(bought[1]);
        assertEq(totalCharged, 3e18);
        assertEq(market.withdrawable(buyer), 1e18);
    }

    /// @dev Reviewer-found bug (2026-09-09): revoking `setApprovalForAll` on a listed item's
    ///      collection is a completely normal, always-available seller action that `EpochGuard.stillValid`
    ///      cannot see (it only tracks `ownerOf`/epoch, never ERC-721 operator-approval state), so the
    ///      listing sails through every other skip check and only the `transferFrom` call itself
    ///      discovers the problem. Before the fix, `_tryBuyOne`'s `transferFrom` was unwrapped, so this
    ///      reverted the ENTIRE `batchBuy` call — including item 0, which had nothing wrong with it —
    ///      directly contradicting the "never reverts the cart, only skips" guarantee in
    ///      `docs/architecture/batch-buy.md` and `IArcNSMarket.batchBuy`'s NatSpec.
    function test_batchBuy_seller_revokes_approval_after_listing_skips_only_that_item() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        _list(address(tld), TLD_TOKEN_ID, seller, 2e18, expires);

        // Seller revokes the market's operator approval on the TLD collection only, after listing.
        // Alice's item (a different collection, `registry`) is completely unaffected.
        vm.prank(seller);
        tld.setApprovalForAll(address(market), false);

        IArcNSMarket.BatchBuyItem[] memory items = new IArcNSMarket.BatchBuyItem[](2);
        items[0] = _item(address(registry), aliceHandleId, 1e18);
        items[1] = _item(address(tld), TLD_TOKEN_ID, 2e18);

        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.BatchBuyExecuted(buyer, 2, 1, 1e18);
        vm.prank(buyer);
        (bool[] memory bought, uint256 totalCharged) = market.batchBuy{value: 3e18}(items);

        assertTrue(bought[0], "alice's item is unaffected by tld's revoked approval and still buys");
        assertFalse(bought[1], "tld item's transferFrom reverts (no approval) -> skipped, not a whole-batch revert");
        assertEq(totalCharged, 1e18);
        assertEq(registry.ownerOf(aliceHandleId), buyer);
        assertEq(tld.ownerOf(TLD_TOKEN_ID), seller, "tld token never moved: transfer failed, nothing delivered");
        // the 2e18 earmarked for the failed tld item comes back to the buyer, not stranded.
        assertEq(market.withdrawable(buyer), 2e18);
        // no fee/proceeds credited for the failed item: accounting only happens once the transfer
        // itself is confirmed to have succeeded (mirrors `settleAuction`'s try/catch ordering).
        uint256 feeBps = FEE_BPS;
        uint256 aliceFee = (1e18 * feeBps) / 10_000;
        assertEq(market.withdrawable(seller), 1e18 - aliceFee, "only alice's proceeds credited");
        assertEq(market.withdrawable(treasury), aliceFee, "only alice's fee credited");
        // the tld listing is still consumed (deleted), like `settleAuction` permanently voids an
        // auction it cannot deliver, rather than leaving a listing dangling on a seller who has
        // already signalled (by revoking approval) that they don't intend to honor it right now.
        assertEq(market.getListing(address(tld), TLD_TOKEN_ID).seller, address(0));
    }

    // ---- duplicates, edge sizes --------------------------------------------------------------------

    function test_batchBuy_duplicate_item_in_same_batch_only_buys_once() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);

        IArcNSMarket.BatchBuyItem[] memory items = new IArcNSMarket.BatchBuyItem[](2);
        items[0] = _item(address(registry), aliceHandleId, 1e18);
        items[1] = _item(address(registry), aliceHandleId, 1e18);

        vm.prank(buyer);
        (bool[] memory bought, uint256 totalCharged) = market.batchBuy{value: 2e18}(items);
        assertTrue(bought[0]);
        assertFalse(bought[1], "already bought by item 0 in the same batch, listing is gone");
        assertEq(totalCharged, 1e18);
        assertEq(registry.ownerOf(aliceHandleId), buyer);
        assertEq(market.withdrawable(buyer), 1e18, "the second item's earmarked value comes back");
    }

    function test_batchBuy_reverts_empty_batch() public {
        IArcNSMarket.BatchBuyItem[] memory items = new IArcNSMarket.BatchBuyItem[](0);
        vm.expectRevert(IArcNSMarket.EmptyBatch.selector);
        vm.prank(buyer);
        market.batchBuy{value: 0}(items);
    }

    function test_batchBuy_reverts_batch_too_large() public {
        uint256 max = market.MAX_BATCH_BUY_SIZE();
        IArcNSMarket.BatchBuyItem[] memory items = new IArcNSMarket.BatchBuyItem[](max + 1);
        for (uint256 i = 0; i < items.length; i++) {
            items[i] = _item(address(registry), aliceHandleId, 1e18);
        }
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.BatchTooLarge.selector, max + 1, max));
        vm.prank(buyer);
        market.batchBuy{value: 0}(items);
    }

    function test_batchBuy_at_max_size_all_misses_does_not_revert_and_refunds_everything() public {
        uint256 max = market.MAX_BATCH_BUY_SIZE();
        IArcNSMarket.BatchBuyItem[] memory items = new IArcNSMarket.BatchBuyItem[](max);
        for (uint256 i = 0; i < items.length; i++) {
            // every item targets an unlisted token (aliceHandleId was never listed here) -> all skip
            items[i] = _item(address(registry), aliceHandleId, 1e18);
        }
        vm.prank(buyer);
        (bool[] memory bought, uint256 totalCharged) = market.batchBuy{value: 7e18}(items);
        for (uint256 i = 0; i < items.length; i++) {
            assertFalse(bought[i]);
        }
        assertEq(totalCharged, 0);
        assertEq(market.withdrawable(buyer), 7e18, "a fully-missed batch never reverts; the value comes back");
    }

    // ---- pause / access -----------------------------------------------------------------------------

    function test_batchBuy_is_not_blocked_by_pause() public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        vm.prank(pauser);
        market.pause();

        IArcNSMarket.BatchBuyItem[] memory items = new IArcNSMarket.BatchBuyItem[](1);
        items[0] = _item(address(registry), aliceHandleId, 1e18);
        vm.prank(buyer);
        (bool[] memory bought,) = market.batchBuy{value: 1e18}(items);
        assertTrue(bought[0], "buy of an EXISTING listing is never paused (SR-35), batchBuy matches buy");
    }

    // ---- fuzz ---------------------------------------------------------------------------------------

    /// @dev Whatever mix of listed/unlisted items and however much value is sent, the accounting
    ///      identity always holds: `msg.value == totalCharged + amount credited back to the buyer`,
    ///      and `bought[i]` is true iff that item's price was actually charged.
    function testFuzz_batchBuy_value_accounting_always_reconciles(uint8 listedMask, uint96 valueSentRaw) public {
        _list(address(registry), aliceHandleId, seller, 1e18, expires);
        _list(address(registry), bobHandleId, seller, 2e18, expires);
        _list(address(registry), carolHandleId, seller, 3e18, expires);
        if (listedMask & 1 == 0) {
            vm.prank(seller);
            market.cancelListing(address(registry), aliceHandleId);
        }
        if (listedMask & 2 == 0) {
            vm.prank(seller);
            market.cancelListing(address(registry), bobHandleId);
        }
        if (listedMask & 4 == 0) {
            vm.prank(seller);
            market.cancelListing(address(registry), carolHandleId);
        }

        IArcNSMarket.BatchBuyItem[] memory items = new IArcNSMarket.BatchBuyItem[](3);
        items[0] = _item(address(registry), aliceHandleId, 1e18);
        items[1] = _item(address(registry), bobHandleId, 2e18);
        items[2] = _item(address(registry), carolHandleId, 3e18);

        uint256 valueSent = bound(valueSentRaw, 0, 10e18);
        vm.deal(buyer, valueSent);
        vm.prank(buyer);
        (bool[] memory bought, uint256 totalCharged) = market.batchBuy{value: valueSent}(items);

        uint256 expectedCharged;
        if (bought[0]) expectedCharged += 1e18;
        if (bought[1]) expectedCharged += 2e18;
        if (bought[2]) expectedCharged += 3e18;
        assertEq(totalCharged, expectedCharged);
        assertEq(market.withdrawable(buyer), valueSent - totalCharged);
        assertLe(totalCharged, valueSent);
    }
}
