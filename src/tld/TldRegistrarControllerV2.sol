// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

// Verbatim ens-contracts v1.7.0 ABIs (interfaces only; no OZ 4 contract enters this graph).
import {ENS} from "@ensdomains/ens-contracts/registry/ENS.sol";
import {IReverseRegistrar} from "@ensdomains/ens-contracts/reverseRegistrar/IReverseRegistrar.sol";
import {Resolver} from "@ensdomains/ens-contracts/resolvers/Resolver.sol";

import {IArcNSPriceOracle} from "../interfaces/IArcNSPriceOracle.sol";
import {IArcNSResolver} from "../interfaces/IArcNSResolver.sol";
import {IIntegratorRegistry} from "../interfaces/IIntegratorRegistry.sol";
import {ITldDirectory} from "../interfaces/ITldDirectory.sol";
import {ITldRegistrarController} from "../interfaces/ITldRegistrarController.sol";
import {ITldRegistrarControllerV2} from "../interfaces/ITldRegistrarControllerV2.sol";
import {ArcNSConstants} from "../lib/ArcNSConstants.sol";
import {HandleNormalize} from "../lib/HandleNormalize.sol";
import {LaunchAllowlist} from "../lib/LaunchAllowlist.sol";
import {TldRegistrar} from "./TldRegistrar.sol";

/// @title TldRegistrarControllerV2 — C5 replacement, WP #7772: adds the integrator revenue-share overload
/// @notice Registrar-swap successor to `TldRegistrarController` (immutable by design, SR-60): a new
///         deployment re-pointed via `TldDirectory.setController` + `BaseRegistrar.addController`/
///         `removeController`, not a patch. V1 behaviour is preserved byte-for-byte on the original
///         `register`/`registerWithProof(Registration, uint256[, proof])` entry points (both run the
///         same `_register` with `integrator = address(0)`). New: `registerWithIntegrator`/
///         `registerWithProofAndIntegrator` (`ITldRegistrarControllerV2`) split the price with an
///         allow-listed integrator AND populate the verbatim ENS `NameRegistered.referrer` field
///         (hard-coded `bytes32(0)` on every V1 emit site) with the integrator address, so BENS/indexer
///         consumers see the referral without an event-schema change.
///
/// @dev Integrator safety (CEO requirement, WP #7772): identical guarantee to `HandleControllerV2` —
///      no allow-list, no rate-setting, no self-registration path lives in this file. `rateOf`/
///      `computeSplit` are the ONLY calls into `IIntegratorRegistry`; both are read-only views on a
///      separate, `DEFAULT_ADMIN_ROLE` (timelock)-gated contract whose `CAP_BPS` (40%) hard-limits any
///      rate this controller could ever pay out. `rateOf` runs BEFORE `_consumeCommitment`/
///      `registrar.register`, so an unlisted integrator reverts the whole registration with zero state
///      change (fail-closed).
///
///      Two instances (`.arc`, `.circle`) are byte-identical bytecode with different `Init`, same as V1.
contract TldRegistrarControllerV2 is
    AccessControl,
    Pausable,
    ReentrancyGuardTransient,
    ITldRegistrarController,
    ITldRegistrarControllerV2
{
    /// @notice Constructor arguments (struct so the deploy script and tests share one shape).
    struct Init {
        address admin;
        address genesisAdmin;
        address pauser;
        address registrar;
        address ens;
        address oracle;
        address resolver;
        address reverseRegistrar;
        address directory;
        address treasury;
        address integratorRegistry;
        uint256 minCommitmentAge;
        uint256 maxCommitmentAge;
        string tld;
    }

    /// @notice Thrown by the constructor for a zero address in `Init`.
    error ZeroAddress();

    /// @notice May run `registerReservedBatch` / `sealGenesis`; renounced inside `sealGenesis`.
    bytes32 public constant GENESIS_ROLE = ArcNSConstants.GENESIS_ROLE;
    /// @notice May pause `register` (only `register`) without a timelock delay (SR-62).
    bytes32 public constant PAUSER_ROLE = ArcNSConstants.PAUSER_ROLE;
    /// @inheritdoc ITldRegistrarController
    uint256 public constant MIN_COMMITMENT_AGE_FLOOR = 30 seconds;
    /// @inheritdoc ITldRegistrarController
    uint256 public constant MAX_ALLOWLIST_WINDOW = 90 days;
    /// @dev Upper bound for `maxCommitmentAge` (SR-10).
    uint256 private constant MAX_COMMITMENT_AGE_CAP = 24 hours;
    /// @dev Q3 permanence: every name expires at `type(uint64).max` (BENS clamps ≥ 2^63 to null).
    uint256 private constant MAX_EXPIRY = type(uint64).max;

    TldRegistrar public immutable registrar;
    ENS public immutable ens;
    IArcNSPriceOracle public immutable oracle;
    /// @notice Our resolver (C7): the only one that receives `tagNode`; users may still pick another.
    IArcNSResolver public immutable resolver;
    IReverseRegistrar public immutable reverseRegistrar;
    ITldDirectory public immutable directory;
    /// @inheritdoc ITldRegistrarController
    address public immutable treasury;
    /// @inheritdoc ITldRegistrarControllerV2
    IIntegratorRegistry public immutable integratorRegistry;
    /// @inheritdoc ITldRegistrarController
    bytes32 public immutable tldNode;
    /// @inheritdoc ITldRegistrarController
    bytes32 public immutable namespaceId;
    /// @inheritdoc ITldRegistrarController
    uint256 public immutable minCommitmentAge;
    /// @inheritdoc ITldRegistrarController
    uint256 public immutable maxCommitmentAge;

    string private _tld;

    /// @inheritdoc ITldRegistrarController
    bool public genesisSealed;
    /// @inheritdoc ITldRegistrarController
    bytes32 public genesisRoot;
    /// @inheritdoc ITldRegistrarController
    uint256 public reservedCount;
    /// @inheritdoc ITldRegistrarController
    mapping(bytes32 commitment => uint256 timestamp) public commitments;
    /// @inheritdoc ITldRegistrarController
    mapping(address who => uint256 amount) public withdrawable;
    /// @inheritdoc ITldRegistrarController
    mapping(bytes32 labelhash => uint256 priceWei) public paidWei;
    /// @notice Human label per labelhash (WP-143); read by `TldMetadata` through `labelOf`.
    mapping(bytes32 labelhash => string label) public labels;
    /// @inheritdoc ITldRegistrarController
    bytes32 public allowlistRoot;
    /// @inheritdoc ITldRegistrarController
    uint64 public allowlistSunset;

    constructor(Init memory init) {
        if (init.minCommitmentAge < MIN_COMMITMENT_AGE_FLOOR) {
            revert MinCommitmentAgeBelowFloor(init.minCommitmentAge, MIN_COMMITMENT_AGE_FLOOR);
        }
        if (init.maxCommitmentAge <= init.minCommitmentAge || init.maxCommitmentAge > MAX_COMMITMENT_AGE_CAP) {
            revert MaxCommitmentAgeInvalid(init.maxCommitmentAge);
        }
        if (
            init.admin == address(0) || init.genesisAdmin == address(0) || init.pauser == address(0)
                || init.registrar == address(0) || init.ens == address(0) || init.oracle == address(0)
                || init.resolver == address(0) || init.reverseRegistrar == address(0) || init.directory == address(0)
                || init.treasury == address(0) || init.integratorRegistry == address(0)
        ) revert ZeroAddress();
        if (!HandleNormalize.isCanonical(init.tld)) revert NotCanonical(init.tld);

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(GENESIS_ROLE, init.genesisAdmin);
        _grantRole(PAUSER_ROLE, init.pauser);

        registrar = TldRegistrar(init.registrar);
        ens = ENS(init.ens);
        oracle = IArcNSPriceOracle(init.oracle);
        resolver = IArcNSResolver(init.resolver);
        reverseRegistrar = IReverseRegistrar(init.reverseRegistrar);
        directory = ITldDirectory(init.directory);
        treasury = init.treasury;
        integratorRegistry = IIntegratorRegistry(init.integratorRegistry);
        minCommitmentAge = init.minCommitmentAge;
        maxCommitmentAge = init.maxCommitmentAge;
        _tld = init.tld;
        bytes32 node = HandleNormalize.tldNode(init.tld);
        tldNode = node;
        namespaceId = node;
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ITldRegistrarController
    function tld() external view returns (string memory) {
        return _tld;
    }

    /// @inheritdoc ITldRegistrarController
    function labelOf(bytes32 labelhash) external view returns (string memory) {
        return labels[labelhash];
    }

    /// @inheritdoc ITldRegistrarController
    function valid(string calldata label) public pure returns (bool) {
        return HandleNormalize.isCanonical(label);
    }

    /// @inheritdoc ITldRegistrarController
    function available(string calldata label) public view returns (bool) {
        return valid(label) && registrar.available(uint256(keccak256(bytes(label))));
    }

    /// @inheritdoc ITldRegistrarController
    function quote(string calldata label) public view returns (uint256 priceWei) {
        return oracle.quote(namespaceId, label);
    }

    /// @inheritdoc ITldRegistrarController
    function allowlistActive() public view returns (bool) {
        return allowlistRoot != bytes32(0) && block.timestamp < allowlistSunset;
    }

    /// @inheritdoc ITldRegistrarController
    function isAllowlisted(address owner, bytes32[] calldata proof) public view returns (bool) {
        return LaunchAllowlist.isAllowed(allowlistRoot, proof, owner);
    }

    /// @inheritdoc ITldRegistrarController
    /// @dev SR-10 shape, verbatim V1. The integrator is deliberately NOT part of the commitment (same
    ///      rationale as `HandleControllerV2.makeCommitment`): it only routes the payment split.
    function makeCommitment(Registration calldata registration) public view returns (bytes32) {
        if (registration.data.length > 0 && registration.resolver == address(0)) {
            revert ResolverRequiredWhenDataSupplied();
        }
        if (registration.reverseRecord && registration.resolver == address(0)) {
            revert ResolverRequiredForReverseRecord();
        }
        // Memory copy: nine calldata fields exceed the ABI encoder's stack budget without via_ir; the
        // encoding (and therefore the commitment) is identical.
        Registration memory r = registration;
        return keccak256(
            abi.encode(
                _tld, r.label, r.owner, r.secret, block.chainid, address(this), r.resolver, r.data, r.reverseRecord
            )
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Commit / reveal
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ITldRegistrarController
    function commit(bytes32 commitment) external {
        if (commitments[commitment] + maxCommitmentAge >= block.timestamp) {
            revert UnexpiredCommitmentExists(commitment);
        }
        commitments[commitment] = block.timestamp;
        emit CommitmentMade(commitment, block.timestamp);
    }

    /// @inheritdoc ITldRegistrarController
    /// @dev Byte-for-byte V1 behaviour: `integrator = address(0)`, `referrer = bytes32(0)`.
    function register(Registration calldata registration, uint256 maxPrice)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (allowlistActive()) revert AllowlistRequired();
        _register(registration, maxPrice, address(0));
    }

    /// @inheritdoc ITldRegistrarController
    function registerWithProof(Registration calldata registration, uint256 maxPrice, bytes32[] calldata proof)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (allowlistActive() && !isAllowlisted(registration.owner, proof)) {
            revert NotAllowlisted(registration.owner);
        }
        _register(registration, maxPrice, address(0));
    }

    /// @inheritdoc ITldRegistrarControllerV2
    function registerWithIntegrator(Registration calldata registration, uint256 maxPrice, address integrator)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (integrator == address(0)) revert IntegratorRequired();
        if (allowlistActive()) revert AllowlistRequired();
        _register(registration, maxPrice, integrator);
    }

    /// @inheritdoc ITldRegistrarControllerV2
    function registerWithProofAndIntegrator(
        Registration calldata registration,
        uint256 maxPrice,
        bytes32[] calldata proof,
        address integrator
    ) external payable nonReentrant whenNotPaused {
        if (integrator == address(0)) revert IntegratorRequired();
        if (allowlistActive() && !isAllowlisted(registration.owner, proof)) {
            revert NotAllowlisted(registration.owner);
        }
        _register(registration, maxPrice, integrator);
    }

    /// @dev Shared by all four register entry points. `integrator == address(0)` ⇒ byte-identical V1
    ///      path. Otherwise `rateOf` is resolved and validated FIRST (fail-closed, no partial mutation
    ///      on a bad integrator — same ordering guarantee as `HandleControllerV2._register`).
    function _register(Registration calldata registration, uint256 maxPrice, address integrator) private {
        if (!genesisSealed || !directory.registrationsOpen(tldNode)) revert RegistrationsClosed();
        if (!HandleNormalize.isCanonical(registration.label)) revert NotCanonical(registration.label);

        bytes32 labelhash = keccak256(bytes(registration.label));
        if (!registrar.available(uint256(labelhash))) revert NameNotAvailable(registration.label);

        uint16 rateBps = integrator == address(0) ? 0 : integratorRegistry.rateOf(integrator);

        _consumeCommitment(makeCommitment(registration));

        uint256 price = oracle.quote(namespaceId, registration.label);
        if (price > maxPrice) revert PriceChanged(price, maxPrice);
        if (msg.value < price) revert InsufficientValue(price, msg.value);

        uint256 expires = registration.resolver == address(0)
            ? registrar.register(uint256(labelhash), registration.owner, MAX_EXPIRY - block.timestamp)
            : _registerWithResolver(registration, labelhash);

        paidWei[labelhash] = price;
        labels[labelhash] = registration.label;
        registrar.emitMetadataUpdate(uint256(labelhash));
        oracle.recordSale(namespaceId);

        _settle(labelhash, price, integrator, rateBps);

        bytes32 referrer = integrator == address(0) ? bytes32(0) : bytes32(uint256(uint160(integrator)));
        emit NameRegistered(registration.label, labelhash, registration.owner, price, 0, expires, referrer);
    }

    /// @inheritdoc ITldRegistrarController
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

    /// @inheritdoc ITldRegistrarController
    /// @dev Idempotent, verbatim V1. For a live registrar-swap cutover the runbook calls `sealGenesis`
    ///      immediately after deploy (genesis already ran once under V1 against the shared
    ///      `TldRegistrar`); this batch mints zero names in that path and exists only so a from-genesis
    ///      deploy of V2 (no prior V1) still works unmodified.
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
            resolver.tagNode(keccak256(abi.encodePacked(tldNode, labelhash)), tldNode, id);
            minted++;
            emit ReservedRegistered(labelhash, label);
            emit NameRegistered(label, labelhash, treasury, 0, 0, expires, bytes32(0));
        }
        reservedCount += minted;
    }

    /// @inheritdoc ITldRegistrarController
    function sealGenesis(bytes32 merkleRoot) external {
        if (genesisSealed) revert GenesisAlreadySealed();
        _checkRole(GENESIS_ROLE);
        genesisSealed = true;
        genesisRoot = merkleRoot;
        emit GenesisSealed(tldNode, merkleRoot, reservedCount);
        _revokeRole(GENESIS_ROLE, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Launch allowlist (WP-144; DEFAULT_ADMIN_ROLE = timelock)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ITldRegistrarController
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
    // Pause (only `register`; SR-62)
    // ---------------------------------------------------------------------------------------------

    /// @notice Pause every register overload (all share `whenNotPaused`). `PAUSER_ROLE` (Admin Safe, no
    ///         delay) or the admin.
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
        return interfaceId == type(ITldRegistrarController).interfaceId || super.supportsInterface(interfaceId);
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

    /// @dev Upstream age checks verbatim, then delete (INV-9).
    function _consumeCommitment(bytes32 commitment) private {
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

    /// @dev ENS-legacy ordering, verbatim V1: mint to `this`, hand the node to the owner via
    ///      `setRecord`, write records (trusted writer), then transfer the token.
    function _registerWithResolver(Registration calldata registration, bytes32 labelhash)
        private
        returns (uint256 expires)
    {
        uint256 id = uint256(labelhash);
        expires = registrar.register(id, address(this), MAX_EXPIRY - block.timestamp);

        bytes32 node = keccak256(abi.encodePacked(tldNode, labelhash));
        ens.setRecord(node, registration.owner, registration.resolver, 0);

        if (registration.resolver == address(resolver)) resolver.tagNode(node, tldNode, id);

        registrar.transferFrom(address(this), registration.owner, id);

        Resolver(registration.resolver)
            .setAddr(node, ArcNSConstants.evmCoinType(), abi.encodePacked(registration.owner));
        if (registration.data.length > 0) {
            // slither-disable-next-line unused-return
            Resolver(registration.resolver).multicallWithNodeCheck(node, registration.data);
        }

        if (registration.reverseRecord) {
            // slither-disable-next-line unused-return
            reverseRegistrar.setNameForAddr(
                msg.sender, msg.sender, registration.resolver, string.concat(registration.label, ".", _tld)
            );
        }
    }

    /// @dev Fee split + settle. `integrator == address(0)` ⇒ byte-identical V1 `_settle` (100% to
    ///      treasury). Otherwise `integratorShare + treasuryShare == price` exactly by construction
    ///      (`treasuryShare` is the remainder, never independently computed) — no dust created or lost
    ///      for any `rateBps` in `[0, CAP_BPS]`. Overpayment is still credited to the PAYER's pull
    ///      ledger, never pushed (SR-11/31, Arc blocklist hazard) — unchanged from V1.
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
