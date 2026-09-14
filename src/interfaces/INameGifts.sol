// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title INameGifts — name-gifting escrow across both namespaces (onchain-design §1, M3b)
/// @notice Keyed by `(collection, tokenId)`, the exact multi-collection shape `IArcNSMarket` already
///         proves for `HandleRegistry` (C1, soulbound ERC-721) and every `TldRegistrar` (C4, verbatim
///         ens-contracts `BaseRegistrarImplementation` ERC-721) side by side: one contract serves both
///         namespaces, no per-namespace reimplementation.
///
///         Custody model deliberately UNLIKE `ArcNSMarket` (non-custodial, the NFT stays with the
///         seller until `buy`) and instead LIKE `Vouchers.sol` (escrows the asset at `create` time):
///         `create()` immediately pulls the token into this contract via `transferFrom`. The sender
///         must `approve(address(NameGifts), tokenId)` (or grant `setApprovalForAll`) beforehand —
///         the same non-custodial-until-the-actual-move permission model `list()` already uses, just
///         triggered a transaction earlier.
///
///         Before `expiresAt` only `claim` works (recipient only); at/after `expiresAt` only `refund`
///         works (sender only) — the exact exclusive claim/refund window split `Vouchers.sol` uses.
interface INameGifts {
    struct Gift {
        address collection;
        uint256 tokenId;
        address sender;
        address recipient;
        uint64 expiresAt;
        bool claimed;
        bool refunded;
    }

    event CollectionAllowed(address indexed collection, bool allowed);
    event GiftCreated(
        uint256 indexed giftId,
        address indexed collection,
        uint256 indexed tokenId,
        address sender,
        address recipient,
        uint64 expiresAt
    );
    event GiftClaimed(uint256 indexed giftId, address indexed recipient);
    event GiftRefunded(uint256 indexed giftId, address indexed sender);

    error ZeroAddress();
    error CollectionNotAllowed(address collection);
    error NotOwner(address collection, uint256 tokenId, address caller);
    error NotApproved(address collection, uint256 tokenId, address caller);
    error TokenLocked(address collection, uint256 tokenId);
    error ExpiryInPast(uint64 expiresAt, uint64 now_);
    /// @notice TLD names only (registration-expiry guard, see `NameGifts._requireExpiryClearOfRegistration`).
    error ExpiryTooCloseToRegistrationExpiry(uint64 giftExpiresAt, uint256 nameExpiresAt);
    error GiftUnknown(uint256 giftId);
    error NotRecipient(uint256 giftId, address caller);
    error NotSender(uint256 giftId, address caller);
    error GiftExpired(uint256 giftId, uint64 expiresAt);
    error GiftNotExpired(uint256 giftId, uint64 expiresAt);
    error AlreadyClaimed(uint256 giftId);
    error AlreadyRefunded(uint256 giftId);
    error ValueNotAccepted();

    function isCollectionAllowed(address collection) external view returns (bool);
    function giftOf(uint256 giftId) external view returns (Gift memory);
    function activeGiftId(address collection, uint256 tokenId) external view returns (uint256);
    function nextGiftId() external view returns (uint256);

    /// @notice DEFAULT_ADMIN_ROLE (the timelock).
    function setCollectionAllowed(address collection, bool allowed) external;

    /// @notice Pulls `tokenId` from `msg.sender` into escrow (`msg.sender` must already own it and
    ///         have approved this contract). Reverts if the collection is not allow-listed, the
    ///         token is locked (native or parity `INameLocks`), `expiresAt` is not strictly in the
    ///         future, or (TLD names only) `expiresAt` sits too close to the name's own registration
    ///         expiry.
    function create(address collection, uint256 tokenId, address recipient, uint64 expiresAt)
        external
        returns (uint256 giftId);
    /// @notice Recipient only, strictly before `expiresAt`. Transfers the escrowed token to the caller.
    function claim(uint256 giftId) external;
    /// @notice Sender only, at/after `expiresAt` and only if unclaimed. Returns the escrowed token.
    function refund(uint256 giftId) external;
}
