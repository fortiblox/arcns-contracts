// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IHandleController} from "../interfaces/IHandleController.sol";
import {IHandleRegistry} from "../interfaces/IHandleRegistry.sol";
import {IArcNSPriceOracle} from "../interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../lib/ArcNSConstants.sol";
import {HandleNormalize} from "../lib/HandleNormalize.sol";
import {LaunchAllowlist} from "../lib/LaunchAllowlist.sol";

/// @title HandleController — C2, commit-reveal registration for the handle namespace (onchain-design §2, §7)
/// @notice Sole REGISTRAR_ROLE on `HandleRegistry`. Commit-reveal per SR-10 (ENS ETHRegistrarController
///         v1.7.0 age semantics), `maxPrice` guard (pricing.md §4), pull ledger for overpayment
///         (SR-11/SR-31), treasury push (§6), reserved genesis that never touches `totalSold`
///         (CEO decision 6a), `sealGenesis` that revokes GENESIS_ROLE in the same tx (SR-16), and the
///         optional launch allowlist (WP-144, `docs/architecture/launch-allowlist.md`): while
///         `allowlistActive()` only `registerWithProof` with a Merkle proof for `owner` mints; the
///         window is set by the timelock and closes by itself at `allowlistSunset`.
///
/// @dev Roles: DEFAULT_ADMIN_ROLE = timelock (also `setAllowlist`); GENESIS_ROLE = deployer EOA until
///      sealed; PAUSER_ROLE = Admin Safe (pause blocks only `register`; unpause is admin-only, SR-62).
///      Immutable by design (SR-60): a v2 controller is a new deployment re-pointed via the
///      registry's REGISTRAR_ROLE.
contract HandleController is IHandleController, AccessControl, Pausable, ReentrancyGuardTransient {
    // ---------------------------------------------------------------------------------------------
    // Types / constants / immutables
    // ---------------------------------------------------------------------------------------------

    /// @dev Constructor bundle (keeps the deploy script readable and avoids stack pressure).
    struct Init {
        address admin;
        address genesisAdmin;
        address pauser;
        address registry;
        address oracle;
        address treasury;
        uint256 minCommitmentAge;
        uint256 maxCommitmentAge;
    }

    /// @dev Constructor-only guard; not part of `IHandleController` (deploy-time misconfiguration).
    error ZeroAddress();

    bytes32 public constant GENESIS_ROLE = ArcNSConstants.GENESIS_ROLE;
    bytes32 public constant PAUSER_ROLE = ArcNSConstants.PAUSER_ROLE;

    /// @inheritdoc IHandleController
    uint256 public constant MIN_COMMITMENT_AGE_FLOOR = 30 seconds;
    /// @notice `maxCommitmentAge` may not exceed this (SR-10: 24 h).
    uint256 public constant MAX_COMMITMENT_AGE_CEILING = 24 hours;
    /// @inheritdoc IHandleController
    uint256 public constant MAX_ALLOWLIST_WINDOW = 90 days;

    IHandleRegistry public immutable registry;
    IArcNSPriceOracle public immutable oracle;
    /// @inheritdoc IHandleController
    address public immutable treasury;
    /// @inheritdoc IHandleController
    uint256 public immutable minCommitmentAge;
    /// @inheritdoc IHandleController
    uint256 public immutable maxCommitmentAge;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleController
    bool public genesisSealed;
    /// @inheritdoc IHandleController
    bytes32 public genesisRoot;
    /// @inheritdoc IHandleController
    uint256 public reservedCount;
    /// @inheritdoc IHandleController
    mapping(bytes32 commitment => uint256 timestamp) public commitments;
    /// @inheritdoc IHandleController
    mapping(address who => uint256 amount) public withdrawable;
    /// @inheritdoc IHandleController
    bytes32 public allowlistRoot;
    /// @inheritdoc IHandleController
    uint64 public allowlistSunset;

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    constructor(Init memory init) {
        if (
            init.admin == address(0) || init.genesisAdmin == address(0) || init.pauser == address(0)
                || init.registry == address(0) || init.oracle == address(0) || init.treasury == address(0)
        ) revert ZeroAddress();
        if (init.minCommitmentAge < MIN_COMMITMENT_AGE_FLOOR) {
            revert MinCommitmentAgeBelowFloor(init.minCommitmentAge, MIN_COMMITMENT_AGE_FLOOR);
        }
        if (init.maxCommitmentAge <= init.minCommitmentAge || init.maxCommitmentAge > MAX_COMMITMENT_AGE_CEILING) {
            revert MaxCommitmentAgeInvalid(init.maxCommitmentAge);
        }
        registry = IHandleRegistry(init.registry);
        oracle = IArcNSPriceOracle(init.oracle);
        treasury = init.treasury;
        minCommitmentAge = init.minCommitmentAge;
        maxCommitmentAge = init.maxCommitmentAge;
        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(GENESIS_ROLE, init.genesisAdmin);
        _grantRole(PAUSER_ROLE, init.pauser);
    }

    /// @dev Dust / mis-sent value is refused (T-GAS-1). Only `register` is payable.
    receive() external payable {
        revert ValueNotAccepted();
    }

    fallback() external payable {
        revert ValueNotAccepted();
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleController
    function namespaceId() external pure returns (bytes32) {
        return ArcNSConstants.HANDLE_ROOT;
    }

    /// @inheritdoc IHandleController
    function valid(string calldata name) public pure returns (bool) {
        return HandleNormalize.isCanonical(name);
    }

    /// @inheritdoc IHandleController
    function available(string calldata name) public view returns (bool) {
        return valid(name) && !registry.exists(ArcNSConstants.handleTokenId(name));
    }

    /// @inheritdoc IHandleController
    function quote(string calldata name) public view returns (uint256 priceWei) {
        return oracle.quote(ArcNSConstants.HANDLE_ROOT, name);
    }

    /// @inheritdoc IHandleController
    /// @dev SR-10: chain id and this address are inside the hash so a commitment cannot be replayed
    ///      on another chain or against a replacement controller; `owner` is inside so a copied reveal
    ///      still mints to the committer's owner (T-REG-1).
    function makeCommitment(string calldata name, address owner, bytes32 secret, uint8 handleType)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(ArcNSConstants.TAG_HANDLE, name, owner, secret, block.chainid, address(this), handleType)
        );
    }

    /// @inheritdoc IHandleController
    /// @dev `<` against `allowlistSunset`: the sunset second itself is open (mirrors `claim`/`refund`
    ///      window discipline elsewhere — the two states never overlap). 1-second timestamp
    ///      granularity is fine for a days-long window (threat-model §0).
    function allowlistActive() public view returns (bool) {
        return allowlistRoot != bytes32(0) && block.timestamp < allowlistSunset;
    }

    /// @inheritdoc IHandleController
    function isAllowlisted(address owner, bytes32[] calldata proof) public view returns (bool) {
        return LaunchAllowlist.isAllowed(allowlistRoot, proof, owner);
    }

    // ---------------------------------------------------------------------------------------------
    // Commit / reveal
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleController
    function commit(bytes32 commitment) external {
        if (commitments[commitment] + maxCommitmentAge >= block.timestamp) {
            revert UnexpiredCommitmentExists(commitment);
        }
        commitments[commitment] = block.timestamp;
        emit CommitmentMade(commitment, block.timestamp);
    }

    /// @inheritdoc IHandleController
    /// @dev Pausable (new registrations only, SR-62). `nonReentrant` is belt-and-braces: the only
    ///      external value call is the treasury push. The allowlist gate (WP-144) is evaluated before
    ///      the genesis gate so a launch-window client sees `AllowlistRequired` first.
    function register(string calldata name, address owner, bytes32 secret, uint8 handleType, uint256 maxPrice)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (allowlistActive()) revert AllowlistRequired();
        _register(name, owner, secret, handleType, maxPrice);
    }

    /// @inheritdoc IHandleController
    /// @dev The proof is verified for `owner` (never `msg.sender`, see `LaunchAllowlist`) and only
    ///      while the window is open; outside it this is byte-for-byte `register`.
    function registerWithProof(
        string calldata name,
        address owner,
        bytes32 secret,
        uint8 handleType,
        uint256 maxPrice,
        bytes32[] calldata proof
    ) external payable nonReentrant whenNotPaused {
        if (allowlistActive() && !isAllowlisted(owner, proof)) revert NotAllowlisted(owner);
        _register(name, owner, secret, handleType, maxPrice);
    }

    /// @dev Age checks are verbatim ENS ETHRegistrarController v1.7.0 (`>` / `<=` against
    ///      `block.timestamp`). Shared by `register` and `registerWithProof`; the caller has already
    ///      cleared the allowlist gate.
    function _register(string calldata name, address owner, bytes32 secret, uint8 handleType, uint256 maxPrice)
        internal
    {
        if (!genesisSealed) revert RegistrationsClosed();
        if (!HandleNormalize.isCanonical(name)) revert NotCanonical(name);
        uint256 tokenId = ArcNSConstants.handleTokenId(name);
        if (registry.exists(tokenId)) revert NameNotAvailable(name);

        _consumeCommitment(makeCommitment(name, owner, secret, handleType));

        uint256 price = oracle.quote(ArcNSConstants.HANDLE_ROOT, name);
        if (price > maxPrice) revert PriceChanged(price, maxPrice);
        if (msg.value < price) revert InsufficientValue(price, msg.value);

        uint256 minted = registry.register(name, owner, handleType, false);
        assert(minted == tokenId); // registry derives the id the same way (SR-20 single source)
        oracle.recordSale(ArcNSConstants.HANDLE_ROOT);

        uint256 excess = msg.value - price;
        if (excess > 0) {
            withdrawable[msg.sender] += excess;
            emit Credited(msg.sender, excess);
        }
        _payTreasury(tokenId, price);
        emit NameRegistered(name, tokenId, owner, price, handleType);
    }

    function _consumeCommitment(bytes32 commitment) internal {
        uint256 commitmentTimestamp = commitments[commitment];
        if (commitmentTimestamp + minCommitmentAge > block.timestamp) {
            revert CommitmentTooNew(commitment, commitmentTimestamp + minCommitmentAge, block.timestamp);
        }
        if (commitmentTimestamp + maxCommitmentAge <= block.timestamp) {
            // 0 is the "never committed" sentinel (verbatim ENS ETHRegistrarController v1.7.0), not a computed value.
            // slither-disable-next-line incorrect-equality
            if (commitmentTimestamp == 0) revert CommitmentNotFound(commitment);
            revert CommitmentTooOld(commitment, commitmentTimestamp + maxCommitmentAge, block.timestamp);
        }
        delete commitments[commitment];
    }

    /// @dev Push to the Treasury Safe; a failing push reverts the registration (onchain-design §6).
    function _payTreasury(uint256 tokenId, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = treasury.call{value: amount}("");
        if (!ok) revert TreasuryPaymentFailed(treasury, amount);
        emit TreasuryFee(tokenId, amount);
    }

    /// @inheritdoc IHandleController
    /// @dev Pull ledger (SR-31). Not pausable: withdrawals must always work (SR-62).
    function withdraw() external nonReentrant {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert WithdrawFailed(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Genesis (GENESIS_ROLE, pre-seal only)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleController
    /// @dev Idempotent: names that already exist are skipped so a partial batch can be re-run.
    ///      Never calls `oracle.recordSale` — treasury inventory is not a sale (pricing.md §4).
    ///      `reservedCount` counts names actually minted by this contract.
    function registerReservedBatch(string[] calldata names, uint8[] calldata handleTypes)
        external
        onlyRole(GENESIS_ROLE)
    {
        if (genesisSealed) revert GenesisAlreadySealed();
        if (names.length != handleTypes.length) revert BatchLengthMismatch();
        uint256 minted = 0;
        for (uint256 i = 0; i < names.length; i++) {
            uint256 tokenId = ArcNSConstants.handleTokenId(names[i]);
            if (registry.exists(tokenId)) continue;
            tokenId = registry.register(names[i], treasury, handleTypes[i], true);
            minted++;
            emit ReservedRegistered(tokenId, names[i]);
        }
        reservedCount += minted;
    }

    /// @inheritdoc IHandleController
    /// @dev Opens public registration and revokes GENESIS_ROLE from the caller in the same tx (SR-16).
    function sealGenesis(bytes32 merkleRoot) external onlyRole(GENESIS_ROLE) {
        if (genesisSealed) revert GenesisAlreadySealed();
        genesisSealed = true;
        genesisRoot = merkleRoot;
        emit GenesisSealed(ArcNSConstants.HANDLE_ROOT, merkleRoot, reservedCount);
        _revokeRole(GENESIS_ROLE, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Launch allowlist (WP-144; DEFAULT_ADMIN_ROLE = timelock)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleController
    /// @dev A non-zero root needs `now < sunset <= now + MAX_ALLOWLIST_WINDOW`; clearing needs
    ///      `sunset == 0` so a "clear" can never be confused with a window. Re-setting overwrites both
    ///      fields atomically — there is no separate "extend"; the timelock delay (SR-61) applies to
    ///      every change, so the window can only be extended/rotated with public notice.
    function setAllowlist(bytes32 root, uint64 sunset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (root == bytes32(0)) {
            if (sunset != 0) revert AllowlistSunsetInvalid(sunset);
        } else if (sunset <= block.timestamp || sunset > block.timestamp + MAX_ALLOWLIST_WINDOW) {
            revert AllowlistSunsetInvalid(sunset);
        }
        allowlistRoot = root;
        allowlistSunset = sunset;
        emit AllowlistSet(root, sunset);
    }

    // ---------------------------------------------------------------------------------------------
    // Pause (SR-62: registrations only; unpause is timelocked admin)
    // ---------------------------------------------------------------------------------------------

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
