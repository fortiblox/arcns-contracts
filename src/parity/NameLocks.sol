// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {INameLocks} from "../interfaces/INameLocks.sol";

/// @title NameLocks — WP-125, generalized name-lock parity module (M3b)
/// @notice See `INameLocks` for full scope: `HandleRegistry` (C1) already owns SR-14's native lock
///         for the handle namespace; this module is the same four-function timelock state machine
///         (`lock`/`initiateUnlock`/`completeUnlock`/`cancelUnlock`), generalized to any
///         `(collection, tokenId)` pair and gated by `IERC721(collection).ownerOf(tokenId)` instead of
///         a registry's own internal owner bookkeeping.
///
/// @dev Direct SR-14 port of `HandleRegistry.lock`/`initiateUnlock`/`completeUnlock`/`cancelUnlock`
///      (`contracts/src/handle/HandleRegistry.sol`), read-only reference for this lane. Same
///      `MIN_UNLOCK_TIMELOCK = 7 days` hard floor, same idempotent-lock and works-while-locked
///      `cancelUnlock` rules.
///
///      Judgment call — idempotent `lock`, not strict: `HandleRegistry.lock` is the explicit
///      behavioral template the brief points at, and it does NOT revert on a re-lock — it silently
///      re-locks and clears any pending unlock (the owner's defence against a stale unlock request
///      surviving a "lock again" call). This contract matches that exactly. `AlreadyLocked` stays
///      declared on `INameLocks` for interface completeness / a future stricter posture, but is
///      intentionally unused here — using it would diverge from the one behavioral template the brief
///      names, for no correctness gain (idempotent re-lock is strictly safer for the owner, never
///      surprising, and never leaves the token unexpectedly unlocked).
contract NameLocks is INameLocks, AccessControl {
    using SafeCast for uint256;

    /// @inheritdoc INameLocks
    uint64 public constant MIN_UNLOCK_TIMELOCK = 7 days;

    struct LockState {
        bool locked;
        uint40 unlockInitiatedAt;
    }

    mapping(address collection => mapping(uint256 tokenId => LockState)) internal _locks;

    /// @dev Configured timelock; `unlockTimelock()` applies the 7-day floor on read (SR-14 parity).
    uint64 internal _unlockTimelockCfg;

    /// @param admin `DEFAULT_ADMIN_ROLE` holder (the timelock in production; only gates
    ///        `setUnlockTimelock`).
    /// @param unlockTimelockSecs Initial configured timelock seconds (floored at 7 days on read).
    constructor(address admin, uint64 unlockTimelockSecs) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _unlockTimelockCfg = unlockTimelockSecs;
        emit UnlockTimelockSet(unlockTimelockSecs);
    }

    // ---------------------------------------------------------------------------------------------
    // Internal guards
    // ---------------------------------------------------------------------------------------------

    /// @dev Reverts `NotOwner` unless `msg.sender` is the collection's current `ownerOf(tokenId)`
    ///      (reverts with the collection's own error for an unknown token, same as `ownerOf` would).
    function _requireOwner(address collection, uint256 tokenId) internal view returns (address owner) {
        owner = IERC721(collection).ownerOf(tokenId);
        if (owner != msg.sender) revert NotOwner(collection, tokenId, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner actions — lock / unlock (SR-14 parity)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc INameLocks
    /// @dev Idempotent (see contract NatSpec): re-locking clears a pending unlock, matching
    ///      `HandleRegistry.lock`.
    function lock(address collection, uint256 tokenId) external {
        _requireOwner(collection, tokenId);
        LockState storage s = _locks[collection][tokenId];
        s.locked = true;
        s.unlockInitiatedAt = 0;
        emit Locked(collection, tokenId);
    }

    /// @inheritdoc INameLocks
    function initiateUnlock(address collection, uint256 tokenId) external {
        _requireOwner(collection, tokenId);
        LockState storage s = _locks[collection][tokenId];
        if (!s.locked) revert NotLocked(collection, tokenId);
        if (s.unlockInitiatedAt != 0) revert UnlockPending(collection, tokenId);
        uint40 at = block.timestamp.toUint40();
        s.unlockInitiatedAt = at;
        emit UnlockInitiated(collection, tokenId, at);
    }

    /// @inheritdoc INameLocks
    /// @dev Timelock = `max(config, MIN_UNLOCK_TIMELOCK)`, same as `HandleRegistry.completeUnlock`.
    function completeUnlock(address collection, uint256 tokenId) external {
        _requireOwner(collection, tokenId);
        LockState storage s = _locks[collection][tokenId];
        if (!s.locked) revert NotLocked(collection, tokenId);
        uint64 initiated = s.unlockInitiatedAt;
        if (initiated == 0) revert NoUnlockPending(collection, tokenId);
        uint64 readyAt = initiated + unlockTimelock();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt, uint64(block.timestamp));
        s.locked = false;
        s.unlockInitiatedAt = 0;
        emit Unlocked(collection, tokenId);
    }

    /// @inheritdoc INameLocks
    /// @dev Works while locked (the point of it): the owner's defence against a thief's
    ///      `initiateUnlock`. Leaves the token locked, matching `HandleRegistry.cancelUnlock`.
    function cancelUnlock(address collection, uint256 tokenId) external {
        _requireOwner(collection, tokenId);
        LockState storage s = _locks[collection][tokenId];
        if (s.unlockInitiatedAt == 0) revert NoUnlockPending(collection, tokenId);
        s.unlockInitiatedAt = 0;
        emit UnlockCancelled(collection, tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc INameLocks
    function setUnlockTimelock(uint64 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unlockTimelockCfg = seconds_;
        emit UnlockTimelockSet(seconds_);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc INameLocks
    function unlockTimelock() public view returns (uint64) {
        uint64 cfg = _unlockTimelockCfg;
        return cfg > MIN_UNLOCK_TIMELOCK ? cfg : MIN_UNLOCK_TIMELOCK;
    }

    /// @inheritdoc INameLocks
    function isLocked(address collection, uint256 tokenId) external view returns (bool) {
        return _locks[collection][tokenId].locked;
    }

    /// @inheritdoc INameLocks
    function unlockInitiatedAt(address collection, uint256 tokenId) external view returns (uint40) {
        return _locks[collection][tokenId].unlockInitiatedAt;
    }
}
