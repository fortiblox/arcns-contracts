// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IRecordDelegate — WP-126, single-active record delegate per name, epoch-gated (M3b)
/// @notice Ports x1-handles `set_record_delegate`/`revoke_record_delegate` (single delegate PDA per
///         handle) generalized across every allow-listed collection via `EpochGuard`. Unlike ENS's
///         `approve(node, delegate, bool)` boolean-per-delegate model (already on `ArcNSResolver`,
///         `contracts/src/resolver`, out of this lane), this is x1's stricter shape: **at most one**
///         active delegate per `(collection, tokenId)`, and it auto-invalidates the instant the name
///         changes hands (`EpochGuard.stillValid` — SR-12/T-REG-4 class) with no explicit revoke
///         required.
///
/// @dev Not yet consulted by `ArcNSResolver.isAuthorised` (that wiring needs `contracts/src/resolver`,
///      out of this lane's file scope) — tracked as a cross-lane follow-up in the M3 PR description.
///      This module is a complete, independently correct and tested state machine ready for that wire.
interface IRecordDelegate {
    struct Delegation {
        address delegate;
        address ownerAtDelegation;
        uint64 epochAtDelegation;
        uint40 delegatedAt;
    }

    event DelegateSet(address indexed collection, uint256 indexed tokenId, address indexed delegate);
    event DelegateRevoked(address indexed collection, uint256 indexed tokenId, address delegate);

    error NotCurrentAuthority(address collection, uint256 tokenId, address caller);
    error DelegationActive(address collection, uint256 tokenId, address delegate);
    error NoActiveDelegation(address collection, uint256 tokenId);
    error ZeroAddress();
    error SelfDelegation(address collection, uint256 tokenId);

    /// @notice `address(0)` if there is no delegate, or the stored one has gone stale because the
    ///         name changed hands since (auto-invalidation, no explicit revoke needed).
    function delegateOf(address collection, uint256 tokenId) external view returns (address);
    function isActiveDelegate(address collection, uint256 tokenId, address who) external view returns (bool);
    function delegationOf(address collection, uint256 tokenId) external view returns (Delegation memory);

    /// @notice Current owner (or its ERC-721 operator) only; reverts `DelegationActive` if the
    ///         existing delegation is still valid (must be revoked, or must have gone stale, first).
    function setDelegate(address collection, uint256 tokenId, address delegate) external;
    /// @notice Current owner (or operator) only — the delegate itself cannot revoke or renounce
    ///         (x1 parity: one authority model, no second code path).
    function revokeDelegate(address collection, uint256 tokenId) external;
}
