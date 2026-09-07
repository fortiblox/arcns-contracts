// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @dev Optional extension a collection may implement (HandleRegistry does; the verbatim ENS
///      `TldRegistrar` does not) to expose a monotonic per-token epoch (SR-12).
interface IEpochOf {
    function epochOf(uint256 tokenId) external view returns (uint64);
}

/// @dev Optional extension a collection may implement (HandleRegistry does) for a native lock flag.
interface INativeLockOf {
    function isLocked(uint256 tokenId) external view returns (bool);
}

/// @title EpochGuard — generalized "has this (collection, tokenId) changed hands" check
/// @notice WP-119 requires the marketplace (and the M3b parity modules that key state off an NFT the
///         same way — locks, delegate, text records, attestations) to work against **any**
///         allow-listed ERC-721: `HandleRegistry` (C1, exposes `epochOf`/`isLocked` — SR-12) and every
///         `TldRegistrar` (C4, verbatim ens-contracts `BaseRegistrarImplementation`,
///         which has neither). `snapshot`/`stillValid` give every consumer one staleness check that
///         degrades gracefully: full epoch-precision when the collection has `epochOf` (closes the
///         Wyvern/OpenSea "list, sell, buy back, stale listing still executes" class — T-MKT-1 — for
///         the handle namespace), owner-address precision otherwise.
///
/// @dev Known, documented limitation (flagged in the M3 PR description, not a bandaid): for a
///      collection without `epochOf` (today, every TLD registrar) a transfer away and back to the
///      *same* address is invisible to this guard, because there is no epoch counter to observe and
///      this library cannot add one without editing `contracts/src/tld/*` (owned by a different lane).
///      Closing that gap fully requires an epoch counter inside the TLD registrar itself.
library EpochGuard {
    struct Snapshot {
        address owner;
        uint64 epoch; // 0 sentinel when the collection has no `epochOf`
    }

    function snapshot(address collection, uint256 tokenId) internal view returns (Snapshot memory s) {
        s.owner = IERC721(collection).ownerOf(tokenId);
        s.epoch = _epochOf(collection, tokenId);
    }

    function stillValid(Snapshot memory s, address collection, uint256 tokenId) internal view returns (bool) {
        if (IERC721(collection).ownerOf(tokenId) != s.owner) return false;
        return _epochOf(collection, tokenId) == s.epoch;
    }

    function currentOwner(address collection, uint256 tokenId) internal view returns (address) {
        return IERC721(collection).ownerOf(tokenId);
    }

    /// @notice True if `collection` reports `tokenId` locked, via its own native `isLocked` when it
    ///         has one (HandleRegistry, SR-14). Collections without one (TLD registrars) always
    ///         report false here — callers combine this with a parity `INameLocks` lookup (WP-125).
    function nativeLocked(address collection, uint256 tokenId) internal view returns (bool) {
        (bool ok, bytes memory data) =
            collection.staticcall(abi.encodeWithSelector(INativeLockOf.isLocked.selector, tokenId));
        if (!ok || data.length < 32) return false;
        return abi.decode(data, (bool));
    }

    /// @dev `staticcall` so a collection without `epochOf` (selector miss/revert) degrades to the
    ///      0 sentinel instead of reverting the caller's snapshot/validate.
    function _epochOf(address collection, uint256 tokenId) private view returns (uint64) {
        (bool ok, bytes memory data) = collection.staticcall(abi.encodeWithSelector(IEpochOf.epochOf.selector, tokenId));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint64));
    }
}
