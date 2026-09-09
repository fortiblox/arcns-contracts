// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IArcNSMarket} from "../interfaces/IArcNSMarket.sol";
import {INameLocks} from "../interfaces/INameLocks.sol";
import {EpochGuard} from "../parity/EpochGuard.sol";
import {ArcNSConstants} from "../lib/ArcNSConstants.sol";

/// @title ArcNSMarket — C10, shared marketplace across every allow-listed ERC-721 (onchain-design §8)
/// @notice Non-custodial (SR-30): the NFT stays with the seller — `isApprovedForAll` to this contract
///         is required at `list`/`startAuction` time, and the actual move is a single `transferFrom`
///         inside `buy`/`acceptOffer`/`settleAuction`. On `HandleRegistry` (C1) that `transferFrom`
///         succeeds even for a soulbound handle because this contract holds `MARKET_ROLE` there
///         (`HandleRegistry._update` special-cases `hasRole(MARKET_ROLE, msg.sender)`) — no bespoke
///         "market move" entrypoint is needed. Pull-payment only (SR-31): every payout — seller
///         proceeds, bid/offer refunds, overpayment, the treasury fee — is credited to
///         `withdrawable[addr]`; `withdraw()` is the sole outbound value call, unlike
///         `HandleController`'s push-based treasury fee (deliberately different — a marketplace
///         counterparty is untrusted in a way the protocol's own treasury Safe is not, T-MKT-3).
///
/// @dev Roles: `DEFAULT_ADMIN_ROLE` = timelock (`setCollectionAllowed`, `setMarketConfig`, `unpause`);
///      `PAUSER_ROLE` = guardian (pause only, no delay, SR-62). Staleness/lock checks are delegated to
///      `EpochGuard` (native epoch/lock) and `INameLocks` (parity lock for collections with none of
///      their own, e.g. TLD registrars) — never re-implemented here (T-MKT-1).
contract ArcNSMarket is IArcNSMarket, AccessControl, Pausable, ReentrancyGuardTransient {
    // ---------------------------------------------------------------------------------------------
    // Types / constants / immutables
    // ---------------------------------------------------------------------------------------------

    /// @dev Constructor bundle (stack-too-deep avoidance, matches `HandleController.Init`).
    struct Init {
        address admin;
        address pauser;
        address treasury;
        address nameLocks; // may be `address(0)`: parity module not deployed yet (WP-125)
        MarketConfig config;
    }

    /// @dev A second `placeOffer` from the same offerer while one is still live reverts (design
    ///      judgment call, WP-120): the offerer must `cancelOffer` first. Not part of the frozen
    ///      `IArcNSMarket` interface (additive, does not change any interface-mandated behavior).
    error OfferAlreadyExists(address collection, uint256 tokenId, address offerer);

    bytes32 public constant PAUSER_ROLE = ArcNSConstants.PAUSER_ROLE;

    /// @inheritdoc IArcNSMarket
    uint32 public constant MIN_AUCTION_DURATION = 600 seconds;
    /// @inheritdoc IArcNSMarket
    uint32 public constant MAX_AUCTION_DURATION = 30 days;
    /// @inheritdoc IArcNSMarket
    /// @dev Policy cap (#7611), not a gas-derived ceiling: a single `buy` measures well under 200k gas
    ///      (see the gas table in the PR / `docs/architecture/onchain-design.md`), so even the cap's
    ///      worst case (every item valid) stays a small fraction of a block's gas limit; the cap exists
    ///      to keep a batch transaction's calldata and worst-case gas predictable for wallets/UX, not
    ///      because a larger batch would be unsafe.
    uint256 public constant MAX_BATCH_BUY_SIZE = 40;

    /// @notice Treasury Safe credited with the fee share of every sale (pull-based, SR-31).
    address public immutable treasury;
    /// @notice Parity lock module (WP-125) consulted for collections with no native lock of their
    ///         own (TLD registrars). `address(0)` disables this check — treated as "no parity locks
    ///         configured yet", not a misconfiguration, so this contract works before that module
    ///         lands.
    address public immutable nameLocks;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    MarketConfig private _marketConfig;

    /// @inheritdoc IArcNSMarket
    mapping(address collection => bool allowed) public isCollectionAllowed;
    /// @inheritdoc IArcNSMarket
    mapping(address who => uint256 amount) public withdrawable;

    /// @dev `Listing.seller == address(0)` is the "no listing" sentinel (a seller is always non-zero).
    mapping(address collection => mapping(uint256 tokenId => Listing)) private _listings;
    /// @dev `Offer.amount == 0` is the "no offer" sentinel (`placeOffer` requires `msg.value > 0`).
    mapping(address collection => mapping(uint256 tokenId => mapping(address offerer => Offer))) private _offers;
    /// @dev `Auction.seller == address(0)` is the "no auction" sentinel.
    mapping(address collection => mapping(uint256 tokenId => Auction)) private _auctions;

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    constructor(Init memory init) {
        if (init.admin == address(0) || init.pauser == address(0) || init.treasury == address(0)) {
            revert ZeroAddress();
        }
        _validateConfig(init.config);
        treasury = init.treasury;
        nameLocks = init.nameLocks;
        _marketConfig = init.config;
        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(PAUSER_ROLE, init.pauser);
        emit MarketConfigUpdated(init.config);
    }

    /// @dev Dust / mis-sent value is refused (SR-36). Every payable entrypoint is an explicit
    ///      function (`buy`, `placeOffer`, `placeBid`) — nothing is ever expected here.
    receive() external payable {
        revert ValueNotAccepted();
    }

    fallback() external payable {
        revert ValueNotAccepted();
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSMarket
    function marketConfig() external view returns (MarketConfig memory) {
        return _marketConfig;
    }

    /// @inheritdoc IArcNSMarket
    function getListing(address collection, uint256 tokenId) external view returns (Listing memory) {
        return _listings[collection][tokenId];
    }

    /// @inheritdoc IArcNSMarket
    function getOffer(address collection, uint256 tokenId, address offerer) external view returns (Offer memory) {
        return _offers[collection][tokenId][offerer];
    }

    /// @inheritdoc IArcNSMarket
    function getAuction(address collection, uint256 tokenId) external view returns (Auction memory) {
        return _auctions[collection][tokenId];
    }

    /// @inheritdoc IArcNSMarket
    /// @dev Native lock first (HandleRegistry, SR-14), parity `INameLocks` second (WP-125) — the
    ///      exact `_isLocked` composition, exposed read-only.
    function isLocked(address collection, uint256 tokenId) external view returns (bool) {
        return _isLocked(collection, tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // Admin (DEFAULT_ADMIN_ROLE = timelock)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSMarket
    function setCollectionAllowed(address collection, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (collection == address(0)) revert ZeroAddress();
        isCollectionAllowed[collection] = allowed;
        emit CollectionAllowed(collection, allowed);
    }

    /// @inheritdoc IArcNSMarket
    /// @dev Only `feeBps` is ever snapshotted per-listing/offer/auction (SR-33). `minPrice`,
    ///      `minBidIncrementBps`, `antiSnipeWindow` and `antiSnipeExtend` are read live at each call
    ///      site, so an admin config change applies immediately to in-flight offers/auctions too —
    ///      deliberate: none of those are a pricing term the counterparty relied on being fixed
    ///      the way a fee rate is.
    function setMarketConfig(MarketConfig calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateConfig(config);
        _marketConfig = config;
        emit MarketConfigUpdated(config);
    }

    /// @inheritdoc IArcNSMarket
    /// @dev SR-62: no delay, guardian-gated. Blocks only `list`/`placeOffer`/`startAuction`/`placeBid`
    ///      (SR-35) — every other state-changing function ignores `paused` entirely.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc IArcNSMarket
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _validateConfig(MarketConfig memory config) internal pure {
        if (config.feeBps > 10_000) revert FeeBpsTooHigh(config.feeBps);
        if (config.antiSnipeExtend < config.antiSnipeWindow) {
            revert AntiSnipeExtendTooShort(config.antiSnipeWindow, config.antiSnipeExtend);
        }
    }

    /// @dev Native lock (HandleRegistry, SR-14) first; parity `INameLocks` (WP-125) second, only when
    ///      configured. A collection with neither reports unlocked.
    function _isLocked(address collection, uint256 tokenId) internal view returns (bool) {
        return EpochGuard.nativeLocked(collection, tokenId)
            || (nameLocks != address(0) && INameLocks(nameLocks).isLocked(collection, tokenId));
    }

    // ---------------------------------------------------------------------------------------------
    // Listings (SR-30)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSMarket
    /// @dev Re-listing an already-listed `(collection, tokenId)` simply overwrites the prior listing
    ///      (design judgment call, WP-119) — unlike `startAuction`, a `Listing` never escrows funds,
    ///      so there is nothing to strand or refund by refreshing it in place; the seller could
    ///      equivalently `cancelListing` then `list` again for the identical end state.
    function list(address collection, uint256 tokenId, uint256 price, uint40 expiresAt)
        external
        whenNotPaused
        nonReentrant
    {
        if (!isCollectionAllowed[collection]) revert CollectionNotAllowed(collection);
        address owner_ = IERC721(collection).ownerOf(tokenId);
        if (owner_ != msg.sender) revert NotOwner(collection, tokenId, msg.sender);
        if (!IERC721(collection).isApprovedForAll(msg.sender, address(this))) {
            revert NotApproved(collection, tokenId, msg.sender);
        }
        if (_isLocked(collection, tokenId)) revert TokenLocked(collection, tokenId);
        if (_auctions[collection][tokenId].seller != address(0)) revert AlreadyAuctioned(collection, tokenId);

        MarketConfig memory cfg = _marketConfig;
        if (price < cfg.minPrice) revert PriceTooLow(price, cfg.minPrice);
        if (expiresAt <= block.timestamp) revert ListingExpired(collection, tokenId);

        EpochGuard.Snapshot memory snap = EpochGuard.snapshot(collection, tokenId);
        _listings[collection][tokenId] = Listing({
            seller: msg.sender,
            price: price,
            expiresAt: expiresAt,
            feeBps: cfg.feeBps,
            ownerAtList: snap.owner,
            epochAtList: snap.epoch
        });
        emit Listed(collection, tokenId, msg.sender, price, expiresAt, cfg.feeBps);
    }

    /// @inheritdoc IArcNSMarket
    /// @dev Not paused-gated (SR-35 lists only `list`/`placeOffer`/`startAuction`/`placeBid`): a
    ///      seller may always reprice an existing listing.
    function updateListingPrice(address collection, uint256 tokenId, uint256 newPrice) external nonReentrant {
        Listing storage l = _listings[collection][tokenId];
        if (l.seller == address(0)) revert NotListed(collection, tokenId);
        if (msg.sender != l.seller) revert NotSeller(collection, tokenId, msg.sender);
        if (newPrice < _marketConfig.minPrice) revert PriceTooLow(newPrice, _marketConfig.minPrice);
        l.price = newPrice;
        emit ListingPriceChanged(collection, tokenId, newPrice);
    }

    /// @inheritdoc IArcNSMarket
    /// @dev Always allowed, even paused (SR-35). Callable by the recorded seller OR the token's
    ///      CURRENT owner (parity with the X1 program): an out-of-market transfer leaves a stale
    ///      listing that `buy` already refuses (`ListingStale`, no theft risk) but would otherwise
    ///      hold the new owner hostage — unable to `list`/`startAuction` (`AlreadyListed`/
    ///      `AlreadyAuctioned` would never fire against a token they don't need to touch, but they'd
    ///      have no way to clear the stale row without this). `ownerOf` is wrapped in `try/catch` so a
    ///      burned/released token (HandleRegistry `release`) still lets the recorded seller clean up.
    function cancelListing(address collection, uint256 tokenId) external nonReentrant {
        Listing memory l = _listings[collection][tokenId];
        if (l.seller == address(0)) revert NotListed(collection, tokenId);
        bool ok = msg.sender == l.seller;
        if (!ok) {
            try IERC721(collection).ownerOf(tokenId) returns (address current) {
                ok = msg.sender == current;
            } catch {
                // token no longer exists — only the recorded seller may cancel (handled above).
            }
        }
        if (!ok) revert NotSeller(collection, tokenId, msg.sender);
        delete _listings[collection][tokenId];
        emit ListingCancelled(collection, tokenId);
    }

    /// @inheritdoc IArcNSMarket
    /// @dev SR-30/31/32/33: price guard first (`PriceChanged`) so a stale client quote is reported as
    ///      exactly that before any other check; `ListingStale` folds "current owner == recorded
    ///      seller" AND "epoch unchanged" into the one `EpochGuard.stillValid` check, since
    ///      `ownerAtList` was set to `seller` at `list` time. Checks-effects-interactions: the ledger
    ///      is credited and the listing deleted before the single `transferFrom` interaction: a
    ///      failure there (e.g. `HandleRegistry` recovery pending) reverts the whole call atomically,
    ///      which is a clean rollback (INV-5) — no void/refund path is needed here, unlike
    ///      `settleAuction`, because a reverted `buy` has escrowed nothing.
    function buy(address collection, uint256 tokenId, uint256 expectedPrice) external payable nonReentrant {
        Listing memory l = _listings[collection][tokenId];
        if (l.seller == address(0)) revert NotListed(collection, tokenId);
        if (l.price != expectedPrice) revert PriceChanged(expectedPrice, l.price);
        if (block.timestamp > l.expiresAt) revert ListingExpired(collection, tokenId);
        if (_isLocked(collection, tokenId)) revert TokenLocked(collection, tokenId);
        if (!EpochGuard.stillValid(
                EpochGuard.Snapshot({owner: l.ownerAtList, epoch: l.epochAtList}), collection, tokenId
            )) {
            revert ListingStale(collection, tokenId);
        }
        if (msg.value < l.price) revert IncorrectPayment(l.price, msg.value);

        uint256 fee = (l.price * l.feeBps) / 10_000;
        uint256 net = l.price - fee;
        uint256 excess = msg.value - l.price;

        delete _listings[collection][tokenId];
        if (fee > 0) {
            withdrawable[treasury] += fee;
            emit Credited(treasury, fee);
        }
        withdrawable[l.seller] += net;
        emit Credited(l.seller, net);
        if (excess > 0) {
            withdrawable[msg.sender] += excess;
            emit Credited(msg.sender, excess);
        }
        emit Sold(collection, tokenId, l.seller, msg.sender, l.price, fee);
        // `l.seller` is the validated listing's seller (checked non-zero and re-verified against
        // ownerOf/epoch above), never arbitrary caller input — slither cannot see the guard above.
        // slither-disable-next-line arbitrary-send-erc20
        IERC721(collection).transferFrom(l.seller, msg.sender, tokenId);
    }

    /// @inheritdoc IArcNSMarket
    /// @dev #7611: best-effort, never reverts on a per-item problem — see `_tryBuyOne`. `nonReentrant`
    ///      covers the whole batch (a single external re-entrant call could otherwise re-drive
    ///      `batchBuy`/`buy` against a `remaining` value snapshot that no longer matches this
    ///      contract's actual balance). Not `whenNotPaused`: like `buy`, a batch purchase acts on
    ///      EXISTING listings, never creates one, so it is outside the SR-35 pausable surface.
    function batchBuy(BatchBuyItem[] calldata items)
        external
        payable
        nonReentrant
        returns (bool[] memory bought, uint256 totalCharged)
    {
        uint256 n = items.length;
        if (n == 0) revert EmptyBatch();
        if (n > MAX_BATCH_BUY_SIZE) revert BatchTooLarge(n, MAX_BATCH_BUY_SIZE);

        bought = new bool[](n);
        uint256 remaining = msg.value;
        uint256 boughtCount = 0;
        for (uint256 i = 0; i < n; i++) {
            BatchBuyItem calldata item = items[i];
            (bool ok, uint256 price) = _tryBuyOne(item.collection, item.tokenId, item.expectedPrice, remaining);
            if (ok) {
                bought[i] = true;
                remaining -= price;
                totalCharged += price;
                boughtCount++;
            }
        }
        // Whatever was never charged to a successful item — including the ENTIRE value if every item
        // failed — is credited to the buyer's own pull ledger (SR-31): a batch purchase never reverts
        // and never strands funds, matching `buy`'s own excess-credit handling per item.
        //
        // slither: `reentrancy-no-eth` flags this write as coming after the loop's external calls
        // (each `_tryBuyOne`'s `transferFrom`). `remaining` is only known once every item has been
        // attempted, so this credit cannot be moved before the loop without a full two-pass rewrite
        // (validate every item, THEN transfer) — a materially riskier restructuring for a call path
        // `nonReentrant` (transient) already forecloses reentrancy on for the whole batch. See
        // SECURITY-NOTES.md's `reentrancy-no-eth` (M3, #7611) entry.
        if (remaining > 0) {
            // slither-disable-next-line reentrancy-no-eth
            withdrawable[msg.sender] += remaining;
            emit Credited(msg.sender, remaining);
        }
        emit BatchBuyExecuted(msg.sender, n, boughtCount, totalCharged);
    }

    /// @dev One line item of `batchBuy`: identical validation and settlement to `buy`, except every
    ///      "this specific item cannot be bought right now" condition returns `(false, 0)` instead of
    ///      reverting, so one bad item in a cart never blocks the rest (docs/architecture/onchain-design.md
    ///      batch-buy section). `valueAvailable` is the caller's REMAINING unspent `msg.value` at this
    ///      point in the batch, not the full `msg.value` — each item can only spend what earlier items
    ///      in the same batch left behind.
    /// @dev #7611 fix (2026-09-09): the `transferFrom` is wrapped in `try/catch`, mirroring
    ///      `settleAuction`'s exact pattern, because every OTHER skip condition above (price/expiry/lock/
    ///      `EpochGuard.stillValid`) is blind to ERC-721 operator-approval state — a seller can revoke
    ///      `setApprovalForAll` on the market at any time after listing (a completely normal, always-
    ///      available action) without failing any of those checks, so only the transfer attempt itself
    ///      can discover it. Fee/proceeds accounting is only applied INSIDE the success branch, after the
    ///      transfer is confirmed, so a failed transfer never charges the buyer or credits the seller/
    ///      treasury for an item that was never actually delivered; the listing stays deleted either way
    ///      (mirrors `settleAuction` permanently voiding an undeliverable auction rather than leaving a
    ///      listing dangling for a seller who has already signalled, by revoking approval, that they
    ///      don't intend to honor it right now). On failure this returns `(false, 0)` exactly like every
    ///      other skip condition: `batchBuy` never reverts the whole cart over it, and the buyer's
    ///      earmarked value for this item flows back to them via `batchBuy`'s own unspent-`remaining`
    ///      refund — no separate refund path needed here.
    function _tryBuyOne(address collection, uint256 tokenId, uint256 expectedPrice, uint256 valueAvailable)
        private
        returns (bool ok, uint256 price)
    {
        Listing memory l = _listings[collection][tokenId];
        if (l.seller == address(0)) return (false, 0);
        if (l.price != expectedPrice) return (false, 0);
        if (block.timestamp > l.expiresAt) return (false, 0);
        if (_isLocked(collection, tokenId)) return (false, 0);
        if (!EpochGuard.stillValid(
                EpochGuard.Snapshot({owner: l.ownerAtList, epoch: l.epochAtList}), collection, tokenId
            )) {
            return (false, 0);
        }
        if (valueAvailable < l.price) return (false, 0);

        delete _listings[collection][tokenId];

        // Same guard as `buy`: `l.seller` comes from a validated listing, re-verified against
        // ownerOf/epoch immediately above, never arbitrary caller input.
        // slither-disable-next-line arbitrary-send-erc20
        try IERC721(collection).transferFrom(l.seller, msg.sender, tokenId) {
            uint256 fee = (l.price * l.feeBps) / 10_000;
            uint256 net = l.price - fee;
            price = l.price;
            if (fee > 0) {
                withdrawable[treasury] += fee;
                emit Credited(treasury, fee);
            }
            withdrawable[l.seller] += net;
            emit Credited(l.seller, net);
            emit Sold(collection, tokenId, l.seller, msg.sender, l.price, fee);
            return (true, price);
        } catch {
            // Transfer failed after passing every other check (e.g. approval revoked post-listing):
            // skip this item exactly like any other unbuyable condition above — no charge, no credit,
            // the earmarked value comes back to the buyer via `batchBuy`'s `remaining` refund.
            return (false, 0);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Offers (escrowed, WP-120)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSMarket
    /// @dev No lock check at creation (parity with the X1 `place_offer`, which only checks
    ///      pause/tokenized) — the lock is re-verified at `acceptOffer` time, which is the only point
    ///      it can matter. A second live offer from the same `(collection, tokenId, msg.sender)`
    ///      reverts `OfferAlreadyExists` rather than silently replacing it (design judgment call,
    ///      WP-120, closest EVM analog of the X1 program's `init`-constrained PDA, which fails the
    ///      same way on a second `place_offer`): call `cancelOffer` first to change an offer's amount.
    function placeOffer(address collection, uint256 tokenId, uint40 expiresAt)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        if (!isCollectionAllowed[collection]) revert CollectionNotAllowed(collection);
        MarketConfig memory cfg = _marketConfig;
        if (msg.value == 0 || msg.value < cfg.minPrice) revert PriceTooLow(msg.value, cfg.minPrice);
        if (expiresAt <= block.timestamp) revert OfferExpired(collection, tokenId, msg.sender);
        if (_offers[collection][tokenId][msg.sender].amount != 0) {
            revert OfferAlreadyExists(collection, tokenId, msg.sender);
        }

        _offers[collection][tokenId][msg.sender] =
            Offer({offerer: msg.sender, amount: msg.value, expiresAt: expiresAt, feeBps: cfg.feeBps});
        emit OfferPlaced(collection, tokenId, msg.sender, msg.value, expiresAt);
    }

    /// @inheritdoc IArcNSMarket
    /// @dev Always allowed, even paused (SR-35, SR-31): escrowed funds must always be reclaimable.
    function cancelOffer(address collection, uint256 tokenId) external nonReentrant {
        Offer memory o = _offers[collection][tokenId][msg.sender];
        if (o.amount == 0) revert NoOffer(collection, tokenId, msg.sender);
        delete _offers[collection][tokenId][msg.sender];
        withdrawable[msg.sender] += o.amount;
        emit Credited(msg.sender, o.amount);
        emit OfferCancelled(collection, tokenId, msg.sender);
    }

    /// @inheritdoc IArcNSMarket
    /// @dev Caller must be the CURRENT owner (not the recorded seller of any coexisting listing — an
    ///      offer is independent of a listing, per the M3 design). A coexisting listing is left as-is:
    ///      it goes stale (`ownerAtList` now differs) and `buy` will refuse it with `ListingStale`; the
    ///      new owner (or the old recorded seller) can `cancelListing` at any time. No mutual-exclusion
    ///      check against a live auction either — accepting an offer while an auction is in flight
    ///      changes `ownerOf` out from under it, and `settleAuction`'s own deliverability check
    ///      (`EpochGuard.stillValid` against `ownerAtStart`) then VOIDs that auction with a full bidder
    ///      refund (SR-34) rather than letting it deliver a name this contract no longer holds
    ///      approval-derived authority to move — the safety property already falls out of
    ///      `settleAuction`'s own guard, so no separate check is needed here.
    function acceptOffer(address collection, uint256 tokenId, address offerer, uint256 expectedAmount)
        external
        nonReentrant
    {
        Offer memory o = _offers[collection][tokenId][offerer];
        if (o.amount == 0) revert NoOffer(collection, tokenId, offerer);
        if (o.amount != expectedAmount) revert AmountChanged(expectedAmount, o.amount);
        if (block.timestamp > o.expiresAt) revert OfferExpired(collection, tokenId, offerer);
        address owner_ = IERC721(collection).ownerOf(tokenId);
        if (owner_ != msg.sender) revert NotOwner(collection, tokenId, msg.sender);
        if (_isLocked(collection, tokenId)) revert TokenLocked(collection, tokenId);

        uint256 fee = (o.amount * o.feeBps) / 10_000;
        uint256 net = o.amount - fee;

        delete _offers[collection][tokenId][offerer];
        if (fee > 0) {
            withdrawable[treasury] += fee;
            emit Credited(treasury, fee);
        }
        withdrawable[msg.sender] += net;
        emit Credited(msg.sender, net);
        emit OfferAccepted(collection, tokenId, offerer, msg.sender, o.amount, fee);
        IERC721(collection).transferFrom(msg.sender, offerer, tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // English auctions (WP-121)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSMarket
    function startAuction(address collection, uint256 tokenId, uint256 reserve, uint32 duration)
        external
        whenNotPaused
        nonReentrant
    {
        if (!isCollectionAllowed[collection]) revert CollectionNotAllowed(collection);
        address owner_ = IERC721(collection).ownerOf(tokenId);
        if (owner_ != msg.sender) revert NotOwner(collection, tokenId, msg.sender);
        if (!IERC721(collection).isApprovedForAll(msg.sender, address(this))) {
            revert NotApproved(collection, tokenId, msg.sender);
        }
        if (_isLocked(collection, tokenId)) revert TokenLocked(collection, tokenId);
        if (_listings[collection][tokenId].seller != address(0)) revert AlreadyListed(collection, tokenId);
        if (_auctions[collection][tokenId].seller != address(0)) revert AlreadyAuctioned(collection, tokenId);
        if (duration < MIN_AUCTION_DURATION || duration > MAX_AUCTION_DURATION) {
            revert DurationOutOfRange(duration, MIN_AUCTION_DURATION, MAX_AUCTION_DURATION);
        }

        // No `minPrice` floor on `reserve` (design judgment call, WP-121, parity with the X1
        // program's `reserve: u64`, which has none either): a 0-reserve auction is meaningful — the
        // `placeBid` first-bid rule (`> 0`) already forecloses a free/dust auction on its own, so
        // gating `reserve` here too would only forbid the legitimate "start the bidding at zero" case.
        MarketConfig memory cfg = _marketConfig;

        EpochGuard.Snapshot memory snap = EpochGuard.snapshot(collection, tokenId);
        uint40 endsAt = uint40(block.timestamp + duration);
        _auctions[collection][tokenId] = Auction({
            seller: msg.sender,
            reserve: reserve,
            highestBid: 0,
            highestBidder: address(0),
            endsAt: endsAt,
            feeBps: cfg.feeBps,
            ownerAtStart: snap.owner,
            epochAtStart: snap.epoch
        });
        emit AuctionStarted(collection, tokenId, msg.sender, reserve, endsAt, cfg.feeBps);
    }

    /// @inheritdoc IArcNSMarket
    /// @dev SR-34: first bid must be `> 0` and `>= reserve` (`ReserveNotMet`); every later bid must
    ///      clear `highestBid + max(1, highestBid * minBidIncrementBps / 10_000)` (`BidTooLow`) — the
    ///      `max(1, ...)` matches the X1 program so a tiny `highestBid` still requires a strictly
    ///      higher bid. The previous highest bidder is credited (never pushed, SR-31/T-MKT-3) before
    ///      the anti-snipe extension, which can only ever push `endsAt` out (INV-6): `max(current,
    ///      now + antiSnipeExtend)`.
    function placeBid(address collection, uint256 tokenId) external payable whenNotPaused nonReentrant {
        Auction storage a = _auctions[collection][tokenId];
        if (a.seller == address(0)) revert NoActiveAuction(collection, tokenId);
        if (block.timestamp >= a.endsAt) revert AuctionEnded(collection, tokenId, a.endsAt);
        if (msg.sender == a.seller) revert SellerCannotBid(collection, tokenId);

        address prevBidder = a.highestBidder;
        uint256 prevBid = a.highestBid;
        if (prevBidder == address(0)) {
            if (msg.value == 0) revert BidTooLow(1, 0);
            if (msg.value < a.reserve) revert ReserveNotMet(a.reserve, msg.value);
        } else {
            uint256 increment = (prevBid * _marketConfig.minBidIncrementBps) / 10_000;
            if (increment == 0) increment = 1;
            uint256 minRequired = prevBid + increment;
            if (msg.value < minRequired) revert BidTooLow(minRequired, msg.value);
        }

        a.highestBid = msg.value;
        a.highestBidder = msg.sender;
        if (prevBidder != address(0)) {
            withdrawable[prevBidder] += prevBid;
            emit Credited(prevBidder, prevBid);
        }

        uint40 newEndsAt = a.endsAt;
        if (uint256(a.endsAt) - block.timestamp <= _marketConfig.antiSnipeWindow) {
            uint40 extended = uint40(block.timestamp + _marketConfig.antiSnipeExtend);
            if (extended > newEndsAt) {
                newEndsAt = extended;
                a.endsAt = extended;
            }
        }
        emit BidPlaced(collection, tokenId, msg.sender, msg.value, newEndsAt);
    }

    /// @inheritdoc IArcNSMarket
    /// @dev Permissionless, never paused (SR-34/35). Always requires `block.timestamp >= endsAt`; a
    ///      zero-bid auction past its end is simply cleared with no transfer, reusing the
    ///      `AuctionCancelled` event shape (design judgment call, WP-121) — there is nothing to
    ///      settle, and this keeps a forgotten no-bid auction from staying stuck forever. When there
    ///      is a highest bid, deliverability (`ownerOf == seller` at the ORIGINAL snapshot, via
    ///      `EpochGuard.stillValid`, plus not locked) is re-checked and the `transferFrom` itself is
    ///      wrapped in `try/catch`: either failing VOIDS the auction — full refund to the highest
    ///      bidder, no fee, no transfer, `AuctionVoided` (SR-34) — instead of reverting, because a
    ///      keeper-callable settlement must never be able to get permanently stuck on a name that
    ///      became undeliverable after the auction started (e.g. a `HandleRegistry` recovery
    ///      completed, or completed while pending, mid-auction — INV-5). The auction row is deleted
    ///      before either the deliverability check or the transfer attempt so this function can never
    ///      be re-entered into double-processing the same auction, even though `nonReentrant` already
    ///      forecloses that.
    function settleAuction(address collection, uint256 tokenId) external nonReentrant {
        Auction memory a = _auctions[collection][tokenId];
        if (a.seller == address(0)) revert NoActiveAuction(collection, tokenId);
        if (block.timestamp < a.endsAt) revert AuctionNotEnded(collection, tokenId, a.endsAt);

        delete _auctions[collection][tokenId];

        if (a.highestBidder == address(0)) {
            emit AuctionCancelled(collection, tokenId);
            return;
        }

        bool deliverable = !_isLocked(collection, tokenId);
        if (deliverable) {
            try IERC721(collection).ownerOf(tokenId) returns (address current) {
                deliverable = current == a.seller
                    && EpochGuard.stillValid(
                        EpochGuard.Snapshot({owner: a.ownerAtStart, epoch: a.epochAtStart}), collection, tokenId
                    );
            } catch {
                deliverable = false;
            }
        }

        if (deliverable) {
            // `a.seller`/`a.highestBidder` come from the validated Auction row (non-zero-seller
            // checked above, deliverability re-verified against ownerOf/epoch/lock just above), never
            // arbitrary caller input — slither cannot see the guards above this call.
            // slither-disable-next-line arbitrary-send-erc20
            try IERC721(collection).transferFrom(a.seller, a.highestBidder, tokenId) {
                uint256 fee = (a.highestBid * a.feeBps) / 10_000;
                uint256 net = a.highestBid - fee;
                if (fee > 0) {
                    withdrawable[treasury] += fee;
                    emit Credited(treasury, fee);
                }
                withdrawable[a.seller] += net;
                emit Credited(a.seller, net);
                emit AuctionSettled(collection, tokenId, a.highestBidder, a.highestBid, fee);
                return;
            } catch {
                deliverable = false;
            }
        }

        // Undeliverable (stale owner/epoch, locked, or the transfer itself reverted — e.g. a
        // HandleRegistry recovery in flight): void, refund in full, no fee (SR-34).
        withdrawable[a.highestBidder] += a.highestBid;
        emit Credited(a.highestBidder, a.highestBid);
        emit AuctionVoided(collection, tokenId, a.highestBidder, a.highestBid);
    }

    /// @inheritdoc IArcNSMarket
    /// @dev Seller only, zero bids only (SR-34) — once a bidder has escrowed a bid, only
    ///      `settleAuction` may end the auction. Never paused (SR-35).
    function cancelAuction(address collection, uint256 tokenId) external nonReentrant {
        Auction memory a = _auctions[collection][tokenId];
        if (a.seller == address(0)) revert NoActiveAuction(collection, tokenId);
        if (msg.sender != a.seller) revert NotSeller(collection, tokenId, msg.sender);
        if (a.highestBidder != address(0)) revert AuctionHasBids(collection, tokenId);
        delete _auctions[collection][tokenId];
        emit AuctionCancelled(collection, tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // Pull ledger (SR-31)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSMarket
    /// @dev Not paused-gated (SR-35): withdrawals must always work.
    function withdraw() external nonReentrant {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert WithdrawFailed(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }
}
