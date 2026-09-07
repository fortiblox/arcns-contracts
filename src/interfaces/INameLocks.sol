// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title INameLocks — WP-125, generalized name-lock parity module (M3b)
/// @notice `HandleRegistry` (C1) already has a native hard lock (`lock`/`initiateUnlock`/
///         `completeUnlock`/`cancelUnlock`, SR-14) baked into its own `_update` choke point — this
///         module does **not** duplicate that for the handle namespace. It exists for collections with no native
///         lock of their own, today every TLD registrar (C4, verbatim ENS `BaseRegistrarImplementation`
///         in `contracts/src/tld`, out of this lane's file scope): the current `ownerOf` a
///         `(collection, tokenId)` may still lock/unlock it here, and `ArcNSMarket` refuses to
///         list/offer-accept/auction a locked token from *either* source (native `isLocked` first,
///         this registry second — see `EpochGuard.nativeLocked`).
///
/// @dev Known, documented limitation: a raw `IERC721(collection).transferFrom` on a TLD registrar
///      cannot be blocked from here — that would require a hook inside `contracts/src/tld/*`, which
///      this lane does not own. "Locked name refuses transfer" is therefore fully closed for
///      the handle namespace (native, SR-14) and closed for **market-mediated** transfers of any allow-listed
///      collection (this module + `ArcNSMarket`), but a TLD name's owner can still call the
///      registrar's own `transferFrom` directly while "locked" here. Flagged in the M3 PR description
///      as a follow-up for whichever lane owns `contracts/src/tld`.
interface INameLocks {
    event Locked(address indexed collection, uint256 indexed tokenId);
    event UnlockInitiated(address indexed collection, uint256 indexed tokenId, uint40 at);
    event UnlockCancelled(address indexed collection, uint256 indexed tokenId);
    event Unlocked(address indexed collection, uint256 indexed tokenId);
    event UnlockTimelockSet(uint64 seconds_);

    error NotOwner(address collection, uint256 tokenId, address caller);
    error AlreadyLocked(address collection, uint256 tokenId);
    error NotLocked(address collection, uint256 tokenId);
    error UnlockPending(address collection, uint256 tokenId);
    error NoUnlockPending(address collection, uint256 tokenId);
    error TimelockNotElapsed(uint64 readyAt, uint64 now_);

    /// @notice Hard floor (SR-14 parity): the effective timelock is never below this, however
    ///         `setUnlockTimelock` is configured.
    function MIN_UNLOCK_TIMELOCK() external view returns (uint64); // 7 days

    function unlockTimelock() external view returns (uint64); // max(config, MIN_UNLOCK_TIMELOCK)
    function setUnlockTimelock(uint64 seconds_) external; // DEFAULT_ADMIN_ROLE (timelock)

    function isLocked(address collection, uint256 tokenId) external view returns (bool);
    function unlockInitiatedAt(address collection, uint256 tokenId) external view returns (uint40);

    function lock(address collection, uint256 tokenId) external; // current ownerOf only; idempotent
    function initiateUnlock(address collection, uint256 tokenId) external;
    function completeUnlock(address collection, uint256 tokenId) external;
    function cancelUnlock(address collection, uint256 tokenId) external; // works while locked
}
