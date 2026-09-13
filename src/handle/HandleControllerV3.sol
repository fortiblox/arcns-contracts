// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IHandleControllerV3} from "../interfaces/IHandleControllerV3.sol";
import {IHandleRegistry} from "../interfaces/IHandleRegistry.sol";
import {IArcNSPriceOracle} from "../interfaces/IArcNSPriceOracle.sol";
import {IIntegratorRegistry} from "../interfaces/IIntegratorRegistry.sol";
import {ArcNSConstants} from "../lib/ArcNSConstants.sol";
import {HandleNormalize} from "../lib/HandleNormalize.sol";
import {LaunchAllowlist} from "../lib/LaunchAllowlist.sol";

/// @title HandleControllerV3 — TESTNET-ONLY, additive single-transaction registrar for the handle namespace
/// @notice Trade-off, stated up front: front-running protection is intentionally dropped.
///         `registerDirect` mints in one transaction with no commit-reveal step, which means a
///         registration can in principle be front-run by watching the mempool. That is acceptable ONLY
///         on testnet, where names carry no real value and UX/iteration speed matters more than
///         griefing resistance. Mainnet keeps `HandleControllerV2`'s (and V1's) commit-reveal flow
///         unchanged — this contract is never intended to be deployed there.
///
///         This deployment is purely additive: it is granted `HandleRegistry.REGISTRAR_ROLE` alongside
///         whichever of `HandleController` (V1) or `HandleControllerV2` is already live, and it never
///         revokes anything from either. V1/V2 keep registering names exactly as before; V3 is a third,
///         independent entry point onto the same `HandleRegistry`.
///
/// @dev Oracle interaction, the single most important design decision in this file: V3 NEVER calls
///      `oracle.recordSale`. `ArcNSPriceOracle.namespaceInfo(HANDLE_ROOT).controller` is a single
///      address per namespace — `recordSale` reverts `NotNamespaceController` for anyone else, and
///      `setController` REPLACES that address rather than adding to a set (see
///      `script/lib/ControllerV2CutoverLib.sol`'s own NatSpec). Making V3 the oracle's namespace
///      controller would silently break `recordSale` for whichever of V1/V2 currently holds that slot —
///      exactly the "existing commit-reveal controller" this deployment must not disturb (standing CEO
///      decision, Q2 2026-09-12, not to redesign the oracle to be multi-controller). So V3 must never
///      touch `oracle.setController`, and consequently must never call `oracle.recordSale`.
///
///      Net effect, called out explicitly rather than shipped silently: registrations made through
///      `HandleControllerV3` do NOT advance the price curve's `totalSold`/`volumeBps` counter for
///      `HANDLE_ROOT`. `oracle.quote()` is unaffected (pure/view, no role needed), so V3 still charges
///      the live curve price correctly — V3 registrations just never push that curve forward.
///
///      Everything else mirrors `HandleControllerV2`: same roles, same pull-ledger withdraw, same
///      genesis/allowlist/pause machinery, same `_register` shape (including the integrator-split
///      branch, kept verbatim even though `registerDirect` never exercises it with a non-zero
///      integrator — see the NatSpec on `_register`).
contract HandleControllerV3 is IHandleControllerV3, AccessControl, Pausable, ReentrancyGuardTransient {
    // ---------------------------------------------------------------------------------------------
    // Types / constants / immutables
    // ---------------------------------------------------------------------------------------------

    /// @dev Constructor bundle (keeps the deploy script readable and avoids stack pressure). Same as
    ///      `HandleControllerV2.Init` minus `minCommitmentAge`/`maxCommitmentAge` — there is no
    ///      commitment window to configure.
    struct Init {
        address admin;
        address genesisAdmin;
        address pauser;
        address registry;
        address oracle;
        address treasury;
        address integratorRegistry;
    }

    /// @dev Constructor-only guard; not part of the interface (deploy-time misconfiguration).
    error ZeroAddress();

    bytes32 public constant GENESIS_ROLE = ArcNSConstants.GENESIS_ROLE;
    bytes32 public constant PAUSER_ROLE = ArcNSConstants.PAUSER_ROLE;

    /// @inheritdoc IHandleControllerV3
    uint256 public constant MAX_ALLOWLIST_WINDOW = 90 days;

    IHandleRegistry public immutable registry;
    IArcNSPriceOracle public immutable oracle;
    /// @inheritdoc IHandleControllerV3
    address public immutable treasury;
    /// @inheritdoc IHandleControllerV3
    IIntegratorRegistry public immutable integratorRegistry;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleControllerV3
    bool public genesisSealed;
    /// @inheritdoc IHandleControllerV3
    bytes32 public genesisRoot;
    /// @inheritdoc IHandleControllerV3
    uint256 public reservedCount;
    /// @inheritdoc IHandleControllerV3
    mapping(address who => uint256 amount) public withdrawable;
    /// @inheritdoc IHandleControllerV3
    bytes32 public allowlistRoot;
    /// @inheritdoc IHandleControllerV3
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
        registry = IHandleRegistry(init.registry);
        oracle = IArcNSPriceOracle(init.oracle);
        treasury = init.treasury;
        integratorRegistry = IIntegratorRegistry(init.integratorRegistry);
        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(GENESIS_ROLE, init.genesisAdmin);
        _grantRole(PAUSER_ROLE, init.pauser);
    }

    /// @dev Dust / mis-sent value is refused (T-GAS-1). Only `registerDirect` is payable.
    receive() external payable {
        revert ValueNotAccepted();
    }

    fallback() external payable {
        revert ValueNotAccepted();
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleControllerV3
    function namespaceId() external pure returns (bytes32) {
        return ArcNSConstants.HANDLE_ROOT;
    }

    /// @inheritdoc IHandleControllerV3
    function valid(string calldata name) public pure returns (bool) {
        return HandleNormalize.isCanonical(name);
    }

    /// @inheritdoc IHandleControllerV3
    function available(string calldata name) public view returns (bool) {
        return valid(name) && !registry.exists(ArcNSConstants.handleTokenId(name));
    }

    /// @inheritdoc IHandleControllerV3
    function quote(string calldata name) public view returns (uint256 priceWei) {
        return oracle.quote(ArcNSConstants.HANDLE_ROOT, name);
    }

    /// @inheritdoc IHandleControllerV3
    function allowlistActive() public view returns (bool) {
        return allowlistRoot != bytes32(0) && block.timestamp < allowlistSunset;
    }

    /// @inheritdoc IHandleControllerV3
    function isAllowlisted(address owner, bytes32[] calldata proof) public view returns (bool) {
        return LaunchAllowlist.isAllowed(allowlistRoot, proof, owner);
    }

    // ---------------------------------------------------------------------------------------------
    // Registration — no commit/reveal
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleControllerV3
    /// @dev Structurally V2's `register()` with `bytes32 secret` removed from both the signature and
    ///      the internal call — no commitment is ever made or consumed. There is no proof-taking
    ///      sibling (no `registerDirectWithProof`): while an allowlist is active on THIS contract's own
    ///      `allowlistRoot`, `registerDirect` always reverts `AllowlistRequired` with no way through.
    ///      V3's allowlist is independent per-contract state (defaults `root == 0`, i.e. inactive), so
    ///      this only matters if governance later calls `setAllowlist` on V3 itself.
    function registerDirect(string calldata name, address owner, uint8 handleType, uint256 maxPrice)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (allowlistActive()) revert AllowlistRequired();
        _register(name, owner, handleType, maxPrice, address(0));
    }

    /// @dev Copied from `HandleControllerV2._register` verbatim, line order preserved, except: (1) the
    ///      `bytes32 secret` parameter and the `_consumeCommitment(makeCommitment(...))` line are
    ///      removed entirely (no replacement — this is the "remove commit-reveal" instruction), and (2)
    ///      `oracle.recordSale(ArcNSConstants.HANDLE_ROOT)` is removed entirely (see the contract-level
    ///      NatSpec above for why — this is required, not optional). Everything else, INCLUDING the
    ///      integrator-split branch, is kept byte-for-byte: `registerDirect` only ever calls this with
    ///      `integrator == address(0)`, so that branch is dead code from today's public surface, kept
    ///      only because a future `registerDirectWithIntegrator` overload could reuse it unmodified.
    function _register(string calldata name, address owner, uint8 handleType, uint256 maxPrice, address integrator)
        internal
    {
        if (!genesisSealed) revert RegistrationsClosed();
        if (!HandleNormalize.isCanonical(name)) revert NotCanonical(name);
        uint256 tokenId = ArcNSConstants.handleTokenId(name);
        if (registry.exists(tokenId)) revert NameNotAvailable(name);

        // Fail-closed BEFORE any state mutation: an unlisted/misconfigured integrator reverts the whole
        // registration here. `rateOf` is DEFAULT_ADMIN_ROLE-gated allow-list data on IntegratorRegistry;
        // this contract never sets it and cannot be tricked into treating a non-integrator as one.
        uint16 rateBps = integrator == address(0) ? 0 : integratorRegistry.rateOf(integrator);

        uint256 price = oracle.quote(ArcNSConstants.HANDLE_ROOT, name);
        if (price > maxPrice) revert PriceChanged(price, maxPrice);
        if (msg.value < price) revert InsufficientValue(price, msg.value);

        uint256 minted = registry.register(name, owner, handleType, false);
        assert(minted == tokenId); // registry derives the id the same way (SR-20 single source)

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

    /// @dev Push to the Treasury Safe; a failing push reverts the registration (onchain-design §6).
    ///      Copied verbatim from `HandleControllerV2._payTreasury`.
    function _payTreasury(uint256 tokenId, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = treasury.call{value: amount}("");
        if (!ok) revert TreasuryPaymentFailed(treasury, amount);
        emit TreasuryFee(tokenId, amount);
    }

    /// @inheritdoc IHandleControllerV3
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

    /// @inheritdoc IHandleControllerV3
    /// @dev Idempotent: names that already exist (minted by V1/V2 before V3 shipped, or by this
    ///      contract) are skipped, so a partial batch can be re-run safely. RUNBOOK: this only covers
    ///      names reserved on THIS contract's own batch — see the operational warning on `sealGenesis`
    ///      below about reservation batches still pending on V1/V2 for the same launch.
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

    /// @inheritdoc IHandleControllerV3
    /// @dev Opens public registration and revokes GENESIS_ROLE from the caller in the same tx (SR-16).
    ///
    ///      RUNBOOK WARNING, load-bearing: `genesisSealed`/`reservedCount` are state local to THIS
    ///      contract only — they know nothing about `HandleController` (V1) or `HandleControllerV2`'s own
    ///      independent genesis state, even though all three controllers mint onto the SAME shared
    ///      `HandleRegistry`. V1/V2's commit-reveal flow always gave the operator an incidental buffer
    ///      (`MIN_COMMITMENT_AGE_FLOOR`, >= 30s) between a name becoming registerable and it actually
    ///      landing, during which a reservation batch still in flight could be finished first.
    ///      `registerDirect` has NO such buffer — zero delay between transaction submission and mint. The
    ///      operator MUST NOT call `sealGenesis` on this contract until every reserved/team/premium-name
    ///      batch for this namespace, across EVERY controller live on this `HandleRegistry` (V1, V2, and
    ///      this contract), has finished registering on-chain. Sealing early makes any name still
    ///      unregistered by another controller's pending batch immediately `registerDirect`-able by
    ///      anyone. Nothing in this contract (or in V1/V2) enforces that cross-controller ordering —
    ///      it is a manual genesis-launch runbook precondition, not a compile-time or on-chain guarantee.
    function sealGenesis(bytes32 merkleRoot) external onlyRole(GENESIS_ROLE) {
        if (genesisSealed) revert GenesisAlreadySealed();
        genesisSealed = true;
        genesisRoot = merkleRoot;
        emit GenesisSealed(ArcNSConstants.HANDLE_ROOT, merkleRoot, reservedCount);
        _revokeRole(GENESIS_ROLE, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Launch allowlist (DEFAULT_ADMIN_ROLE = timelock)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHandleControllerV3
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
