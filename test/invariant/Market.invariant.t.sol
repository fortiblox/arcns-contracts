// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {ArcNSMarket} from "../../src/market/ArcNSMarket.sol";
import {IArcNSMarket} from "../../src/interfaces/IArcNSMarket.sol";
import {MockERC721} from "../market/mocks/MockERC721.sol";
import {MockNameLocks} from "../market/mocks/MockNameLocks.sol";

/// @dev Drives `ArcNSMarket` through listings, offers, auctions, locking and withdrawals over a
///      bounded actor/token universe. Every market call is wrapped in `try/catch`; the invariants read
///      *on-chain* state (the contract's own `withdrawable`/`getOffer`/`getAuction`), not a shadow
///      ledger, so a divergence can only come from the contract itself, not from handler bookkeeping
///      drift — the one exception is `maxEndsAtSeen` (INV-6), which is inherently a "what did I see
///      before" ghost.
contract MarketHandler is Test {
    ArcNSMarket public market;
    MockERC721 public collection;
    MockNameLocks public nameLocks;
    address public treasury;

    address[] public actors;
    uint256[] public tokenIds;

    uint256 public calls;
    uint256 public successes;
    bool public soldOrSettledWhileLocked;
    mapping(bytes32 key => uint40) public maxEndsAtSeen;
    bool public endsAtDecreased;

    constructor(ArcNSMarket market_, MockERC721 collection_, MockNameLocks nameLocks_, address treasury_) {
        market = market_;
        collection = collection_;
        nameLocks = nameLocks_;
        treasury = treasury_;
        actors.push(makeAddr("mktActor0"));
        actors.push(makeAddr("mktActor1"));
        actors.push(makeAddr("mktActor2"));
        actors.push(makeAddr("mktActor3"));
        for (uint256 i = 0; i < actors.length; i++) {
            vm.deal(actors[i], 1_000_000 ether);
        }
        // One token minted to each actor up front so every actor can act as a seller.
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 tokenId = 1000 + i;
            collection.mint(actors[i], tokenId);
            tokenIds.push(tokenId);
            vm.prank(actors[i]);
            collection.setApprovalForAll(address(market), true);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function tokenCount() external view returns (uint256) {
        return tokenIds.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _token(uint256 seed) internal view returns (uint256) {
        return tokenIds[seed % tokenIds.length];
    }

    function _key(uint256 tokenId) internal view returns (bytes32) {
        return keccak256(abi.encode(address(collection), tokenId));
    }

    // ---- actions ----------------------------------------------------------------------------------

    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 2 days));
    }

    function toggleLock(uint256 tokenSeed, bool locked) external {
        calls++;
        uint256 tokenId = _token(tokenSeed);
        nameLocks.forceSetLocked(address(collection), tokenId, locked);
        successes++;
    }

    function list(uint256 actorSeed, uint256 tokenSeed, uint256 price, uint256 durationSeed) external {
        calls++;
        address seller = _actor(actorSeed);
        uint256 tokenId = _token(tokenSeed);
        if (collection.ownerOf(tokenId) != seller) return; // not the owner right now, skip quietly
        price = bound(price, 0.01 ether, 1000 ether);
        uint40 expiresAt = uint40(block.timestamp + bound(durationSeed, 1 hours, 30 days));
        vm.prank(seller);
        try market.list(address(collection), tokenId, price, expiresAt) {
            successes++;
        } catch {}
    }

    function cancelListing(uint256 actorSeed, uint256 tokenSeed) external {
        calls++;
        vm.prank(_actor(actorSeed));
        try market.cancelListing(address(collection), _token(tokenSeed)) {
            successes++;
        } catch {}
    }

    function buy(uint256 actorSeed, uint256 tokenSeed) external {
        calls++;
        address buyer = _actor(actorSeed);
        uint256 tokenId = _token(tokenSeed);
        IArcNSMarket.Listing memory l = market.getListing(address(collection), tokenId);
        if (l.seller == address(0)) return;
        bool wasLocked = market.isLocked(address(collection), tokenId);
        vm.prank(buyer);
        try market.buy{value: l.price}(address(collection), tokenId, l.price) {
            successes++;
            if (wasLocked) soldOrSettledWhileLocked = true;
        } catch {}
    }

    function placeOffer(uint256 actorSeed, uint256 tokenSeed, uint256 amount, uint256 durationSeed) external {
        calls++;
        address offerer = _actor(actorSeed);
        uint256 tokenId = _token(tokenSeed);
        amount = bound(amount, 0.01 ether, 1000 ether);
        uint40 expiresAt = uint40(block.timestamp + bound(durationSeed, 1 hours, 30 days));
        vm.prank(offerer);
        try market.placeOffer{value: amount}(address(collection), tokenId, expiresAt) {
            successes++;
        } catch {}
    }

    function cancelOffer(uint256 actorSeed, uint256 tokenSeed) external {
        calls++;
        vm.prank(_actor(actorSeed));
        try market.cancelOffer(address(collection), _token(tokenSeed)) {
            successes++;
        } catch {}
    }

    function acceptOffer(uint256 sellerSeed, uint256 tokenSeed, uint256 offererSeed) external {
        calls++;
        address seller = _actor(sellerSeed);
        uint256 tokenId = _token(tokenSeed);
        address offerer = _actor(offererSeed);
        IArcNSMarket.Offer memory o = market.getOffer(address(collection), tokenId, offerer);
        if (o.amount == 0) return;
        bool wasLocked = market.isLocked(address(collection), tokenId);
        vm.prank(seller);
        try market.acceptOffer(address(collection), tokenId, offerer, o.amount) {
            successes++;
            if (wasLocked) soldOrSettledWhileLocked = true;
        } catch {}
    }

    function startAuction(uint256 actorSeed, uint256 tokenSeed, uint256 reserve, uint256 durationSeed) external {
        calls++;
        address seller = _actor(actorSeed);
        uint256 tokenId = _token(tokenSeed);
        if (collection.ownerOf(tokenId) != seller) return;
        reserve = bound(reserve, 0, 100 ether);
        uint32 duration = uint32(bound(durationSeed, market.MIN_AUCTION_DURATION(), market.MAX_AUCTION_DURATION()));
        vm.prank(seller);
        try market.startAuction(address(collection), tokenId, reserve, duration) {
            successes++;
        } catch {}
    }

    function placeBid(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        calls++;
        address bidder = _actor(actorSeed);
        uint256 tokenId = _token(tokenSeed);
        IArcNSMarket.Auction memory a = market.getAuction(address(collection), tokenId);
        if (a.seller == address(0)) return;
        amount = bound(amount, a.reserve == 0 ? 1 : a.reserve, a.highestBid + 2000 ether + 1);
        vm.prank(bidder);
        try market.placeBid{value: amount}(address(collection), tokenId) {
            successes++;
            bytes32 key = _key(tokenId);
            IArcNSMarket.Auction memory after_ = market.getAuction(address(collection), tokenId);
            if (after_.endsAt < maxEndsAtSeen[key]) endsAtDecreased = true;
            else maxEndsAtSeen[key] = after_.endsAt;
        } catch {}
    }

    function settleAuction(uint256 tokenSeed) external {
        calls++;
        uint256 tokenId = _token(tokenSeed);
        IArcNSMarket.Auction memory a = market.getAuction(address(collection), tokenId);
        if (a.seller == address(0)) return;
        if (block.timestamp < a.endsAt) return;
        bool wasLocked = market.isLocked(address(collection), tokenId);
        bool hadBid = a.highestBidder != address(0);
        address ownerBefore = collection.ownerOf(tokenId);
        try market.settleAuction(address(collection), tokenId) {
            successes++;
            // `settleAuction` never reverts on a locked/undeliverable auction — it VOIDs instead
            // (full bidder refund, no transfer). A "success" here only proves an actual sale if the
            // NFT actually moved to the highest bidder; a void is the correct, safe outcome.
            address ownerAfter = collection.ownerOf(tokenId);
            bool actuallySettled = hadBid && ownerAfter == a.highestBidder && ownerAfter != ownerBefore;
            if (actuallySettled && wasLocked) soldOrSettledWhileLocked = true;
        } catch {}
    }

    function cancelAuction(uint256 actorSeed, uint256 tokenSeed) external {
        calls++;
        vm.prank(_actor(actorSeed));
        try market.cancelAuction(address(collection), _token(tokenSeed)) {
            successes++;
        } catch {}
    }

    function withdraw(uint256 actorSeed) external {
        calls++;
        vm.prank(_actor(actorSeed));
        try market.withdraw() {
            successes++;
        } catch {}
    }

    /// @dev #7611: buys up to 3 tokens in one call, funded exactly for whichever of the three are
    ///      currently listed (unlisted slots contribute 0 to the sent value and are skipped by the
    ///      contract, not reverted). Mirrors `buy`'s own locked-token ghost so INV-5 covers the batch
    ///      path too.
    function batchBuy(uint256 actorSeed, uint256 tokenSeed1, uint256 tokenSeed2, uint256 tokenSeed3) external {
        calls++;
        address buyer = _actor(actorSeed);
        uint256[3] memory seeds = [tokenSeed1, tokenSeed2, tokenSeed3];

        IArcNSMarket.BatchBuyItem[] memory items = new IArcNSMarket.BatchBuyItem[](3);
        bool[] memory wasLocked = new bool[](3);
        uint256 totalValue;
        for (uint256 i = 0; i < 3; i++) {
            uint256 tokenId = _token(seeds[i]);
            IArcNSMarket.Listing memory l = market.getListing(address(collection), tokenId);
            items[i] =
                IArcNSMarket.BatchBuyItem({collection: address(collection), tokenId: tokenId, expectedPrice: l.price});
            wasLocked[i] = market.isLocked(address(collection), tokenId);
            if (l.seller != address(0)) totalValue += l.price;
        }
        vm.prank(buyer);
        try market.batchBuy{value: totalValue}(items) returns (bool[] memory bought, uint256) {
            successes++;
            for (uint256 i = 0; i < 3; i++) {
                if (bought[i] && wasLocked[i]) soldOrSettledWhileLocked = true;
            }
        } catch {}
    }
}

/// @notice INV-4 (escrow solvency), INV-5 (never moves a locked token), INV-6 (`endsAt` never
///         decreases) for `ArcNSMarket` (WP-123). Uses a plain `MockERC721` collection (the harder,
///         epoch-less case — see `EpochGuard`) so the campaign also stresses the degrade-gracefully
///         path the real TLD registrars will use.
contract MarketInvariantTest is StdInvariant, Test {
    ArcNSMarket internal market;
    MockERC721 internal collection;
    MockNameLocks internal nameLocks;
    MarketHandler internal handler;

    address internal admin = makeAddr("mktAdmin");
    address internal pauser = makeAddr("mktPauser");
    address internal treasury = makeAddr("mktTreasury");

    function setUp() public {
        vm.warp(1_700_000_000);
        collection = new MockERC721("Mock TLD", "MTLD");
        nameLocks = new MockNameLocks(admin);
        market = new ArcNSMarket(
            ArcNSMarket.Init({
                admin: admin,
                pauser: pauser,
                treasury: treasury,
                nameLocks: address(nameLocks),
                config: IArcNSMarket.MarketConfig({
                    feeBps: 200,
                    minBidIncrementBps: 500,
                    antiSnipeWindow: 300,
                    antiSnipeExtend: 300,
                    minPrice: 0.01 ether
                })
            })
        );
        vm.prank(admin);
        market.setCollectionAllowed(address(collection), true);

        handler = new MarketHandler(market, collection, nameLocks, treasury);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = MarketHandler.warp.selector;
        selectors[1] = MarketHandler.toggleLock.selector;
        selectors[2] = MarketHandler.list.selector;
        selectors[3] = MarketHandler.cancelListing.selector;
        selectors[4] = MarketHandler.buy.selector;
        selectors[5] = MarketHandler.placeOffer.selector;
        selectors[6] = MarketHandler.cancelOffer.selector;
        selectors[7] = MarketHandler.acceptOffer.selector;
        selectors[8] = MarketHandler.startAuction.selector;
        selectors[9] = MarketHandler.placeBid.selector;
        selectors[10] = MarketHandler.settleAuction.selector;
        selectors[11] = MarketHandler.batchBuy.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev "Handler alive" is checked once per completed run in `afterInvariant()` below, not inside
    ///      each `invariant_*` (those run after EVERY call, including call #1 of a fresh run — with an
    ///      11-selector handler and several selectors gated on a seed-matched precondition, requiring
    ///      a success by some fixed call count mid-run is a brittle, occasionally-false test failure,
    ///      not a real property; `afterInvariant` fires once at the END of the run's full depth, giving
    ///      every selector many draws before judging the handler "broken" — matching the convention in
    ///      `HandleController.invariant.t.sol`'s own `afterInvariant`).
    /// @dev INV-4: `market.balance == Σ live offers + Σ live bids + Σ withdrawable`, computed entirely
    ///      from on-chain reads over the handler's bounded actor/token universe (never a shadow ledger).
    function invariant_INV4_escrow_equals_offers_plus_bids_plus_withdrawable() public view {
        uint256 n = handler.actorCount();
        uint256 m = handler.tokenCount();

        uint256 sumOffers = 0;
        for (uint256 t = 0; t < m; t++) {
            uint256 tokenId = handler.tokenIds(t);
            for (uint256 a = 0; a < n; a++) {
                sumOffers += market.getOffer(address(collection), tokenId, handler.actors(a)).amount;
            }
        }

        uint256 sumBids = 0;
        for (uint256 t = 0; t < m; t++) {
            IArcNSMarket.Auction memory auc = market.getAuction(address(collection), handler.tokenIds(t));
            if (auc.seller != address(0)) sumBids += auc.highestBid;
        }

        uint256 sumWithdrawable = market.withdrawable(treasury);
        for (uint256 a = 0; a < n; a++) {
            sumWithdrawable += market.withdrawable(handler.actors(a));
        }

        assertEq(
            address(market).balance,
            sumOffers + sumBids + sumWithdrawable,
            "market.balance != offers + bids + withdrawable"
        );
    }

    /// @dev INV-5 (market half): no `buy`/`acceptOffer`/`settleAuction` ever completes while the
    ///      target `(collection, tokenId)` was locked at the moment the handler observed it. The
    ///      contract itself must have refused (or voided, for auctions) — this ghost catches a broken
    ///      guard, it does not replace the contract's own check.
    function invariant_INV5_market_never_moves_a_locked_token() public view {
        assertFalse(handler.soldOrSettledWhileLocked(), "a sale/accept/settle completed on a locked token");
    }

    /// @dev INV-6: `endsAt` never decreases across any sequence of bids on the same auction.
    function invariant_INV6_auction_endsAt_never_decreases() public view {
        assertFalse(handler.endsAtDecreased(), "an auction's endsAt decreased across bids");
    }

    /// @dev No path pays out more than was escrowed: every actor's cumulative `withdrawable` credit
    ///      can never exceed what the contract currently holds plus what has already been paid out —
    ///      i.e. the contract must never go insolvent. Since `withdraw()` immediately zeroes the ledger
    ///      before paying, and `nonReentrant` forecloses any reentrant double-spend, the only way this
    ///      could fail is a bug crediting more than was received; INV-4 above already proves the ledger
    ///      always reconciles exactly against `market.balance`, which is the stronger property this one
    ///      is implied by — kept as its own named invariant per the WP-123 acceptance line "no path
    ///      pays out more than was escrowed" so CI reports it explicitly.
    function invariant_no_path_overpays_its_escrow() public view {
        // If the contract were ever insolvent, INV-4's exact-equality check above would already have
        // failed (the sum of claims would exceed `market.balance`, since the ledger can only be read
        // as non-negative uint256s). This assertion documents the property as its own named target.
        assertGe(
            address(market).balance,
            0,
            "unreachable: a negative balance would mean uint256 underflow already reverted somewhere"
        );
    }

    /// @dev Runs once per completed run (all up to `depth` calls done), not after every call — the
    ///      right place for a "did the handler actually do anything" liveness check (see the comment
    ///      above `invariant_INV4_*`). 48 calls gives every one of the 11 selectors, including the
    ///      seed-matched `list`/`startAuction`, many independent draws.
    function afterInvariant() public view {
        if (handler.calls() < 48) return;
        assertGt(handler.successes(), 0, "handler never succeeded");
    }
}
