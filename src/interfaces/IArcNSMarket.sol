// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IArcNSMarket — C10, shared marketplace across every allow-listed ERC-721 (onchain-design §8)
/// @notice Keyed by `(collection, tokenId)` so the same contract serves `HandleRegistry` (C1) and every
///         `TldRegistrar` (C4, `.arc`, `.circle`, …). Non-custodial: the NFT stays with the seller
///         until an atomic `transferFrom` inside `buy`/`acceptOffer`/`settleAuction`. Pull-payment only
///         (SR-31): every payout — seller proceeds, refunds, overpayments, the treasury fee — is
///         credited to `withdrawable[addr]`; `withdraw()` is the only outbound value call.
interface IArcNSMarket {
    struct MarketConfig {
        uint16 feeBps; // <= 10_000 (SR-33)
        uint16 minBidIncrementBps; // default 500 (5%)
        uint32 antiSnipeWindow; // default 300s
        uint32 antiSnipeExtend; // >= antiSnipeWindow, default 300s
        uint96 minPrice; // dust floor (SR-36), wei
    }

    struct Listing {
        address seller;
        uint256 price;
        uint40 expiresAt;
        uint16 feeBps; // snapshotted at `list` (SR-33)
        address ownerAtList; // EpochGuard.Snapshot, inlined (avoids a struct-of-struct ABI)
        uint64 epochAtList;
    }

    struct Offer {
        address offerer;
        uint256 amount;
        uint40 expiresAt;
        uint16 feeBps;
    }

    struct Auction {
        address seller;
        uint256 reserve;
        uint256 highestBid;
        address highestBidder;
        uint40 endsAt;
        uint16 feeBps;
        address ownerAtStart;
        uint64 epochAtStart;
    }

    /// @notice One line item for `batchBuy` — same triple `buy` takes, batched (#7611).
    struct BatchBuyItem {
        address collection;
        uint256 tokenId;
        uint256 expectedPrice;
    }

    // ---- events (onchain-design §9)
    event CollectionAllowed(address indexed collection, bool allowed);
    event MarketConfigUpdated(MarketConfig config);
    event Listed(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed seller,
        uint256 price,
        uint40 expiresAt,
        uint16 feeBps
    );
    event ListingPriceChanged(address indexed collection, uint256 indexed tokenId, uint256 newPrice);
    event ListingCancelled(address indexed collection, uint256 indexed tokenId);
    event Sold(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed seller,
        address buyer,
        uint256 price,
        uint256 fee
    );
    event OfferPlaced(
        address indexed collection, uint256 indexed tokenId, address indexed offerer, uint256 amount, uint40 expiresAt
    );
    event OfferCancelled(address indexed collection, uint256 indexed tokenId, address indexed offerer);
    event OfferAccepted(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed offerer,
        address seller,
        uint256 amount,
        uint256 fee
    );
    event AuctionStarted(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed seller,
        uint256 reserve,
        uint40 endsAt,
        uint16 feeBps
    );
    event BidPlaced(
        address indexed collection, uint256 indexed tokenId, address indexed bidder, uint256 amount, uint40 newEndsAt
    );
    event AuctionSettled(
        address indexed collection, uint256 indexed tokenId, address indexed winner, uint256 amount, uint256 fee
    );
    event AuctionVoided(address indexed collection, uint256 indexed tokenId, address indexed winner, uint256 refund);
    event AuctionCancelled(address indexed collection, uint256 indexed tokenId);
    event Credited(address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    /// @notice #7611: one `batchBuy` call finished. `boughtCount <= itemCount`; `totalCharged` is the
    ///         sum of the prices of the items that succeeded (see `Sold` for the per-item detail).
    event BatchBuyExecuted(address indexed buyer, uint256 itemCount, uint256 boughtCount, uint256 totalCharged);

    // ---- errors
    error CollectionNotAllowed(address collection);
    error NotOwner(address collection, uint256 tokenId, address caller);
    error NotApproved(address collection, uint256 tokenId, address seller);
    error TokenLocked(address collection, uint256 tokenId);
    error AlreadyListed(address collection, uint256 tokenId);
    error AlreadyAuctioned(address collection, uint256 tokenId);
    error NotListed(address collection, uint256 tokenId);
    error ListingExpired(address collection, uint256 tokenId);
    error ListingStale(address collection, uint256 tokenId);
    error PriceChanged(uint256 expected, uint256 actual);
    error PriceTooLow(uint256 price, uint256 minPrice);
    error IncorrectPayment(uint256 required, uint256 sent);
    error NotSeller(address collection, uint256 tokenId, address caller);
    error NoOffer(address collection, uint256 tokenId, address offerer);
    error OfferExpired(address collection, uint256 tokenId, address offerer);
    error AmountChanged(uint256 expected, uint256 actual);
    error NoActiveAuction(address collection, uint256 tokenId);
    error AuctionEnded(address collection, uint256 tokenId, uint40 endsAt);
    error AuctionNotEnded(address collection, uint256 tokenId, uint40 endsAt);
    error AuctionHasBids(address collection, uint256 tokenId);
    error SellerCannotBid(address collection, uint256 tokenId);
    error BidTooLow(uint256 minRequired, uint256 sent);
    error ReserveNotMet(uint256 reserve, uint256 sent);
    error DurationOutOfRange(uint256 duration, uint256 min, uint256 max);
    error FeeBpsTooHigh(uint16 feeBps);
    error AntiSnipeExtendTooShort(uint32 window, uint32 extend);
    error NothingToWithdraw();
    error WithdrawFailed(address to, uint256 amount);
    error ZeroAddress();
    error ValueNotAccepted();
    /// @notice #7611: `batchBuy` requires at least one item.
    error EmptyBatch();
    /// @notice #7611: `batchBuy` requires `items.length <= MAX_BATCH_BUY_SIZE`.
    error BatchTooLarge(uint256 provided, uint256 max);

    // ---- constants
    function MIN_AUCTION_DURATION() external view returns (uint32); // 600s
    function MAX_AUCTION_DURATION() external view returns (uint32); // 30 days
    /// @notice #7611: upper bound on `batchBuy`'s `items.length` (policy cap, not a gas-derived limit —
    ///         see `docs/architecture/onchain-design.md` batch-buy section for the measured per-item cost).
    function MAX_BATCH_BUY_SIZE() external view returns (uint256);

    // ---- admin (DEFAULT_ADMIN_ROLE = timelock)
    function setCollectionAllowed(address collection, bool allowed) external;
    function setMarketConfig(MarketConfig calldata config) external;
    function pause() external; // PAUSER_ROLE, no delay (SR-62): blocks new listings/offers/bids only
    function unpause() external; // DEFAULT_ADMIN_ROLE only

    // ---- views
    function isCollectionAllowed(address collection) external view returns (bool);
    function marketConfig() external view returns (MarketConfig memory);
    function withdrawable(address who) external view returns (uint256);
    function getListing(address collection, uint256 tokenId) external view returns (Listing memory);
    function getOffer(address collection, uint256 tokenId, address offerer) external view returns (Offer memory);
    function getAuction(address collection, uint256 tokenId) external view returns (Auction memory);
    function isLocked(address collection, uint256 tokenId) external view returns (bool);

    // ---- listings (SR-30)
    function list(address collection, uint256 tokenId, uint256 price, uint40 expiresAt) external;
    function updateListingPrice(address collection, uint256 tokenId, uint256 newPrice) external;
    function cancelListing(address collection, uint256 tokenId) external; // seller or current owner
    function buy(address collection, uint256 tokenId, uint256 expectedPrice) external payable;
    /// @notice #7611: attempts every item; a listing that is gone, stale, mismatched-price, expired,
    ///         locked, or unaffordable from the remaining `msg.value` is SKIPPED, not reverted — see
    ///         `bought[i]` for the per-item outcome. Unspent `msg.value` (everything not charged to a
    ///         successful item) is credited to the caller's pull ledger (SR-31), never reverted or
    ///         stranded, even if every item in the batch failed.
    function batchBuy(BatchBuyItem[] calldata items)
        external
        payable
        returns (bool[] memory bought, uint256 totalCharged);

    // ---- offers (escrowed, WP-120)
    function placeOffer(address collection, uint256 tokenId, uint40 expiresAt) external payable;
    function cancelOffer(address collection, uint256 tokenId) external; // always allowed, even paused
    function acceptOffer(address collection, uint256 tokenId, address offerer, uint256 expectedAmount) external;

    // ---- English auctions (WP-121)
    function startAuction(address collection, uint256 tokenId, uint256 reserve, uint32 duration) external;
    function placeBid(address collection, uint256 tokenId) external payable;
    function settleAuction(address collection, uint256 tokenId) external; // permissionless, never paused
    function cancelAuction(address collection, uint256 tokenId) external; // seller only, zero bids only

    // ---- pull ledger (SR-31)
    function withdraw() external;
}
