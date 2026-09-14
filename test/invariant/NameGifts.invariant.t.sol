// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {NameGifts} from "../../src/parity/NameGifts.sol";
import {INameGifts} from "../../src/interfaces/INameGifts.sol";

/// @dev Plain mintable ERC-721 stand-in for an allow-listed gift collection — the invariant campaign
///      only needs many distinct `(collection, tokenId)` pairs with real transfer semantics, not the
///      specific soulbound/registration-expiry mechanics already covered unit-by-unit in
///      `NameGifts.t.sol`.
contract InvariantMockCollection is ERC721 {
    constructor() ERC721("Invariant Mock", "INV") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

/// @notice M3b escrow-custody invariant for `NameGifts` (`test/invariant/README.md` conventions):
///         for any sequence of create/claim/refund calls across many `(collection, tokenId)` pairs,
///         at all times exactly one of {escrow holds it (gift live), sender holds it (never created /
///         refunded), recipient holds it (claimed)} is true for every token this handler has ever
///         touched — no token is ever owned by two parties' expectations at once, and no token is
///         ever unrecoverable by both sender and recipient simultaneously.
///         - INV-GIFT-1: for every `(collection, tokenId)` this handler created a gift for,
///           `ownerOf(tokenId)` is exactly one of {address(gifts), original sender, recipient at
///           create time}, and matches the gift's own state (`claimed` ⇒ recipient,
///           `refunded` ⇒ sender, neither ⇒ escrow).
///         - INV-GIFT-2: a claimed-or-refunded gift never becomes claimable/refundable again
///           (checked by construction, same ghost-tracking approach as `Vouchers.invariant.t.sol`).
contract NameGiftsHandler is Test {
    NameGifts public gifts;
    InvariantMockCollection public collection;

    address[4] public actors;
    uint256[] public giftIds;
    mapping(uint256 => address) public originalSender;
    mapping(uint256 => address) public originalRecipient;
    mapping(uint256 => uint256) public giftTokenId;
    mapping(uint256 => bool) public claimedTwice;
    mapping(uint256 => bool) public refundedTwice;

    uint256 internal nextTokenId = 1;

    uint256 public calls;
    uint256 public successes;
    uint256 public createOk;
    uint256 public claimOk;
    uint256 public refundOk;

    constructor(NameGifts gifts_, InvariantMockCollection collection_, address[4] memory actors_) {
        gifts = gifts_;
        collection = collection_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 60 days));
        successes++;
    }

    function create(uint256 senderSeed, uint256 recipientSeed, uint256 delay) external {
        calls++;
        address sender_ = _actor(senderSeed);
        address recipient_ = _actor(recipientSeed);
        uint64 expiresAt = uint64(block.timestamp + bound(delay, 1, 3650 days));

        uint256 tokenId = nextTokenId++;
        collection.mint(sender_, tokenId);
        vm.prank(sender_);
        collection.approve(address(gifts), tokenId);

        vm.prank(sender_);
        try gifts.create(address(collection), tokenId, recipient_, expiresAt) returns (uint256 id) {
            giftIds.push(id);
            originalSender[id] = sender_;
            originalRecipient[id] = recipient_;
            giftTokenId[id] = tokenId;
            createOk++;
            successes++;
        } catch {}
    }

    function claim(uint256 idxSeed) external {
        calls++;
        if (giftIds.length == 0) return;
        uint256 id = giftIds[idxSeed % giftIds.length];
        INameGifts.Gift memory before = gifts.giftOf(id);
        bool wasTerminal = before.claimed || before.refunded;
        vm.prank(originalRecipient[id]);
        try gifts.claim(id) {
            claimOk++;
            successes++;
            if (wasTerminal) claimedTwice[id] = true;
        } catch {}
    }

    function refund(uint256 idxSeed) external {
        calls++;
        if (giftIds.length == 0) return;
        uint256 id = giftIds[idxSeed % giftIds.length];
        INameGifts.Gift memory before = gifts.giftOf(id);
        bool wasTerminal = before.claimed || before.refunded;
        vm.prank(originalSender[id]);
        try gifts.refund(id) {
            refundOk++;
            successes++;
            if (wasTerminal) refundedTwice[id] = true;
        } catch {}
    }

    function giftCount() external view returns (uint256) {
        return giftIds.length;
    }

    /// @dev For every gift ever created, the token's current owner must be exactly the party the
    ///      gift's own terminal state implies — never split between two claimants, never orphaned.
    function anyCustodyMismatch() external view returns (bool) {
        for (uint256 i = 0; i < giftIds.length; i++) {
            uint256 id = giftIds[i];
            INameGifts.Gift memory g = gifts.giftOf(id);
            address expected;
            if (g.claimed) {
                expected = originalRecipient[id];
            } else if (g.refunded) {
                expected = originalSender[id];
            } else {
                expected = address(gifts);
            }
            if (IERC721(collection).ownerOf(giftTokenId[id]) != expected) return true;
        }
        return false;
    }

    function anyDoubleClaimOrRefund() external view returns (bool) {
        for (uint256 i = 0; i < giftIds.length; i++) {
            if (claimedTwice[giftIds[i]] || refundedTwice[giftIds[i]]) return true;
        }
        return false;
    }
}

contract NameGiftsInvariantTest is StdInvariant, Test {
    NameGifts internal gifts;
    InvariantMockCollection internal collection;
    NameGiftsHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        address admin = makeAddr("giftAdmin");
        gifts = new NameGifts(NameGifts.Init({admin: admin, nameLocks: address(0)}));
        collection = new InvariantMockCollection();
        vm.prank(admin);
        gifts.setCollectionAllowed(address(collection), true);

        address[4] memory actors =
            [makeAddr("giftActor0"), makeAddr("giftActor1"), makeAddr("giftActor2"), makeAddr("giftActor3")];
        handler = new NameGiftsHandler(gifts, collection, actors);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = NameGiftsHandler.warp.selector;
        selectors[1] = NameGiftsHandler.create.selector;
        selectors[2] = NameGiftsHandler.claim.selector;
        selectors[3] = NameGiftsHandler.refund.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_GIFT1_custody_never_mismatches() public view {
        assertFalse(
            handler.anyCustodyMismatch(), "a gift token's owner diverged from escrow/sender/recipient expectation"
        );
    }

    function invariant_GIFT2_no_gift_claimed_or_refunded_twice() public view {
        assertFalse(handler.anyDoubleClaimOrRefund(), "a gift was claimed or refunded after already being terminal");
    }

    function afterInvariant() public view {
        if (handler.calls() < 12) return;
        assertGt(handler.successes(), 0, "handler never succeeded");
    }
}
