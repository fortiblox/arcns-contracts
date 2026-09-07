// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ITextRecords — WP-127, create/update/close text records with a live-record counter (M3b)
/// @notice Generalized across every allow-listed collection via `EpochGuard`. Ports x1-handles
///         `create_text_record`/`update_text_record`/`close_text_record`. A record snapshotted at
///         creation goes stale (reads as empty, `exists() == false`) the instant `EpochGuard` sees the
///         name change hands — the same structural staleness rule `ArcNSResolver`'s version-keyed
///         storage already gives the `handle`/`.arc`/`.circle` namespaces address records (onchain-design §3.3),
///         applied here to the parity text-record surface this lane owns.
///
/// @dev `onchain-design.md` §3.1 explicitly deviates from x1's `record_count` release-gate ("the
///      X1 record_count gate is unnecessary [on EVM] because version++ on re-register makes old
///      records unreachable") — `HandleRegistry.release` (out of this lane) does **not** consult this
///      counter, which conflicts with the WP-127 acceptance line "release refuses while records
///      exist". Per the brief, `onchain-design.md` is design authority over `work-packages.md` on a
///      conflict; this module's `recordCountOf` is therefore informational (SDK/UI use), not an
///      enforced release-blocker. Flagged for the CEO in the M3 PR description.
interface ITextRecords {
    struct TextRecord {
        string value;
        address ownerAtCreate;
        uint64 epochAtCreate;
        uint40 updatedAt;
    }

    event TextRecordCreated(address indexed collection, uint256 indexed tokenId, string key, string value);
    event TextRecordUpdated(address indexed collection, uint256 indexed tokenId, string key, string value);
    event TextRecordClosed(address indexed collection, uint256 indexed tokenId, string key);

    error NotCurrentAuthority(address collection, uint256 tokenId, address caller);
    error RecordExists(address collection, uint256 tokenId, bytes32 keyHash);
    error RecordNotFound(address collection, uint256 tokenId, bytes32 keyHash);
    error EmptyKey();

    /// @notice Live (not stale, not closed) record count for `(collection, tokenId)` — informational.
    function recordCountOf(address collection, uint256 tokenId) external view returns (uint32);
    /// @notice `""` if the record was never created, was closed, or has gone stale (epoch/owner change).
    function textOf(address collection, uint256 tokenId, string calldata key) external view returns (string memory);
    function exists(address collection, uint256 tokenId, string calldata key) external view returns (bool);

    function createTextRecord(address collection, uint256 tokenId, string calldata key, string calldata value) external;
    function updateTextRecord(address collection, uint256 tokenId, string calldata key, string calldata value) external;
    function closeTextRecord(address collection, uint256 tokenId, string calldata key) external;
}
