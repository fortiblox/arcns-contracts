// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IRecordDelegate} from "../interfaces/IRecordDelegate.sol";
import {EpochGuard} from "./EpochGuard.sol";

/// @title RecordDelegate — WP-126, single-active record delegate per name, epoch-gated (M3b)
/// @notice See `IRecordDelegate` for full scope: ports x1-handles `set_record_delegate` /
///         `revoke_record_delegate` (a single delegate PDA per handle) generalized across every
///         allow-listed collection via `EpochGuard`. At most one active delegate per
///         `(collection, tokenId)`; it auto-invalidates the instant the name changes hands, with no
///         explicit revoke required.
///
/// @dev Reference source (behavior ported, not code): x1-handles `set_record_delegate` /
///      `revoke_record_delegate`, gated there by the STRICT `require_current_authority` (a delegate
///      can never re-delegate or revoke itself — x1 has no ERC-721-style operator concept, since a
///      tokenized handle's authority is proven by owning the NFT's ATA, not by a second approval
///      relation).
///
///      Judgment call — authority model: this port treats "current authority" as the ERC-721 owner
///      **or** an approved operator (`isApprovedForAll` / `getApproved`), mirroring ERC-721 operator
///      semantics rather than x1's strict owner-only model. This is consistent with this codebase's
///      own precedent: `HandleRegistry.isOwnerOrOperator` already generalizes "owner or operator" as
///      the shape a record-adjacent authority check should take on EVM. The simpler, equally
///      defensible alternative (owner-only, exact x1 parity) was considered and rejected only because
///      it would diverge from that existing precedent; either is fine, this is a legitimate judgment
///      call flagged for review. `TextRecords` makes the identical choice for consistency.
contract RecordDelegate is IRecordDelegate {
    mapping(address collection => mapping(uint256 tokenId => Delegation)) internal _delegations;

    // ---------------------------------------------------------------------------------------------
    // Internal guards
    // ---------------------------------------------------------------------------------------------

    /// @dev "Current authority" = current `ownerOf`, or an ERC-721 operator approved for that owner
    ///      (`isApprovedForAll`) or for this specific token (`getApproved`). See contract NatSpec for
    ///      the owner-vs-operator judgment call.
    function _requireCurrentAuthority(address collection, uint256 tokenId) internal view {
        IERC721 c = IERC721(collection);
        address owner = c.ownerOf(tokenId);
        if (owner == msg.sender) return;
        if (c.isApprovedForAll(owner, msg.sender)) return;
        if (c.getApproved(tokenId) == msg.sender) return;
        revert NotCurrentAuthority(collection, tokenId, msg.sender);
    }

    /// @dev Reconstructs an `EpochGuard.Snapshot` from the stored delegation fields and checks it
    ///      against the collection's live state.
    function _stillValid(Delegation storage d, address collection, uint256 tokenId) internal view returns (bool) {
        EpochGuard.Snapshot memory snap = EpochGuard.Snapshot({owner: d.ownerAtDelegation, epoch: d.epochAtDelegation});
        return EpochGuard.stillValid(snap, collection, tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IRecordDelegate
    function delegateOf(address collection, uint256 tokenId) public view returns (address) {
        Delegation storage d = _delegations[collection][tokenId];
        if (d.delegate == address(0)) return address(0);
        if (!_stillValid(d, collection, tokenId)) return address(0);
        return d.delegate;
    }

    /// @inheritdoc IRecordDelegate
    function isActiveDelegate(address collection, uint256 tokenId, address who) external view returns (bool) {
        return who != address(0) && delegateOf(collection, tokenId) == who;
    }

    /// @inheritdoc IRecordDelegate
    function delegationOf(address collection, uint256 tokenId) external view returns (Delegation memory) {
        return _delegations[collection][tokenId];
    }

    // ---------------------------------------------------------------------------------------------
    // Mutations
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IRecordDelegate
    function setDelegate(address collection, uint256 tokenId, address delegate) external {
        _requireCurrentAuthority(collection, tokenId);
        if (delegate == address(0)) revert ZeroAddress();
        if (delegate == msg.sender) revert SelfDelegation(collection, tokenId);

        Delegation storage d = _delegations[collection][tokenId];
        if (d.delegate != address(0) && _stillValid(d, collection, tokenId)) {
            revert DelegationActive(collection, tokenId, d.delegate);
        }

        EpochGuard.Snapshot memory snap = EpochGuard.snapshot(collection, tokenId);
        d.delegate = delegate;
        d.ownerAtDelegation = snap.owner;
        d.epochAtDelegation = snap.epoch;
        d.delegatedAt = uint40(block.timestamp);
        emit DelegateSet(collection, tokenId, delegate);
    }

    /// @inheritdoc IRecordDelegate
    function revokeDelegate(address collection, uint256 tokenId) external {
        _requireCurrentAuthority(collection, tokenId);
        Delegation storage d = _delegations[collection][tokenId];
        if (d.delegate == address(0) || !_stillValid(d, collection, tokenId)) {
            revert NoActiveDelegation(collection, tokenId);
        }
        address delegate = d.delegate;
        delete _delegations[collection][tokenId];
        emit DelegateRevoked(collection, tokenId, delegate);
    }
}
