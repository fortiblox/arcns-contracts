// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title IHandleRegistry — C1, the source of truth for handle-namespace ownership (onchain-design §3.1)
/// @notice ERC-721 from birth; soulbound-by-default (`transferable == false` ⇒ ERC-721 transfers revert
///         except through `transfer` (owner), `completeRecovery`, REGISTRAR_ROLE mint and MARKET_ROLE).
///         `ownerOf` is the only authority. The `_update` hook is the single choke point for every
///         ownership change and bumps `epoch` by exactly 1 (SR-12), stamps `registeredAt = now + 1`
///         (X1 INT-M1 parity), and clears recovery state.
interface IHandleRegistry is IERC721 {
    enum HandleType {
        Human,
        Merchant,
        Org,
        Agent
    }

    struct Handle {
        bytes32 name; // ASCII a-z0-9-, zero-padded; len = index of first 0x00
        uint64 registeredAt; // epoch anchor timestamp, bumped `now + 1` on every ownership change
        uint64 epoch; // record-version counter, +1 on every ownership change (SR-12)
        uint8 handleType; // HandleType, descriptive only
        bool transferable; // set by `tokenize`, one-way
        bool locked; // hard freeze (SR-14)
        uint64 unlockInitiatedAt;
        uint64 recoveryInitiatedAt;
    }

    // ---- events (onchain-design §9)
    event HandleRegistered(
        uint256 indexed tokenId, string name, address indexed owner, uint8 handleType, bool reserved
    );
    event EpochBumped(uint256 indexed tokenId, uint64 epoch, uint64 registeredAt, uint8 reason);
    event Tokenized(uint256 indexed tokenId, uint256 fee);
    event Released(uint256 indexed tokenId);
    event RecoverySet(uint256 indexed tokenId, address recovery);
    event RecoveryInitiated(uint256 indexed tokenId, address target, uint64 at);
    event RecoveryCancelled(uint256 indexed tokenId);
    event RecoveryCompleted(uint256 indexed tokenId, address previousOwner, address newOwner);
    event Locked(uint256 indexed tokenId);
    event UnlockInitiated(uint256 indexed tokenId, uint64 at);
    event UnlockCancelled(uint256 indexed tokenId);
    event Unlocked(uint256 indexed tokenId);
    event SubnameCreated(uint256 indexed tokenId, bytes32 indexed labelhash, string label);
    event SubnameRevoked(uint256 indexed tokenId, bytes32 indexed labelhash);
    event RecoveryTimelockSet(uint64 seconds_);
    event TreasuryFee(uint256 indexed tokenId, uint256 amount);

    // ---- epoch bump reasons (for `EpochBumped.reason`)
    // 0 = mint, 1 = transfer, 2 = recovery, 3 = market, 4 = burn

    // ---- errors (X1 `RegistryError` names kept where they exist)
    error NotCanonical(string name);
    error AlreadyRegistered(uint256 tokenId);
    error HandleLocked(uint256 tokenId);
    error HandleNotLocked(uint256 tokenId);
    error TransfersLocked(uint256 tokenId);
    error AlreadyTransferable(uint256 tokenId);
    error RecoveryPending(uint256 tokenId);
    error NoRecoveryPending(uint256 tokenId);
    error NoRecoverySet(uint256 tokenId);
    error NotRecoveryKey(uint256 tokenId, address caller);
    error RecoveryDisabledWhenTokenized(uint256 tokenId);
    error TimelockNotElapsed(uint64 readyAt, uint64 now_);
    error NoUnlockPending(uint256 tokenId);
    error UnlockPending(uint256 tokenId);
    error NotOwner(uint256 tokenId, address caller);
    error SubnameExists(uint256 tokenId, bytes32 labelhash);
    error SubnameUnknown(uint256 tokenId, bytes32 labelhash);
    error IncorrectPayment(uint256 required, uint256 sent);
    error TreasuryPaymentFailed(address treasury, uint256 amount);
    error ZeroAddress();
    error ValueNotAccepted();

    // ---- constants / derivations
    function HANDLE_ROOT() external view returns (bytes32);
    function MIN_UNLOCK_TIMELOCK() external view returns (uint64); // 7 days (SR-14)
    function MIN_RECOVERY_TIMELOCK() external view returns (uint64); // 7 days (SR-15)
    function treasury() external view returns (address);
    function recoveryTimelock() external view returns (uint64); // effective = max(config, MIN_RECOVERY_TIMELOCK)
    function tokenIdOf(string calldata name) external pure returns (uint256);
    function nodeOf(string calldata name) external pure returns (bytes32);

    // ---- views used by the resolver / SDK
    function exists(uint256 tokenId) external view returns (bool);
    function nodeToToken(bytes32 node) external view returns (uint256);
    function subnodeToToken(bytes32 subnode) external view returns (uint256);
    function subnameCreatedAt(uint256 tokenId, bytes32 labelhash) external view returns (uint64);
    function handleOf(uint256 tokenId) external view returns (Handle memory);
    function nameOf(uint256 tokenId) external view returns (string memory);
    function epochOf(uint256 tokenId) external view returns (uint64);
    function isLocked(uint256 tokenId) external view returns (bool);
    function isTransferable(uint256 tokenId) external view returns (bool);
    function recoveryOf(uint256 tokenId) external view returns (address);
    function recoveryTargetOf(uint256 tokenId) external view returns (address);
    function recoveryPending(uint256 tokenId) external view returns (bool);
    /// @notice ERC-721 owner or approved operator/approved-for-token (resolver authority input).
    function isOwnerOrOperator(uint256 tokenId, address who) external view returns (bool);
    function contractURI() external view returns (string memory);

    // ---- REGISTRAR_ROLE (HandleController)
    function register(string calldata name, address owner, uint8 handleType, bool reserved) external returns (uint256);

    // ---- owner actions (X1 port-map rows 10–18, 33, 34, 44, 45)
    function transfer(uint256 tokenId, address to) external;
    function tokenize(uint256 tokenId, uint256 maxPrice) external payable;
    function release(uint256 tokenId) external;
    function lock(uint256 tokenId) external;
    function initiateUnlock(uint256 tokenId) external;
    function completeUnlock(uint256 tokenId) external;
    function cancelUnlock(uint256 tokenId) external;
    function setRecovery(uint256 tokenId, address recovery) external;
    function initiateRecovery(uint256 tokenId, address target) external;
    function cancelRecovery(uint256 tokenId) external;
    function completeRecovery(uint256 tokenId) external;
    function createSubname(uint256 tokenId, string calldata label) external;
    function revokeSubname(uint256 tokenId, string calldata label) external;

    // ---- governance (timelock)
    function setRecoveryTimelock(uint64 seconds_) external;
}
