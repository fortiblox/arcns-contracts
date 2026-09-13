// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IArcNSPriceOracle} from "../interfaces/IArcNSPriceOracle.sol";
import {IIntegratorRegistry} from "../interfaces/IIntegratorRegistry.sol";
import {ITldDirectory} from "../interfaces/ITldDirectory.sol";
import {ITldRegistrarControllerV3} from "../interfaces/ITldRegistrarControllerV3.sol";
import {ArcNSConstants} from "../lib/ArcNSConstants.sol";
import {HandleNormalize} from "../lib/HandleNormalize.sol";
import {LaunchAllowlist} from "../lib/LaunchAllowlist.sol";
import {TldRegistrar} from "./TldRegistrar.sol";

/// @title TldRegistrarControllerV3 — WP #7773: additive, no-resolver-only registrar controller
/// @notice A THIRD, purely additive controller alongside whichever of `TldRegistrarController` (V1) /
///         `TldRegistrarControllerV2` (V2) is currently live for a TLD — never a registrar-swap
///         replacement of either. `registerDirect` is the only entry point: a single-tx
///         `registrar.register(id, owner, duration)` mint with NO commit-reveal step and NO ENS side
///         effects at all (no `ens.setRecord`, no coin-type `Resolver.setAddr`, no `resolver.tagNode`,
///         no `reverseRegistrar.setNameForAddr`) — exactly the `registration.resolver == address(0)`
///         branch of `TldRegistrarControllerV2._register`, and only that branch.
///
/// @dev Architectural constraint this file is shaped by: `TldDirectory.setController` and
///      `ArcNSPriceOracle.namespaceInfo(namespaceId).controller` are BOTH single-address-per-node
///      fields — `setController` deletes the previous controller's binding the moment it is called,
///      and `ArcNSResolver.tagNode` only trusts whoever `TldDirectory` currently names as the
///      controller. Becoming the directory controller (to get an ENS/resolver record) or the oracle's
///      namespace controller (to call `recordSale`) would therefore EVICT whichever of V1/V2 holds
///      that slot today and stop this deployment from being additive. This contract deliberately never
///      calls `TldDirectory.setController` or `ArcNSPriceOracle.setController`, and holds no resolver,
///      ENS registry, or reverse-registrar reference at all — it only needs `TldRegistrar.addController`
///      (`BaseRegistrarImplementation.controllers` is a plain `mapping(address => bool)`, multi-holder
///      by construction) plus read-only references to `TldDirectory` (`registrationsOpen`) and
///      `ArcNSPriceOracle` (`quote`).
///
///      KNOWN, ACCEPTED SIDE EFFECTS of that trade-off (CEO-flagged, testnet-only limitation):
///        1. `oracle.recordSale(namespaceId)` is never called from this contract (it has no authority
///           to call it, and must never be granted any — same single-controller reasoning as above).
///           `totalSold`/`volumeBps` for a TLD's namespace therefore never advance from a
///           `registerDirect` mint, only from whichever controller the oracle still names.
///        2. `TldMetadata.tokenURI` always resolves a name's label through
///           `ITldRegistrarController(TldDirectory.get(tldNode).controller).labelOf(...)` — i.e.
///           whichever of V1/V2 is the CURRENT directory controller, never this contract, regardless of
///           which controller actually minted the token. A name registered through
///           `TldRegistrarControllerV3.registerDirect` has its label recorded correctly in THIS
///           contract's own `labels`/`paidWei` (readable via `labelOf`), but `TldMetadata.tokenURI`
///           looks it up on the wrong controller and reverts `UnknownLabel` — see
///           `test_tokenURI_for_v3_registered_name_reverts_unknownLabel_known_limitation` in the test
///           suite for the exact, verified behaviour.
///
///      Two instances (`.arc`, `.circle`) are byte-identical bytecode with different `Init`, same as
///      V1/V2.
contract TldRegistrarControllerV3 is AccessControl, Pausable, ReentrancyGuardTransient, ITldRegistrarControllerV3 {
    /// @notice Constructor arguments (struct so the deploy script and tests share one shape). Drops
    ///         `ens`/`resolver`/`reverseRegistrar`/`minCommitmentAge`/`maxCommitmentAge` relative to
    ///         V2's `Init` — none of them apply to a controller with no commit-reveal and no ENS path.
    struct Init {
        address admin;
        address genesisAdmin;
        address pauser;
        address registrar;
        address oracle;
        address directory;
        address treasury;
        address integratorRegistry;
        string tld;
    }

    /// @notice Thrown by the constructor for a zero address in `Init`.
    error ZeroAddress();

    /// @notice May run `registerReservedBatch` / `sealGenesis`; renounced inside `sealGenesis`.
    bytes32 public constant GENESIS_ROLE = ArcNSConstants.GENESIS_ROLE;
    /// @notice May pause `registerDirect` without a timelock delay (SR-62).
    bytes32 public constant PAUSER_ROLE = ArcNSConstants.PAUSER_ROLE;
    /// @inheritdoc ITldRegistrarControllerV3
    uint256 public constant MAX_ALLOWLIST_WINDOW = 90 days;
    /// @dev Q3 permanence: every name expires at `type(uint64).max` (BENS clamps ≥ 2^63 to null).
    uint256 private constant MAX_EXPIRY = type(uint64).max;

    TldRegistrar public immutable registrar;
    IArcNSPriceOracle public immutable oracle;
    /// @dev Read-only: `registrationsOpen` only. This contract never calls `setController` on it.
    ITldDirectory public immutable directory;
    /// @inheritdoc ITldRegistrarControllerV3
    address public immutable treasury;
    /// @notice The allow-list + rate resolver consulted for a non-zero `integrator` argument. Kept for
    ///         parity with V2's integrator-split machinery (see `_register`'s NatSpec) even though the
    ///         single public entry point on this contract, `registerDirect`, never passes one.
    IIntegratorRegistry public immutable integratorRegistry;
    /// @inheritdoc ITldRegistrarControllerV3
    bytes32 public immutable tldNode;
    /// @inheritdoc ITldRegistrarControllerV3
    bytes32 public immutable namespaceId;

    string private _tld;

    /// @inheritdoc ITldRegistrarControllerV3
    bool public genesisSealed;
    /// @inheritdoc ITldRegistrarControllerV3
    bytes32 public genesisRoot;
    /// @inheritdoc ITldRegistrarControllerV3
    uint256 public reservedCount;
    /// @inheritdoc ITldRegistrarControllerV3
    mapping(address who => uint256 amount) public withdrawable;
    /// @inheritdoc ITldRegistrarControllerV3
    mapping(bytes32 labelhash => uint256 priceWei) public paidWei;
    /// @notice Human label per labelhash, populated locally on THIS contract only (WP-143 convention);
    ///         `TldMetadata` never reads it — see the contract-level NatSpec's known-limitation note.
    mapping(bytes32 labelhash => string label) public labels;
    /// @inheritdoc ITldRegistrarControllerV3
    bytes32 public allowlistRoot;
    /// @inheritdoc ITldRegistrarControllerV3
    uint64 public allowlistSunset;

    constructor(Init memory init) {
        if (
            init.admin == address(0) || init.genesisAdmin == address(0) || init.pauser == address(0)
                || init.registrar == address(0) || init.oracle == address(0) || init.directory == address(0)
                || init.treasury == address(0) || init.integratorRegistry == address(0)
        ) revert ZeroAddress();
        if (!HandleNormalize.isCanonical(init.tld)) revert NotCanonical(init.tld);

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(GENESIS_ROLE, init.genesisAdmin);
        _grantRole(PAUSER_ROLE, init.pauser);

        registrar = TldRegistrar(init.registrar);
        oracle = IArcNSPriceOracle(init.oracle);
        directory = ITldDirectory(init.directory);
        treasury = init.treasury;
        integratorRegistry = IIntegratorRegistry(init.integratorRegistry);
        _tld = init.tld;
        bytes32 node = HandleNormalize.tldNode(init.tld);
        tldNode = node;
        namespaceId = node;
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ITldRegistrarControllerV3
    function tld() external view returns (string memory) {
        return _tld;
    }

    /// @inheritdoc ITldRegistrarControllerV3
    function labelOf(bytes32 labelhash) external view returns (string memory) {
        return labels[labelhash];
    }

    /// @inheritdoc ITldRegistrarControllerV3
    function valid(string calldata label) public pure returns (bool) {
        return HandleNormalize.isCanonical(label);
    }

    /// @inheritdoc ITldRegistrarControllerV3
    function available(string calldata label) public view returns (bool) {
        return valid(label) && registrar.available(uint256(keccak256(bytes(label))));
    }

    /// @inheritdoc ITldRegistrarControllerV3
    function quote(string calldata label) public view returns (uint256 priceWei) {
        return oracle.quote(namespaceId, label);
    }

    /// @inheritdoc ITldRegistrarControllerV3
    function allowlistActive() public view returns (bool) {
        return allowlistRoot != bytes32(0) && block.timestamp < allowlistSunset;
    }

    /// @inheritdoc ITldRegistrarControllerV3
    function isAllowlisted(address owner, bytes32[] calldata proof) public view returns (bool) {
        return LaunchAllowlist.isAllowed(allowlistRoot, proof, owner);
    }

    // ---------------------------------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ITldRegistrarControllerV3
    /// @dev No allowlist-proof sibling exists on this controller (unlike V1/V2's
    ///      `registerWithProof`): while `allowlistActive()` is true, `registerDirect` is unconditionally
    ///      refused until the allowlist is cleared or its sunset passes.
    function registerDirect(string calldata label, address owner, uint256 maxPrice)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (allowlistActive()) revert AllowlistRequired();
        _register(label, owner, maxPrice, address(0));
    }

    /// @dev Copied from `TldRegistrarControllerV2._register`, restricted to the `resolver ==
    ///      address(0)` branch and with the commit-reveal step deleted entirely (no
    ///      `_consumeCommitment`/`makeCommitment` call or replacement). The integrator-split branch is
    ///      kept intact (dead code from `registerDirect`, which always passes `address(0)`) purely to
    ///      keep the door open for a future `registerDirectWithIntegrator` overload, same rationale as
    ///      V2's own NatSpec.
    function _register(string calldata label, address owner, uint256 maxPrice, address integrator) private {
        if (!genesisSealed || !directory.registrationsOpen(tldNode)) revert RegistrationsClosed();
        if (!HandleNormalize.isCanonical(label)) revert NotCanonical(label);

        bytes32 labelhash = keccak256(bytes(label));
        if (!registrar.available(uint256(labelhash))) revert NameNotAvailable(label);

        uint16 rateBps = integrator == address(0) ? 0 : integratorRegistry.rateOf(integrator);

        uint256 price = oracle.quote(namespaceId, label);
        if (price > maxPrice) revert PriceChanged(price, maxPrice);
        if (msg.value < price) revert InsufficientValue(price, msg.value);

        // Only the plain-mint half of V2's ternary exists here: no `_registerWithResolver`, no ENS
        // registry reference, no resolver reference, no reverse-registrar reference on this contract.
        uint256 expires = registrar.register(uint256(labelhash), owner, MAX_EXPIRY - block.timestamp);

        paidWei[labelhash] = price;
        labels[labelhash] = label;
        registrar.emitMetadataUpdate(uint256(labelhash));
        // Deliberately no `oracle.recordSale(namespaceId)` call — see the contract-level NatSpec's
        // known-limitation note. This contract must never become the oracle's namespace controller, so
        // it can never legally call `recordSale` either.

        _settle(labelhash, price, integrator, rateBps);

        bytes32 referrer = integrator == address(0) ? bytes32(0) : bytes32(uint256(uint160(integrator)));
        emit NameRegistered(label, labelhash, owner, price, 0, expires, referrer);
    }

    /// @inheritdoc ITldRegistrarControllerV3
    function withdraw() external nonReentrant {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert WithdrawFailed(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Genesis (GENESIS_ROLE; closed by sealGenesis)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ITldRegistrarControllerV3
    /// @dev Copied verbatim from V2 except the `resolver.tagNode(...)` line is deleted (this contract
    ///      has no `resolver` field to call it on, and has no tagNode authority anyway since it never
    ///      becomes the directory controller). In practice this never mints today: genesis has already
    ///      run under V1/V2 against the shared `TldRegistrar`, so every label passed here already
    ///      exists and `continue`s past the mint — the line is deleted for correctness, not because it
    ///      is reachable. RUNBOOK: see the operational warning on `sealGenesis` below about reservation
    ///      batches still pending on V1/V2 for the same TLD.
    function registerReservedBatch(string[] calldata reservedLabels) external {
        if (genesisSealed) revert GenesisAlreadySealed();
        _checkRole(GENESIS_ROLE);
        uint256 duration = MAX_EXPIRY - block.timestamp;
        uint256 minted = 0;
        for (uint256 i = 0; i < reservedLabels.length; i++) {
            string calldata label = reservedLabels[i];
            if (!HandleNormalize.isCanonical(label)) revert NotCanonical(label);
            bytes32 labelhash = keccak256(bytes(label));
            uint256 id = uint256(labelhash);
            if (!registrar.available(id)) continue;
            uint256 expires = registrar.register(id, treasury, duration);
            labels[labelhash] = label;
            minted++;
            emit ReservedRegistered(labelhash, label);
            emit NameRegistered(label, labelhash, treasury, 0, 0, expires, bytes32(0));
        }
        reservedCount += minted;
    }

    /// @inheritdoc ITldRegistrarControllerV3
    /// @dev RUNBOOK WARNING, load-bearing: `genesisSealed`/`reservedCount` are state local to THIS
    ///      contract only — they know nothing about `TldRegistrarController` (V1) or
    ///      `TldRegistrarControllerV2`'s own independent genesis state, even though all three controllers
    ///      register onto the SAME shared `TldRegistrar` for this TLD. V1/V2's commit-reveal flow always
    ///      gave the operator an incidental buffer (`MIN_COMMITMENT_AGE_FLOOR`, >= 30s) between a name
    ///      becoming registerable and it actually landing, during which a reservation batch still in
    ///      flight could be finished first. `registerDirect` has NO such buffer — zero delay between
    ///      transaction submission and mint. The operator MUST NOT call `sealGenesis` on this contract
    ///      until every reserved/team/premium-name batch for this TLD, across EVERY controller live on
    ///      this `TldRegistrar` (V1, V2, and this contract), has finished registering on-chain. Sealing
    ///      early makes any label still unregistered by another controller's pending batch immediately
    ///      `registerDirect`-able by anyone. Nothing in this contract (or in V1/V2) enforces that
    ///      cross-controller ordering — it is a manual genesis-launch runbook precondition, not a
    ///      compile-time or on-chain guarantee.
    function sealGenesis(bytes32 merkleRoot) external {
        if (genesisSealed) revert GenesisAlreadySealed();
        _checkRole(GENESIS_ROLE);
        genesisSealed = true;
        genesisRoot = merkleRoot;
        emit GenesisSealed(tldNode, merkleRoot, reservedCount);
        _revokeRole(GENESIS_ROLE, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Launch allowlist (DEFAULT_ADMIN_ROLE = timelock)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ITldRegistrarControllerV3
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
    // Pause (only `registerDirect`; SR-62)
    // ---------------------------------------------------------------------------------------------

    /// @notice Pause `registerDirect`. `PAUSER_ROLE` (Admin Safe, no delay) or the admin. Independent
    ///         of whatever V1/V2 hold as their own `PAUSER_ROLE` on their own contracts — pausing V1/V2
    ///         does NOT pause this contract, and vice versa (each controller's pause is fully separate;
    ///         an incident responder must pause all three individually).
    function pause() external {
        if (!hasRole(PAUSER_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, PAUSER_ROLE);
        }
        _pause();
    }

    /// @notice Unpause; admin (timelock) only.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-165 / value guard
    // ---------------------------------------------------------------------------------------------

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(ITldRegistrarControllerV3).interfaceId || super.supportsInterface(interfaceId);
    }

    receive() external payable {
        revert ValueNotAccepted();
    }

    fallback() external payable {
        revert ValueNotAccepted();
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Fee split + settle, verbatim V2/V1 `_settle`. `integrator == address(0)` ⇒ 100% to
    ///      treasury. Overpayment is credited to the PAYER's pull ledger, never pushed (SR-11/31, Arc
    ///      blocklist hazard).
    function _settle(bytes32 labelhash, uint256 price, address integrator, uint16 rateBps) private {
        if (integrator == address(0)) {
            if (price > 0) {
                (bool ok,) = payable(treasury).call{value: price}("");
                if (!ok) revert TreasuryPaymentFailed(treasury, price);
                emit TreasuryFee(labelhash, price);
            }
        } else {
            uint256 integratorShare = integratorRegistry.computeSplit(integrator, price);
            uint256 treasuryShare = price - integratorShare;
            if (integratorShare > 0) {
                withdrawable[integrator] += integratorShare;
                emit Credited(integrator, integratorShare);
            }
            emit IIntegratorRegistry.FeeSplit(integrator, price, integratorShare, rateBps);
            if (treasuryShare > 0) {
                (bool ok,) = payable(treasury).call{value: treasuryShare}("");
                if (!ok) revert TreasuryPaymentFailed(treasury, treasuryShare);
                emit TreasuryFee(labelhash, treasuryShare);
            }
        }
        if (msg.value > price) {
            uint256 change = msg.value - price;
            // slither-disable-next-line reentrancy-eth
            withdrawable[msg.sender] += change;
            emit Credited(msg.sender, change);
        }
    }

    /// @dev INV-7: once sealed, `GENESIS_ROLE` can never be granted again.
    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        if (role == GENESIS_ROLE && genesisSealed) revert GenesisAlreadySealed();
        return super._grantRole(role, account);
    }
}
