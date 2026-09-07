// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {INameLocks} from "../../../src/interfaces/INameLocks.sol";

/// @notice Minimal `INameLocks` (WP-125) test double — exercises `ArcNSMarket`'s parity-lock path
///         (`_isLocked`'s second clause) for collections with no native lock of their own (e.g.
///         `MockERC721`, standing in for a TLD registrar) without depending on the real parity module,
///         which does not exist yet. Faithful to the interface's ownerOf-gated lock/unlock flow, plus
///         a `forceSetLocked` test-only escape hatch for setting up a locked fixture in one call.
contract MockNameLocks is INameLocks {
    uint64 public constant MIN_UNLOCK_TIMELOCK = 7 days;

    address public admin;
    uint64 private _unlockTimelock;

    mapping(address collection => mapping(uint256 tokenId => bool)) private _locked;
    mapping(address collection => mapping(uint256 tokenId => uint40)) private _unlockInitiatedAt;

    constructor(address admin_) {
        admin = admin_;
        _unlockTimelock = MIN_UNLOCK_TIMELOCK;
    }

    modifier onlyTokenOwner(address collection, uint256 tokenId) {
        if (IERC721(collection).ownerOf(tokenId) != msg.sender) revert NotOwner(collection, tokenId, msg.sender);
        _;
    }

    function unlockTimelock() external view returns (uint64) {
        return _unlockTimelock < MIN_UNLOCK_TIMELOCK ? MIN_UNLOCK_TIMELOCK : _unlockTimelock;
    }

    function setUnlockTimelock(uint64 seconds_) external {
        require(msg.sender == admin, "not admin");
        _unlockTimelock = seconds_;
        emit UnlockTimelockSet(seconds_);
    }

    function isLocked(address collection, uint256 tokenId) external view returns (bool) {
        return _locked[collection][tokenId];
    }

    function unlockInitiatedAt(address collection, uint256 tokenId) external view returns (uint40) {
        return _unlockInitiatedAt[collection][tokenId];
    }

    function lock(address collection, uint256 tokenId) external onlyTokenOwner(collection, tokenId) {
        if (_locked[collection][tokenId]) return; // idempotent
        _locked[collection][tokenId] = true;
        emit Locked(collection, tokenId);
    }

    function initiateUnlock(address collection, uint256 tokenId) external onlyTokenOwner(collection, tokenId) {
        if (!_locked[collection][tokenId]) revert NotLocked(collection, tokenId);
        if (_unlockInitiatedAt[collection][tokenId] != 0) revert UnlockPending(collection, tokenId);
        _unlockInitiatedAt[collection][tokenId] = uint40(block.timestamp);
        emit UnlockInitiated(collection, tokenId, uint40(block.timestamp));
    }

    function cancelUnlock(address collection, uint256 tokenId) external onlyTokenOwner(collection, tokenId) {
        if (_unlockInitiatedAt[collection][tokenId] == 0) revert NoUnlockPending(collection, tokenId);
        delete _unlockInitiatedAt[collection][tokenId];
        emit UnlockCancelled(collection, tokenId);
    }

    function completeUnlock(address collection, uint256 tokenId) external onlyTokenOwner(collection, tokenId) {
        uint40 at = _unlockInitiatedAt[collection][tokenId];
        if (at == 0) revert NoUnlockPending(collection, tokenId);
        uint64 readyAt = at + this.unlockTimelock();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt, uint64(block.timestamp));
        _locked[collection][tokenId] = false;
        delete _unlockInitiatedAt[collection][tokenId];
        emit Unlocked(collection, tokenId);
    }

    /// @dev Test-only escape hatch: set the lock flag directly without the ownerOf-gated flow, so
    ///      tests can stand up a "locked" fixture in one call.
    function forceSetLocked(address collection, uint256 tokenId, bool locked_) external {
        _locked[collection][tokenId] = locked_;
        if (locked_) emit Locked(collection, tokenId);
        else emit Unlocked(collection, tokenId);
    }
}
