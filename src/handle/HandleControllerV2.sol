// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IHandleController} from "../interfaces/IHandleController.sol";
import {IHandleControllerV2} from "../interfaces/IHandleControllerV2.sol";
import {IHandleRegistry} from "../interfaces/IHandleRegistry.sol";
import {IArcNSPriceOracle} from "../interfaces/IArcNSPriceOracle.sol";
import {IIntegratorRegistry} from "../interfaces/IIntegratorRegistry.sol";
import {ArcNSConstants} from "../lib/ArcNSConstants.sol";
import {HandleNormalize} from "../lib/HandleNormalize.sol";
import {LaunchAllowlist} from "../lib/LaunchAllowlist.sol";

/// @title HandleControllerV2 — C2 replacement, WP #7772: adds the integrator revenue-share overload
/// @notice Registrar-swap successor to `HandleController` (SR-60: the original is immutable by
///         design, so this is a new deployment re-pointed via `HandleRegistry`'s `REGISTRAR_ROLE`, not
///         a patch). Every V1 behaviour is preserved byte-for-byte:
///         - `register`/`registerWithProof` (the original 5-/6-arg forms, `IHandleController`) run the
///           EXACT SAME `_register` path as V1 with `integrator = address(0)`: same price, same
///           treasury amount, same events, same reverts. WP-129's own acceptance bar ("6-arg register
///           form still works without an integrator") holds by construction, not by a special case.
///         - New: `registerWithIntegrator`/`registerWithProofAndIntegrator` (`IHandleControllerV2`)
///           split the price between the Treasury Safe and an allow-listed integrator's pull-ledger
///           balance, per `IIntegratorRegistry`.
///
/// @dev Integrator safety (CEO requirement, WP #7772: "it needs to be whitelisted from an admin, don't
///      want it abused"): this contract adds NO allow-list, NO rate-setting, and NO self-registration
///      path of its own. Every integrator address is resolved through `integratorRegistry.rateOf`,
///      which is `DEFAULT_ADMIN_ROLE` (the timelock)-gated on that separate contract and reverts
///      `NotIntegrator` for anyone not explicitly allow-listed there. The rate is clamped to
///      `IIntegratorRegistry.CAP_BPS` (40%) inside `IntegratorRegistry` itself — this contract never
///      reads or writes a rate directly, so it cannot exceed or bypass that cap even if this file were
///      buggy. `rateOf` is called BEFORE any state mutation (commitment consumption, registry mint), so
///      an invalid integrator reverts the whole registration with zero side effects (T-REG-1 class).
///
///      Roles / storage layout / genesis / allowlist / pause: verbatim `HandleController` (see that
///      contract's NatSpec for SR-10/11/16/31/60/62 rationale). Immutable by design, same as V1: a v3
///      would again be a new deployment re-pointed via `REGISTRAR_ROLE`.
contract HandleControllerV2 is
    IHandleController,
    IHandleControllerV2,
    AccessControl,
    Pausable,
    ReentrancyGuardTransient
{
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
        address integratorRegistry;
        uint256 minCommitmentAge;
        uint256 maxCommitmentAge;
    }

    /// @dev Constructor-only guard; not part of either interface (deploy-time misconfiguration).
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
    /// @inheritdoc IHandleControllerV2
    IIntegratorRegistry public immutable integratorRegistry;
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
                || init.integratorRegistry == address(0)
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
        integratorRegistry = IIntegratorRegistry(init.integratorRegistry);
        minCommitmentAge = init.minCommitmentAge;
        maxCommitmentAge = init.maxCommitmentAge;
        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(GENESIS_ROLE, init.genesisAdmin);
        _grantRole(PAUSER_ROLE, init.pauser);
    }

    /// @dev Dust / mis-sent value is refused (T-GAS-1). Only the register overloads are payable.
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
    /// @dev SR-10: chain id and this address are inside the hash so a commitment cannot be replayed on
    ///      another chain or against a different controller (V1 or a future V3) — a reveal made against
    ///      V1's commitment never matches here, and vice versa. `owner` is inside so a copied reveal
    ///      still mints to the committer's owner (T-REG-1). The integrator is deliberately NOT part of
    ///      the commitment: it only decides how the payment is split, never who owns the name or what
    ///      is being registered, so adding/omitting it at reveal time cannot change the outcome for the
    ///      registrant — only who is credited the referral share.
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
    /// @dev Byte-for-byte V1 behaviour: `integrator = address(0)` through the shared `_register`.
    function register(string calldata name, address owner, bytes32 secret, uint8 handleType, uint256 maxPrice)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (allowlistActive()) revert AllowlistRequired();
        _register(name, owner, secret, handleType, maxPrice, address(0));
    }

    /// @inheritdoc IHandleController
    function registerWithProof(
        string calldata name,
        address owner,
        bytes32 secret,
        uint8 handleType,
        uint256 maxPrice,
        bytes32[] calldata proof
    ) external payable nonReentrant whenNotPaused {
        if (allowlistActive() && !isAllowlisted(owner, proof)) revert NotAllowlisted(owner);
        _register(name, owner, secret, handleType, maxPrice, address(0));
    }

    /// @inheritdoc IHandleControllerV2
    function registerWithIntegrator(
        string calldata name,
        address owner,
        bytes32 secret,
        uint8 handleType,
        uint256 maxPrice,
        address integrator
    ) external payable nonReentrant whenNotPaused {
        if (integrator == address(0)) revert IntegratorRequired();
        if (allowlistActive()) revert AllowlistRequired();
        _register(name, owner, secret, handleType, maxPrice, integrator);
    }

    /// @inheritdoc IHandleControllerV2
    function registerWithProofAndIntegrator(
        string calldata name,
        address owner,
        bytes32 secret,
        uint8 handleType,
        uint256 maxPrice,
        bytes32[] calldata proof,
        address integrator
    ) external payable nonReentrant whenNotPaused {
        if (integrator == address(0)) revert IntegratorRequired();
        if (allowlistActive() && !isAllowlisted(owner, proof)) revert NotAllowlisted(owner);
        _register(name, owner, secret, handleType, maxPrice, integrator);
    }

    /// @dev Shared by all four register entry points. `integrator == address(0)` ⇒ byte-identical to
    ///      V1's `_register` (same price, same treasury push, same events). `integrator != address(0)`
    ///      ⇒ `rateOf` is resolved and validated FIRST, before `_consumeCommitment` or `registry.register`
    ///      run, so a non-allow-listed integrator reverts `NotIntegrator` with the caller's commitment
    ///      and the name both untouched (fail-closed, no partial mutation).
    function _register(
        string calldata name,
        address owner,
        bytes32 secret,
        uint8 handleType,
        uint256 maxPrice,
        address integrator
    ) internal {
        if (!genesisSealed) revert RegistrationsClosed();
        if (!HandleNormalize.isCanonical(name)) revert NotCanonical(name);
        uint256 tokenId = ArcNSConstants.handleTokenId(name);
        if (registry.exists(tokenId)) revert NameNotAvailable(name);

        // Fail-closed BEFORE any state mutation: an unlisted/misconfigured integrator reverts the whole
        // registration here. `rateOf` is DEFAULT_ADMIN_ROLE-gated allow-list data on IntegratorRegistry;
        // this contract never sets it and cannot be tricked into treating a non-integrator as one.
        uint16 rateBps = integrator == address(0) ? 0 : integratorRegistry.rateOf(integrator);

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

        if (integrator == address(0)) {
            _payTreasury(tokenId, price);
        } else {
            // `computeSplit` re-derives the same `rateOf` internally; both calls read the identical,
            // already-validated allow-list entry within this one transaction (IntegratorRegistry makes
            // no external calls of its own, so there is no reentrancy/TOCTOU window between them).
            uint256 integratorShare = integratorRegistry.computeSplit(integrator, price);
            uint256 treasuryShare = price - integratorShare; // <= price by construction: rateBps <= CAP_BPS <= 10_000
            if (integratorShare > 0) {
                withdrawable[integrator] += integratorShare;
                emit Credited(integrator, integratorShare);
            }
            emit IIntegratorRegistry.FeeSplit(integrator, price, integratorShare, rateBps);
            _payTreasury(tokenId, treasuryShare);
        }

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
    /// @dev Pull ledger (SR-31). Not pausable: withdrawals must always work (SR-62). Serves both
    ///      overpayment refunds AND integrator fee-share withdrawals from the same ledger — an
    ///      integrator is just another `withdrawable[]` holder, same zero-then-transfer discipline.
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
    /// @dev Idempotent: names that already exist (minted by V1 before cutover, or by this contract)
    ///      are skipped, so a partial batch can be re-run safely. For a live registrar-swap cutover the
    ///      runbook calls `sealGenesis` immediately after deploy (see `deploy/runbooks/
    ///      integrator-v2-cutover.md`) — genesis already ran once against the shared `HandleRegistry`
    ///      under V1, so this batch is expected to mint zero names in that path and exists only so a
    ///      from-genesis testnet/mainnet deploy of V2 (no prior V1) still works unmodified.
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

    /// @dev INV-7: once sealed, `GENESIS_ROLE` can never be granted again.
    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        if (role == GENESIS_ROLE && genesisSealed) revert GenesisAlreadySealed();
        return super._grantRole(role, account);
    }
}
