// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {ITextRecords} from "../interfaces/ITextRecords.sol";
import {EpochGuard} from "./EpochGuard.sol";

/// @title TextRecords — WP-127, create/update/close text records with a live-record counter (M3b)
/// @notice See `ITextRecords` for full scope: ports x1-handles `create_text_record` /
///         `update_text_record` / `close_text_record`, generalized across every allow-listed
///         collection via `EpochGuard`. A record snapshotted at creation goes stale (reads as empty,
///         `exists() == false`) the instant `EpochGuard` sees the name change hands.
///
/// @dev Reference source (behavior ported, not code): x1-handles `create_text_record` /
///      `update_text_record` / `close_text_record`.
///
///      Judgment call — authority model: identical choice to `RecordDelegate._requireCurrentAuthority`
///      (owner **or** ERC-721 operator via `isApprovedForAll` / `getApproved`), kept consistent across
///      both modules per the brief. See `RecordDelegate`'s NatSpec for the full reasoning.
///
///      Judgment call — `recordCountOf` is informational only (per `ITextRecords`'s NatSpec,
///      `onchain-design.md` §3.1 overrides the work-packages.md "release refuses while records exist"
///      line; `HandleRegistry.release`, out of this lane, does not and will not consult this counter).
///      It cannot be kept perfectly in sync with true liveness: an external transfer instantly makes
///      every existing key's record stale for `textOf`/`exists` (pure read-time `EpochGuard` check,
///      no storage write), but this contract has no hook into that transfer and so cannot proactively
///      decrement per-key at the moment it happens. The counter is therefore a *lazily corrected*
///      count of records physically present in storage, corrected key-by-key the next time each key
///      is touched:
///        - `createTextRecord` always increments on success, whether it fills a truly empty slot or
///          silently overwrites a now-stale one (the latter is a legitimate fresh create from the new
///          owner's perspective, and is the "cleanest option" this module's design brief calls out).
///        - `closeTextRecord` always decrements on success, guarded by requiring the slot to exist
///          (`updatedAt != 0`).
///      This design is proved underflow-safe by construction, not just by the specific test scenario:
///      the only way a slot's `updatedAt` becomes nonzero is a `createTextRecord` call, which always
///      pairs with exactly one counter increment; `closeTextRecord` requires that nonzero state before
///      it will decrement, and immediately deletes the slot (resetting `updatedAt` to zero), so a
///      given physical write can never be decremented twice. The one known imprecision (documented,
///      not a bug): repeated create-over-stale cycles for the same key without an intervening close
///      increment the counter once per cycle, so `recordCountOf` can overcount relative to true live
///      records until the key is finally closed — an accepted consequence of an informational,
///      no-enumeration counter, never an underflow.
contract TextRecords is ITextRecords {
    mapping(address collection => mapping(uint256 tokenId => mapping(bytes32 keyHash => TextRecord))) internal _records;
    mapping(address collection => mapping(uint256 tokenId => uint32)) internal _recordCount;

    // ---------------------------------------------------------------------------------------------
    // Internal guards
    // ---------------------------------------------------------------------------------------------

    /// @dev Same authority shape as `RecordDelegate._requireCurrentAuthority` — see contract NatSpec.
    function _requireCurrentAuthority(address collection, uint256 tokenId) internal view {
        IERC721 c = IERC721(collection);
        address owner = c.ownerOf(tokenId);
        if (owner == msg.sender) return;
        if (c.isApprovedForAll(owner, msg.sender)) return;
        if (c.getApproved(tokenId) == msg.sender) return;
        revert NotCurrentAuthority(collection, tokenId, msg.sender);
    }

    /// @dev Reconstructs an `EpochGuard.Snapshot` from the stored record fields and checks it against
    ///      the collection's live state.
    function _stillValid(TextRecord storage r, address collection, uint256 tokenId) internal view returns (bool) {
        EpochGuard.Snapshot memory snap = EpochGuard.Snapshot({owner: r.ownerAtCreate, epoch: r.epochAtCreate});
        return EpochGuard.stillValid(snap, collection, tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ITextRecords
    function recordCountOf(address collection, uint256 tokenId) external view returns (uint32) {
        return _recordCount[collection][tokenId];
    }

    /// @inheritdoc ITextRecords
    function textOf(address collection, uint256 tokenId, string calldata key) external view returns (string memory) {
        TextRecord storage r = _records[collection][tokenId][keccak256(bytes(key))];
        if (r.updatedAt == 0 || !_stillValid(r, collection, tokenId)) return "";
        return r.value;
    }

    /// @inheritdoc ITextRecords
    function exists(address collection, uint256 tokenId, string calldata key) external view returns (bool) {
        TextRecord storage r = _records[collection][tokenId][keccak256(bytes(key))];
        return r.updatedAt != 0 && _stillValid(r, collection, tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // Mutations
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ITextRecords
    /// @dev A stale existing record (name changed hands since it was created) is silently overwritten
    ///      by a fresh create — see contract NatSpec for the counter's treatment of that case.
    function createTextRecord(address collection, uint256 tokenId, string calldata key, string calldata value)
        external
    {
        if (bytes(key).length == 0) revert EmptyKey();
        _requireCurrentAuthority(collection, tokenId);

        bytes32 keyHash = keccak256(bytes(key));
        TextRecord storage r = _records[collection][tokenId][keyHash];
        if (r.updatedAt != 0 && _stillValid(r, collection, tokenId)) {
            revert RecordExists(collection, tokenId, keyHash);
        }

        EpochGuard.Snapshot memory snap = EpochGuard.snapshot(collection, tokenId);
        r.value = value;
        r.ownerAtCreate = snap.owner;
        r.epochAtCreate = snap.epoch;
        r.updatedAt = uint40(block.timestamp);
        _recordCount[collection][tokenId] += 1;
        emit TextRecordCreated(collection, tokenId, key, value);
    }

    /// @inheritdoc ITextRecords
    /// @dev A stale record is not updatable — only recreatable via `createTextRecord` (matches the
    ///      "stale reads as empty" contract). Owner/epoch snapshot is left unchanged: it was already
    ///      valid, and this call does not represent a change of hands.
    function updateTextRecord(address collection, uint256 tokenId, string calldata key, string calldata value)
        external
    {
        _requireCurrentAuthority(collection, tokenId);
        bytes32 keyHash = keccak256(bytes(key));
        TextRecord storage r = _records[collection][tokenId][keyHash];
        if (r.updatedAt == 0 || !_stillValid(r, collection, tokenId)) {
            revert RecordNotFound(collection, tokenId, keyHash);
        }
        r.value = value;
        r.updatedAt = uint40(block.timestamp);
        emit TextRecordUpdated(collection, tokenId, key, value);
    }

    /// @inheritdoc ITextRecords
    /// @dev Closing a stale record is fine (it's just cleanup) — the only requirement is that a slot
    ///      currently exists in storage, live or stale. See contract NatSpec for why the matching
    ///      decrement can never underflow.
    function closeTextRecord(address collection, uint256 tokenId, string calldata key) external {
        _requireCurrentAuthority(collection, tokenId);
        bytes32 keyHash = keccak256(bytes(key));
        TextRecord storage r = _records[collection][tokenId][keyHash];
        if (r.updatedAt == 0) revert RecordNotFound(collection, tokenId, keyHash);
        _recordCount[collection][tokenId] -= 1;
        delete _records[collection][tokenId][keyHash];
        emit TextRecordClosed(collection, tokenId, key);
    }
}
