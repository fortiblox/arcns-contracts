// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IHandleRegistry} from "../interfaces/IHandleRegistry.sol";
import {IArcNSPriceOracle} from "../interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../lib/ArcNSConstants.sol";
import {HandleNormalize} from "../lib/HandleNormalize.sol";
import {NameMetadata} from "../lib/NameMetadata.sol";

/// @title HandleRegistry — C1, source of truth for handle-namespace ownership (onchain-design §3.1, §4)
/// @notice ERC-721 from birth, soulbound by default. `ownerOf` is the only authority. Every ownership
///         change (mint, `transfer`, ERC-721 transfer, market move, recovery completion, burn) goes
///         through the OZ 5 `_update` hook, which refuses while locked, enforces the soulbound rule,
///         bumps `epoch` by exactly one (SR-12), stamps `registeredAt = now + 1` (X1 INT-M1 parity)
///         and clears recovery state (T-NFT-3).
///
///         Non-upgradeable, no proxies, no delegatecall, no selfdestruct (SR-60). Nothing here is
///         pausable (SR-62). Native value is only accepted by `tokenize` (SR-36, T-GAS-1).
///
/// @dev Storage: `_handles[tokenId]` packs the whole X1 `Handle` into two slots — the 32-byte name
///      and one 208-bit meta word (`epoch` u64, three u40 timestamps, `handleType` u8, two flags).
///      `uint40` timestamps are valid until year 36812; `SafeCast.toUint40` fail-closes beyond it.
///      `recovery` / `recoveryTarget` are separate mappings so they cost nothing until set.
///      `epoch` survives `release` (burn) so a re-registered name starts at a higher epoch (SR-13).
contract HandleRegistry is IHandleRegistry, IERC4906, ERC721, AccessControl {
    using SafeCast for uint256;

    // ---------------------------------------------------------------------------------------------
    // Constants / immutables
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleRegistry
    bytes32 public constant HANDLE_ROOT = ArcNSConstants.HANDLE_ROOT;
    /// @inheritdoc IHandleRegistry
    uint64 public constant MIN_UNLOCK_TIMELOCK = 7 days;
    /// @inheritdoc IHandleRegistry
    uint64 public constant MIN_RECOVERY_TIMELOCK = 7 days;

    bytes32 public constant REGISTRAR_ROLE = ArcNSConstants.REGISTRAR_ROLE;
    bytes32 public constant MARKET_ROLE = ArcNSConstants.MARKET_ROLE;

    /// @dev `EpochBumped.reason` values.
    uint8 internal constant REASON_MINT = 0;
    uint8 internal constant REASON_TRANSFER = 1;
    uint8 internal constant REASON_RECOVERY = 2;
    uint8 internal constant REASON_MARKET = 3;
    uint8 internal constant REASON_BURN = 4;

    /// @dev `_moveKind` values (transient; set only for the duration of an internal move).
    uint256 internal constant MOVE_NONE = 0;
    uint256 internal constant MOVE_TRANSFER = 1;
    uint256 internal constant MOVE_RECOVERY = 2;

    /// @dev Metadata accent colour (hex, no hash sign).
    string internal constant ACCENT = "3b82f6";

    /// @inheritdoc IHandleRegistry
    address public immutable treasury;
    /// @notice The shared price oracle; `quoteTokenize` / `recordTokenize` under `HANDLE_ROOT`.
    IArcNSPriceOracle public immutable oracle;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @dev Two-slot packed twin of `IHandleRegistry.Handle` (see contract NatSpec).
    struct Stored {
        bytes32 name;
        uint64 epoch;
        uint40 registeredAt;
        uint40 unlockInitiatedAt;
        uint40 recoveryInitiatedAt;
        uint8 handleType;
        bool transferable;
        bool locked;
    }

    mapping(uint256 tokenId => Stored) internal _handles;
    mapping(uint256 tokenId => address) internal _recovery;
    mapping(uint256 tokenId => address) internal _recoveryTarget;
    /// @inheritdoc IHandleRegistry
    mapping(bytes32 node => uint256 tokenId) public nodeToToken;
    /// @inheritdoc IHandleRegistry
    mapping(bytes32 subnode => uint256 tokenId) public subnodeToToken;
    mapping(uint256 tokenId => mapping(bytes32 labelhash => uint64 createdAt)) internal _subnames;

    /// @dev Configured recovery/unlock timelock; the effective value is floored at 7 days (SR-14/15).
    uint64 internal _recoveryTimelockCfg;

    /// @dev Set by `transfer` / `completeRecovery` around their `_update` call so the hook can tell an
    ///      owner-initiated move from an ERC-721 `transferFrom`. Transient: it can never outlive the
    ///      transaction, and the callers clear it explicitly anyway.
    uint256 private transient _moveKind;

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    /// @param admin DEFAULT_ADMIN_ROLE holder (the timelock in production).
    /// @param treasury_ Treasury Safe: receives tokenize fees by push (onchain-design §6).
    /// @param oracle_ Shared price oracle.
    /// @param recoveryTimelockSecs Initial recovery/unlock timelock config (floored at 7 days on read).
    constructor(address admin, address treasury_, IArcNSPriceOracle oracle_, uint64 recoveryTimelockSecs)
        ERC721("arcns handles", "ARCNS")
    {
        if (admin == address(0) || treasury_ == address(0) || address(oracle_) == address(0)) revert ZeroAddress();
        treasury = treasury_;
        oracle = oracle_;
        _recoveryTimelockCfg = recoveryTimelockSecs;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        emit RecoveryTimelockSet(recoveryTimelockSecs);
    }

    /// @dev Dust / mis-sent value is refused (T-GAS-1). Only `tokenize` is payable.
    receive() external payable {
        revert ValueNotAccepted();
    }

    fallback() external payable {
        revert ValueNotAccepted();
    }

    // ---------------------------------------------------------------------------------------------
    // Modifiers / internal guards
    // ---------------------------------------------------------------------------------------------

    /// @dev Reverts `NotOwner` unless `msg.sender` is the current ERC-721 owner (reverts
    ///      `ERC721NonexistentToken` for unknown ids).
    function _requireOwner(uint256 tokenId) internal view returns (address owner) {
        owner = _requireOwned(tokenId);
        if (owner != msg.sender) revert NotOwner(tokenId, msg.sender);
    }

    function _requireUnlocked(Stored storage h, uint256 tokenId) internal view {
        if (h.locked) revert HandleLocked(tokenId);
    }

    function _requireNoRecoveryPending(Stored storage h, uint256 tokenId) internal view {
        if (h.recoveryInitiatedAt != 0) revert RecoveryPending(tokenId);
    }

    function _now40() internal view returns (uint40) {
        return block.timestamp.toUint40();
    }

    // ---------------------------------------------------------------------------------------------
    // REGISTRAR_ROLE
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleRegistry
    /// @dev `_mint`, not `_safeMint`: the treasury is a Safe and the receiver callback is pointless
    ///      gas for 19,571 genesis names (onchain-design §7). Reverts with a Solidity panic (0x21)
    ///      when `handleType` is outside `HandleType`.
    function register(string calldata name, address owner, uint8 handleType, bool reserved)
        external
        onlyRole(REGISTRAR_ROLE)
        returns (uint256 tokenId)
    {
        (bytes32 seed, bool ok) = HandleNormalize.seedBytes(name);
        if (!ok) revert NotCanonical(name);
        if (owner == address(0)) revert ZeroAddress();
        HandleType(handleType); // range check
        tokenId = uint256(keccak256(bytes(name)));
        if (_ownerOf(tokenId) != address(0)) revert AlreadyRegistered(tokenId);

        Stored storage h = _handles[tokenId];
        h.name = seed;
        h.handleType = handleType;
        // transferable / locked / timestamps are already zero: cleared on release, never set before.
        nodeToToken[keccak256(abi.encodePacked(HANDLE_ROOT, keccak256(bytes(name))))] = tokenId;

        _mint(owner, tokenId);
        emit HandleRegistered(tokenId, name, owner, handleType, reserved);
    }

    // ---------------------------------------------------------------------------------------------
    // Ownership choke point
    // ---------------------------------------------------------------------------------------------

    /// @dev The single place ownership changes (onchain-design §3.1):
    ///      (a) locked ⇒ revert, every path including burn;
    ///      (b) pending recovery ⇒ revert unless this is `completeRecovery`;
    ///      (c) soulbound: a transfer of a non-tokenized handle is allowed only via `transfer`,
    ///          `completeRecovery` or a MARKET_ROLE caller;
    ///      (d) `epoch += 1`, `registeredAt = now + 1`, recovery / unlock state cleared, `EpochBumped`.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        Stored storage h = _handles[tokenId];
        if (h.locked) revert HandleLocked(tokenId);

        address prev = _ownerOf(tokenId);
        uint8 reason = REASON_MINT;
        if (prev == address(0)) {
            reason = REASON_MINT;
        } else {
            uint256 kind = _moveKind;
            if (kind != MOVE_RECOVERY && h.recoveryInitiatedAt != 0) revert RecoveryPending(tokenId);
            if (to == address(0)) {
                reason = REASON_BURN;
            } else if (kind == MOVE_TRANSFER) {
                reason = REASON_TRANSFER;
            } else if (kind == MOVE_RECOVERY) {
                reason = REASON_RECOVERY;
            } else if (hasRole(MARKET_ROLE, msg.sender)) {
                reason = REASON_MARKET;
            } else if (h.transferable) {
                reason = REASON_TRANSFER;
            } else {
                revert TransfersLocked(tokenId);
            }
        }

        from = super._update(to, tokenId, auth);

        uint64 epoch = h.epoch + 1;
        uint40 registeredAt = (block.timestamp + 1).toUint40();
        h.epoch = epoch;
        h.registeredAt = registeredAt;
        if (prev != address(0)) {
            // Recovery config never survives an ownership change (T-NFT-3); a pending unlock is moot.
            h.recoveryInitiatedAt = 0;
            h.unlockInitiatedAt = 0;
            if (_recovery[tokenId] != address(0)) delete _recovery[tokenId];
            if (_recoveryTarget[tokenId] != address(0)) delete _recoveryTarget[tokenId];
        }
        emit EpochBumped(tokenId, epoch, registeredAt, reason);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner actions — transfer / tokenize / release
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleRegistry
    /// @dev X1 `transfer`: owner-initiated move of a (possibly soulbound) handle. Bypasses the
    ///      soulbound rule only; lock and pending-recovery guards still apply inside `_update`.
    function transfer(uint256 tokenId, address to) external {
        _requireOwner(tokenId);
        if (to == address(0)) revert ZeroAddress();
        _moveKind = MOVE_TRANSFER;
        _update(to, tokenId, address(0));
        _moveKind = MOVE_NONE;
    }

    /// @inheritdoc IHandleRegistry
    /// @dev X1 `mint_handle_nft`. One-way: flips `transferable`, after which ERC-721 transfers work.
    ///      Exact payment: `msg.value == quoteTokenize`; `maxPrice` guards against a curve step between
    ///      quote and send. Fee is pushed to the Treasury Safe and a failing push reverts (§6).
    function tokenize(uint256 tokenId, uint256 maxPrice) external payable {
        _requireOwner(tokenId);
        Stored storage h = _handles[tokenId];
        if (h.transferable) revert AlreadyTransferable(tokenId);
        _requireUnlocked(h, tokenId);
        _requireNoRecoveryPending(h, tokenId);

        uint256 price = oracle.quoteTokenize(HANDLE_ROOT, _nameFromSeed(h.name));
        if (price > maxPrice) revert IncorrectPayment(price, maxPrice);
        if (msg.value != price) revert IncorrectPayment(price, msg.value);

        h.transferable = true;
        // F-C3: a recovery config from before tokenization is a competing
        // authority model once the handle is a bearer NFT (T-NFT-3) — without
        // this, a recovery address set while non-transferable stays live
        // after tokenize() (only a *pending* recovery was checked above), and
        // can later initiateRecovery() to block every sale / eventually seize
        // the token. `_update` already clears recovery on every transfer;
        // tokenize is itself an authority change and gets the same treatment.
        if (_recovery[tokenId] != address(0)) {
            delete _recovery[tokenId];
            emit RecoverySet(tokenId, address(0));
        }
        oracle.recordTokenize(HANDLE_ROOT);
        if (price > 0) {
            (bool ok,) = treasury.call{value: price}("");
            if (!ok) revert TreasuryPaymentFailed(treasury, price);
            emit TreasuryFee(tokenId, price);
        }
        emit Tokenized(tokenId, price);
        emit MetadataUpdate(tokenId);
    }

    /// @inheritdoc IHandleRegistry
    /// @dev X1 `release_handle` → `_burn`. Allowed for tokenized handles too (no SPL-mint reuse
    ///      hazard on EVM). `epoch` is kept so a re-registration starts at `epoch + 1` (SR-13);
    ///      everything else about the handle is cleared. Sub-handle existence is keyed by tokenId
    ///      and is not enumerable, so it is left in place — its records were already invalidated
    ///      by the epoch bump.
    function release(uint256 tokenId) external {
        _requireOwner(tokenId);
        Stored storage h = _handles[tokenId];
        _requireUnlocked(h, tokenId);
        _requireNoRecoveryPending(h, tokenId);

        bytes32 seed = h.name;
        _burn(tokenId);
        delete nodeToToken[keccak256(abi.encodePacked(HANDLE_ROOT, keccak256(bytes(_nameFromSeed(seed)))))];
        h.name = bytes32(0);
        h.handleType = 0;
        h.transferable = false;
        emit Released(tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner actions — lock / unlock (SR-14)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleRegistry
    /// @dev X1 `lock_handle`: idempotent; re-locking clears a pending unlock.
    function lock(uint256 tokenId) external {
        _requireOwner(tokenId);
        Stored storage h = _handles[tokenId];
        h.locked = true;
        h.unlockInitiatedAt = 0;
        emit Locked(tokenId);
        emit MetadataUpdate(tokenId);
    }

    /// @inheritdoc IHandleRegistry
    function initiateUnlock(uint256 tokenId) external {
        _requireOwner(tokenId);
        Stored storage h = _handles[tokenId];
        if (!h.locked) revert HandleNotLocked(tokenId);
        if (h.unlockInitiatedAt != 0) revert UnlockPending(tokenId);
        uint40 at = _now40();
        h.unlockInitiatedAt = at;
        emit UnlockInitiated(tokenId, at);
    }

    /// @inheritdoc IHandleRegistry
    /// @dev Timelock = `max(config, MIN_UNLOCK_TIMELOCK)`; X1 `0 < initiated <= now` sanity kept.
    function completeUnlock(uint256 tokenId) external {
        _requireOwner(tokenId);
        Stored storage h = _handles[tokenId];
        if (!h.locked) revert HandleNotLocked(tokenId);
        uint64 initiated = h.unlockInitiatedAt;
        if (initiated == 0) revert NoUnlockPending(tokenId);
        uint64 readyAt = initiated + recoveryTimelock();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt, uint64(block.timestamp));
        h.locked = false;
        h.unlockInitiatedAt = 0;
        emit Unlocked(tokenId);
        emit MetadataUpdate(tokenId);
    }

    /// @inheritdoc IHandleRegistry
    /// @dev Works while locked (that is the point): the owner's defence against a thief's
    ///      `initiateUnlock`. Leaves the handle locked.
    function cancelUnlock(uint256 tokenId) external {
        _requireOwner(tokenId);
        Stored storage h = _handles[tokenId];
        if (h.unlockInitiatedAt == 0) revert NoUnlockPending(tokenId);
        h.unlockInitiatedAt = 0;
        emit UnlockCancelled(tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner / recovery-key actions — recovery (SR-15)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleRegistry
    /// @dev Refused once tokenized (Q7 / X1 parity: bearer token and recovery override are competing
    ///      authority models) and while locked. Setting a new key (or zero) also drops any pending
    ///      recovery, as on X1.
    function setRecovery(uint256 tokenId, address recovery) external {
        _requireOwner(tokenId);
        Stored storage h = _handles[tokenId];
        if (h.transferable) revert RecoveryDisabledWhenTokenized(tokenId);
        _requireUnlocked(h, tokenId);
        _recovery[tokenId] = recovery;
        if (h.recoveryInitiatedAt != 0) {
            h.recoveryInitiatedAt = 0;
            delete _recoveryTarget[tokenId];
        }
        emit RecoverySet(tokenId, recovery);
    }

    /// @inheritdoc IHandleRegistry
    function initiateRecovery(uint256 tokenId, address target) external {
        _requireOwned(tokenId);
        Stored storage h = _handles[tokenId];
        _requireUnlocked(h, tokenId);
        _requireRecoveryKey(tokenId);
        _requireNoRecoveryPending(h, tokenId);
        if (target == address(0)) revert ZeroAddress();
        uint40 at = _now40();
        h.recoveryInitiatedAt = at;
        _recoveryTarget[tokenId] = target;
        emit RecoveryInitiated(tokenId, target, at);
    }

    /// @inheritdoc IHandleRegistry
    /// @dev Works while locked (X1 rule) — the owner's defence against a compromised recovery key.
    function cancelRecovery(uint256 tokenId) external {
        _requireOwner(tokenId);
        Stored storage h = _handles[tokenId];
        if (h.recoveryInitiatedAt == 0) revert NoRecoveryPending(tokenId);
        h.recoveryInitiatedAt = 0;
        delete _recoveryTarget[tokenId];
        emit RecoveryCancelled(tokenId);
    }

    /// @inheritdoc IHandleRegistry
    /// @dev Moves the handle to `recoveryTarget` after `max(config, MIN_RECOVERY_TIMELOCK)`. Goes
    ///      through `_update`, which bypasses the soulbound rule for this path only and, unlike X1
    ///      (which kept the key for the self-recovery case), clears the recovery key together with
    ///      the pending state: on EVM every ownership change wipes recovery config (T-NFT-3), so the
    ///      new owner re-arms it explicitly with `setRecovery`.
    function completeRecovery(uint256 tokenId) external {
        address prev = _requireOwned(tokenId);
        Stored storage h = _handles[tokenId];
        _requireUnlocked(h, tokenId);
        _requireRecoveryKey(tokenId);
        uint64 initiated = h.recoveryInitiatedAt;
        if (initiated == 0) revert NoRecoveryPending(tokenId);
        uint64 readyAt = initiated + recoveryTimelock();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt, uint64(block.timestamp));
        address target = _recoveryTarget[tokenId];

        _moveKind = MOVE_RECOVERY;
        _update(target, tokenId, address(0));
        _moveKind = MOVE_NONE;
        emit RecoveryCompleted(tokenId, prev, target);
    }

    function _requireRecoveryKey(uint256 tokenId) internal view {
        address rec = _recovery[tokenId];
        if (rec == address(0)) revert NoRecoverySet(tokenId);
        if (rec != msg.sender) revert NotRecoveryKey(tokenId, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner actions — sub-handles (port-map rows 44–45)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleRegistry
    /// @dev Existence + `createdAt` only; records live in the resolver under
    ///      `keccak256(handleNode ‖ labelhash)` at the parent's epoch.
    function createSubname(uint256 tokenId, string calldata label) external {
        _requireOwner(tokenId);
        Stored storage h = _handles[tokenId];
        _requireUnlocked(h, tokenId);
        if (!HandleNormalize.isCanonical(label)) revert NotCanonical(label);
        bytes32 labelhash = keccak256(bytes(label));
        if (_subnames[tokenId][labelhash] != 0) revert SubnameExists(tokenId, labelhash);
        _subnames[tokenId][labelhash] = block.timestamp.toUint64();
        subnodeToToken[_subnodeOf(h.name, labelhash)] = tokenId;
        emit SubnameCreated(tokenId, labelhash, label);
    }

    /// @inheritdoc IHandleRegistry
    function revokeSubname(uint256 tokenId, string calldata label) external {
        _requireOwner(tokenId);
        Stored storage h = _handles[tokenId];
        _requireUnlocked(h, tokenId);
        bytes32 labelhash = keccak256(bytes(label));
        if (_subnames[tokenId][labelhash] == 0) revert SubnameUnknown(tokenId, labelhash);
        delete _subnames[tokenId][labelhash];
        delete subnodeToToken[_subnodeOf(h.name, labelhash)];
        emit SubnameRevoked(tokenId, labelhash);
    }

    function _subnodeOf(bytes32 seed, bytes32 labelhash) internal pure returns (bytes32) {
        bytes32 node = keccak256(abi.encodePacked(HANDLE_ROOT, keccak256(bytes(_nameFromSeed(seed)))));
        return keccak256(abi.encodePacked(node, labelhash));
    }

    // ---------------------------------------------------------------------------------------------
    // Governance (timelock)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleRegistry
    /// @dev Stored verbatim; `recoveryTimelock()` applies the 7-day floor (port-map row 6).
    function setRecoveryTimelock(uint64 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _recoveryTimelockCfg = seconds_;
        emit RecoveryTimelockSet(seconds_);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleRegistry
    function recoveryTimelock() public view returns (uint64) {
        uint64 cfg = _recoveryTimelockCfg;
        return cfg > MIN_RECOVERY_TIMELOCK ? cfg : MIN_RECOVERY_TIMELOCK;
    }

    /// @inheritdoc IHandleRegistry
    function tokenIdOf(string calldata name) external pure returns (uint256) {
        return uint256(keccak256(bytes(name)));
    }

    /// @inheritdoc IHandleRegistry
    function nodeOf(string calldata name) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(HANDLE_ROOT, keccak256(bytes(name))));
    }

    /// @inheritdoc IHandleRegistry
    function exists(uint256 tokenId) public view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /// @inheritdoc IHandleRegistry
    function subnameCreatedAt(uint256 tokenId, bytes32 labelhash) external view returns (uint64) {
        return _subnames[tokenId][labelhash];
    }

    /// @inheritdoc IHandleRegistry
    function handleOf(uint256 tokenId) external view returns (Handle memory) {
        Stored storage h = _handles[tokenId];
        return Handle({
            name: h.name,
            registeredAt: h.registeredAt,
            epoch: h.epoch,
            handleType: h.handleType,
            transferable: h.transferable,
            locked: h.locked,
            unlockInitiatedAt: h.unlockInitiatedAt,
            recoveryInitiatedAt: h.recoveryInitiatedAt
        });
    }

    /// @inheritdoc IHandleRegistry
    function nameOf(uint256 tokenId) external view returns (string memory) {
        return _nameFromSeed(_handles[tokenId].name);
    }

    /// @inheritdoc IHandleRegistry
    function epochOf(uint256 tokenId) external view returns (uint64) {
        return _handles[tokenId].epoch;
    }

    /// @inheritdoc IHandleRegistry
    function isLocked(uint256 tokenId) external view returns (bool) {
        return _handles[tokenId].locked;
    }

    /// @inheritdoc IHandleRegistry
    function isTransferable(uint256 tokenId) external view returns (bool) {
        return _handles[tokenId].transferable;
    }

    /// @inheritdoc IHandleRegistry
    function recoveryOf(uint256 tokenId) external view returns (address) {
        return _recovery[tokenId];
    }

    /// @inheritdoc IHandleRegistry
    function recoveryTargetOf(uint256 tokenId) external view returns (address) {
        return _recoveryTarget[tokenId];
    }

    /// @inheritdoc IHandleRegistry
    function recoveryPending(uint256 tokenId) external view returns (bool) {
        return _handles[tokenId].recoveryInitiatedAt != 0;
    }

    /// @inheritdoc IHandleRegistry
    function isOwnerOrOperator(uint256 tokenId, address who) external view returns (bool) {
        address owner = _ownerOf(tokenId);
        if (owner == address(0) || who == address(0)) return false;
        return owner == who || isApprovedForAll(owner, who) || _getApproved(tokenId) == who;
    }

    /// @dev Left-aligned zero-padded seed → string (inverse of `HandleNormalize.seedBytes`).
    function _nameFromSeed(bytes32 seed) internal pure returns (string memory) {
        uint256 len = 0;
        while (len < 32 && seed[len] != 0) {
            len++;
        }
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = seed[i];
        }
        return string(out);
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata (fully on-chain, T-NFT-5)
    // ---------------------------------------------------------------------------------------------

    /// @notice Fully on-chain JSON + SVG; no hosted API dependency.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Stored storage h = _handles[tokenId];
        string memory name = _nameFromSeed(h.name);
        string memory attributes = string.concat(
            "[",
            NameMetadata.traitString("namespace", "handle"),
            ",",
            NameMetadata.traitNumber("length", bytes(name).length),
            ",",
            NameMetadata.traitString("type", _typeName(h.handleType)),
            ",",
            NameMetadata.traitString("transferable", h.transferable ? "yes" : "no"),
            ",",
            NameMetadata.traitString("locked", h.locked ? "yes" : "no"),
            ",",
            NameMetadata.traitNumber("epoch", h.epoch),
            "]"
        );
        return NameMetadata.tokenURI(
            string.concat("@", name),
            unicode"arcns @handle — a permanent, flat payment name on Arc.",
            attributes,
            ACCENT
        );
    }

    /// @inheritdoc IHandleRegistry
    function contractURI() external pure returns (string memory) {
        return NameMetadata.contractURI(
            "arcns handles",
            unicode"arcns @handle — permanent, flat payment names on Arc. Soulbound until tokenized.",
            ACCENT
        );
    }

    function _typeName(uint8 t) internal pure returns (string memory) {
        if (t == uint8(HandleType.Human)) return "Human";
        if (t == uint8(HandleType.Merchant)) return "Merchant";
        if (t == uint8(HandleType.Org)) return "Org";
        return "Agent";
    }

    /// @dev ERC-721, ERC-721 Metadata, AccessControl, ERC-4906 (`0x49064906`).
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl, IERC165) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }
}
