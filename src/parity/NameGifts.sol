// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {INameGifts} from "../interfaces/INameGifts.sol";
import {INameLocks} from "../interfaces/INameLocks.sol";
import {EpochGuard} from "./EpochGuard.sol";

/// @dev Optional extension a TLD registrar exposes (verbatim ens-contracts
///      `BaseRegistrarImplementation.nameExpires`) that `HandleRegistry` does not (handles never
///      expire). Declared here rather than added to the shared `EpochGuard.sol` (owned by a different
///      lane) — same graceful-degradation `staticcall` pattern as `EpochGuard`'s own `IEpochOf` /
///      `INativeLockOf`.
interface INameExpiryOf {
    function nameExpires(uint256 tokenId) external view returns (uint256);
}

/// @title NameGifts — send-a-name-by-email escrow across both namespaces (onchain-design §1, M3b)
/// @notice See `INameGifts` for the full design: keyed by `(collection, tokenId)` exactly like
///         `IArcNSMarket`, so one contract serves `HandleRegistry` (C1) and every `TldRegistrar` (C4)
///         side by side. Unlike `ArcNSMarket` (non-custodial), `create()` escrows the NFT immediately
///         — the `Vouchers.sol` create/claim/refund state machine, ported from escrowing value to
///         escrowing an NFT.
///
/// @dev Roles: `DEFAULT_ADMIN_ROLE` = timelock (`setCollectionAllowed`), same as `ArcNSMarket`. No
///      other admin surface (no pause) — `INameGifts`/this contract mirror `Vouchers.sol`'s
///      deliberately admin-light posture; every action is sender/recipient-gated and a stuck gift is
///      externally recoverable (`refund` after `expiresAt`, permissionless-by-the-sender) IN THE
///      HANDLE NAMESPACE ONLY. For a TLD-namespace gift, `refund` is only guaranteed to succeed if
///      called within `MIN_REGISTRATION_BUFFER` of `expiresAt` — `_requireExpiryClearOfRegistration`
///      only checks the expiry/registration relationship once, at `create` time, and is never
///      re-checked at `claim`/`refund` time. A sender who does not call `refund` until the
///      underlying TLD registration has since lapsed will find `refund` reverting (see the dev note
///      on `_requireExpiryClearOfRegistration` below) until a third party calls the registrar
///      controller's permissionless `renew` — this contract provides no reminder, event, or
///      time-bound guarantee that this recovery step will happen.
///
///      `id = 0` is never assigned (`nextGiftId` starts at 1) and is treated as "no such gift";
///      existence of a stored gift is tested via `sender != address(0)`, identical sentinel
///      discipline to `Vouchers.sol`'s `payer != address(0)`.
///
///      Locking/staleness reuse `EpochGuard`/`INameLocks` verbatim (no third reimplementation, T-MKT-1
///      class): native lock first (`HandleRegistry.isLocked`, SR-14), parity `INameLocks` second, only
///      when configured — identical composition to `ArcNSMarket._isLocked`.
///
///      Handle-namespace requirement (must be granted at deploy time, not optional):
///      `HandleRegistry._update` only allows a non-owner-initiated `transferFrom` past the soulbound
///      gate when `hasRole(MARKET_ROLE, msg.sender)` — this contract's address must hold
///      `HandleRegistry.MARKET_ROLE` (granted via the same two-phase timelock flow as `ArcNSMarket`,
///      see `script/DeployNameGifts.s.sol` / `script/GrantNameGiftsMarketRole.s.sol`) or `create` /
///      `claim` / `refund` silently narrow to tokenized handles only — a regression from the
///      instant-transfer `HandleRegistry.transfer()` gifting flow this contract replaces.
contract NameGifts is INameGifts, AccessControl, ReentrancyGuardTransient {
    /// @notice Minimum slack required between a gift's own `expiresAt` and the underlying TLD name's
    ///         registration `nameExpires` (registration-expiry guard, TLD names only — see
    ///         `_requireExpiryClearOfRegistration`). Chosen so a name cannot lapse (and start
    ///         reverting `ownerOf`, stranding the escrowed name until someone calls the registrar's
    ///         permissionless `renew`) while still sitting in escrow.
    uint64 public constant MIN_REGISTRATION_BUFFER = 14 days;

    /// @notice Parity lock module (WP-125) consulted for collections with no native lock of their own
    ///         (TLD registrars). `address(0)` disables this check, same convention as
    ///         `ArcNSMarket.nameLocks`.
    address public immutable nameLocks;

    /// @dev Constructor bundle (stack-too-deep avoidance, matches `ArcNSMarket.Init`).
    struct Init {
        address admin;
        address nameLocks; // may be `address(0)`: parity module not deployed yet (WP-125)
    }

    /// @inheritdoc INameGifts
    mapping(address collection => bool allowed) public isCollectionAllowed;

    mapping(uint256 giftId => Gift) internal _gifts;

    /// @inheritdoc INameGifts
    mapping(address collection => mapping(uint256 tokenId => uint256 giftId)) public activeGiftId;

    /// @inheritdoc INameGifts
    uint256 public nextGiftId = 1;

    constructor(Init memory init) {
        if (init.admin == address(0)) revert ZeroAddress();
        nameLocks = init.nameLocks;
        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
    }

    /// @dev This contract only ever custodies an NFT, never value — matches both `Vouchers.sol` and
    ///      `ArcNSMarket`. Unlike those two, this contract has no `withdraw()` (there is nothing to
    ///      withdraw: both functions below unconditionally revert, so ether can never actually be
    ///      received here) — see SECURITY-NOTES.md's `locked-ether` entry for why slither still flags
    ///      it and why that is a false positive specific to this contract.
    // slither-disable-next-line locked-ether
    receive() external payable {
        revert ValueNotAccepted();
    }

    // slither-disable-next-line locked-ether
    fallback() external payable {
        revert ValueNotAccepted();
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc INameGifts
    function giftOf(uint256 giftId) external view returns (Gift memory) {
        return _gifts[giftId];
    }

    // ---------------------------------------------------------------------------------------------
    // Admin (DEFAULT_ADMIN_ROLE = timelock)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc INameGifts
    function setCollectionAllowed(address collection, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (collection == address(0)) revert ZeroAddress();
        isCollectionAllowed[collection] = allowed;
        emit CollectionAllowed(collection, allowed);
    }

    // ---------------------------------------------------------------------------------------------
    // Create / claim / refund
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc INameGifts
    /// @dev Checks-effects-interactions: every state write and event happens before the single
    ///      `transferFrom` that pulls the token into escrow.
    function create(address collection, uint256 tokenId, address recipient, uint64 expiresAt)
        external
        nonReentrant
        returns (uint256 giftId)
    {
        if (!isCollectionAllowed[collection]) revert CollectionNotAllowed(collection);
        if (recipient == address(0)) revert ZeroAddress();
        address owner_ = IERC721(collection).ownerOf(tokenId);
        if (owner_ != msg.sender) revert NotOwner(collection, tokenId, msg.sender);
        if (
            IERC721(collection).getApproved(tokenId) != address(this)
                && !IERC721(collection).isApprovedForAll(msg.sender, address(this))
        ) revert NotApproved(collection, tokenId, msg.sender);
        if (expiresAt <= block.timestamp) revert ExpiryInPast(expiresAt, uint64(block.timestamp));
        if (
            EpochGuard.nativeLocked(collection, tokenId)
                || (nameLocks != address(0) && INameLocks(nameLocks).isLocked(collection, tokenId))
        ) {
            revert TokenLocked(collection, tokenId);
        }
        _requireExpiryClearOfRegistration(collection, tokenId, expiresAt);

        giftId = nextGiftId++;
        _gifts[giftId] = Gift({
            collection: collection,
            tokenId: tokenId,
            sender: msg.sender,
            recipient: recipient,
            expiresAt: expiresAt,
            claimed: false,
            refunded: false
        });
        activeGiftId[collection][tokenId] = giftId;
        emit GiftCreated(giftId, collection, tokenId, msg.sender, recipient, expiresAt);

        IERC721(collection).transferFrom(msg.sender, address(this), tokenId);
    }

    /// @inheritdoc INameGifts
    /// @dev Valid strictly before `expiresAt` (`block.timestamp < expiresAt`); at/after expiry only
    ///      `refund` works, so the two windows never overlap (mirrors `Vouchers.claim`).
    function claim(uint256 giftId) external nonReentrant {
        Gift storage g = _gifts[giftId];
        if (g.sender == address(0)) revert GiftUnknown(giftId);
        if (msg.sender != g.recipient) revert NotRecipient(giftId, msg.sender);
        if (g.claimed) revert AlreadyClaimed(giftId);
        if (g.refunded) revert AlreadyRefunded(giftId);
        if (block.timestamp >= g.expiresAt) revert GiftExpired(giftId, g.expiresAt);

        g.claimed = true;
        delete activeGiftId[g.collection][g.tokenId];
        emit GiftClaimed(giftId, g.recipient);
        IERC721(g.collection).transferFrom(address(this), g.recipient, g.tokenId);
    }

    /// @inheritdoc INameGifts
    /// @dev Valid at/after `expiresAt` (`block.timestamp >= expiresAt`) — the boundary itself is
    ///      refund-eligible, not claim-eligible, mirroring `Vouchers.refund`'s exclusive upper bound.
    function refund(uint256 giftId) external nonReentrant {
        Gift storage g = _gifts[giftId];
        if (g.sender == address(0)) revert GiftUnknown(giftId);
        if (msg.sender != g.sender) revert NotSender(giftId, msg.sender);
        if (g.claimed) revert AlreadyClaimed(giftId);
        if (g.refunded) revert AlreadyRefunded(giftId);
        if (block.timestamp < g.expiresAt) revert GiftNotExpired(giftId, g.expiresAt);

        g.refunded = true;
        delete activeGiftId[g.collection][g.tokenId];
        emit GiftRefunded(giftId, g.sender);
        IERC721(g.collection).transferFrom(address(this), g.sender, g.tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    /// @dev TLD names only: ens-contracts' `BaseRegistrarImplementation.ownerOf` reverts as soon as
    ///      `expiries[tokenId] <= block.timestamp`, even during the 90-day `GRACE_PERIOD` where only
    ///      `renew()` still works — if a name's registration lapsed while escrowed here, BOTH `claim`
    ///      and `refund` would revert too (their final `transferFrom` needs `ownerOf` to resolve),
    ///      stranding the name until someone (anyone — `renew` is `onlyController`, not owner-gated)
    ///      renews it. Mitigated here with a graceful-degrading `staticcall` probe, exactly like
    ///      `EpochGuard._epochOf`'s pattern: a collection with no `nameExpires` (HandleRegistry —
    ///      handles never expire) degrades to a no-op instead of reverting.
    function _requireExpiryClearOfRegistration(address collection, uint256 tokenId, uint64 giftExpiresAt)
        internal
        view
    {
        (bool ok, bytes memory data) =
            collection.staticcall(abi.encodeWithSelector(INameExpiryOf.nameExpires.selector, tokenId));
        if (!ok || data.length < 32) return; // collection has no nameExpires (HandleRegistry) — nothing to guard
        uint256 nameExpiresAt = abi.decode(data, (uint256));
        if (uint256(giftExpiresAt) + MIN_REGISTRATION_BUFFER > nameExpiresAt) {
            revert ExpiryTooCloseToRegistrationExpiry(giftExpiresAt, nameExpiresAt);
        }
    }
}
