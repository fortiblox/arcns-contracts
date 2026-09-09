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
import {ITldDirectory} from "../interfaces/ITldDirectory.sol";
import {ITldRegistrarController} from "../interfaces/ITldRegistrarController.sol";
import {ArcNSConstants} from "../lib/ArcNSConstants.sol";
import {HandleNormalize} from "../lib/HandleNormalize.sol";
import {LaunchAllowlist} from "../lib/LaunchAllowlist.sol";
import {TldRegistrar} from "./TldRegistrar.sol";

/// @title TldRegistrarController — C5, one instance per TLD; fork of ENS `ETHRegistrarController` v1.7.0
/// @notice Kept from upstream: the `makeCommitment` / `commit` / `register` flow with the same
///         `>=` / `<=` age comparisons, resolver-data `multicallWithNodeCheck`, the reverse-record
///         option and the verbatim 7-arg `NameRegistered` event (BENS, WP-145). Removed: `renew`,
///         duration pricing, `MIN_REGISTRATION_DURATION`, `ERC20Recoverable`, `Ownable`,
///         withdraw-to-owner. Added: the arcns ASCII grammar (`HandleNormalize.isCanonical`, SR-02),
///         the X1 price oracle with a `maxPrice` guard (pricing.md §4), permanent names
///         (`expires == type(uint64).max`, Q3), pull ledger for overpayment (SR-11/31), fee pushed
///         to the Treasury Safe, reserved genesis (`GENESIS_ROLE`, renounced in `sealGenesis`,
///         SR-16), the Arc coin-type record set at registration (WP-145), the human label stored for
///         metadata (WP-143), the resolver node tag (onchain-design §3.5) and the optional launch
///         allowlist (WP-144, `docs/architecture/launch-allowlist.md`: while `allowlistActive()` only
///         `registerWithProof` with a Merkle proof for `registration.owner` mints; set by the
///         timelock, closes by itself at `allowlistSunset`).
///
///         Two instances (`.arc`, `.circle`) are byte-identical bytecode with different `Init`.
contract TldRegistrarController is AccessControl, Pausable, ReentrancyGuardTransient, ITldRegistrarController {
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
                || init.treasury == address(0)
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
    /// @dev SR-02: the same ASCII grammar as handles (1–32 bytes, `a-z0-9-`, no edge/double hyphen,
    ///      not all digits), not ENS's `strlen >= 3`. 1- and 2-char labels are reserved by the
    ///      genesis list, not by the grammar.
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
    /// @dev `<` against `allowlistSunset`: the sunset second itself is open.
    function allowlistActive() public view returns (bool) {
        return allowlistRoot != bytes32(0) && block.timestamp < allowlistSunset;
    }

    /// @inheritdoc ITldRegistrarController
    function isAllowlisted(address owner, bytes32[] calldata proof) public view returns (bool) {
        return LaunchAllowlist.isAllowed(allowlistRoot, proof, owner);
    }

    /// @inheritdoc ITldRegistrarController
    /// @dev SR-10 shape (`tag, label, owner, secret, chainid, this`) plus the registration payload, so
    ///      a reveal with any field changed does not match. Upstream checks are kept verbatim.
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
    /// @dev The allowlist gate (WP-144) is evaluated before the genesis/directory gate so a
    ///      launch-window client sees `AllowlistRequired` first.
    function register(Registration calldata registration, uint256 maxPrice)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (allowlistActive()) revert AllowlistRequired();
        _register(registration, maxPrice);
    }

    /// @inheritdoc ITldRegistrarController
    /// @dev The proof is verified for `registration.owner` (never `msg.sender`, see `LaunchAllowlist`)
    ///      and only while the window is open; outside it this is byte-for-byte `register`.
    function registerWithProof(Registration calldata registration, uint256 maxPrice, bytes32[] calldata proof)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (allowlistActive() && !isAllowlisted(registration.owner, proof)) {
            revert NotAllowlisted(registration.owner);
        }
        _register(registration, maxPrice);
    }

    /// @dev Shared by `register` and `registerWithProof`; the caller has already cleared the allowlist gate.
    function _register(Registration calldata registration, uint256 maxPrice) private {
        if (!genesisSealed || !directory.registrationsOpen(tldNode)) revert RegistrationsClosed();
        if (!HandleNormalize.isCanonical(registration.label)) revert NotCanonical(registration.label);

        bytes32 labelhash = keccak256(bytes(registration.label));
        if (!registrar.available(uint256(labelhash))) revert NameNotAvailable(registration.label);

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

        _settle(labelhash, price);

        emit NameRegistered(registration.label, labelhash, registration.owner, price, 0, expires, bytes32(0));
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
    /// @dev Idempotent: labels already taken are skipped, so a partial batch re-runs safely. Every
    ///      reserved name is a real registration to the Treasury Safe (ENS owner = treasury, no
    ///      resolver). MUST NOT touch `oracle.totalSold` (pricing.md §4/§8).
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
    /// @dev The sealed check precedes the role check so a second call reports `GenesisAlreadySealed`
    ///      (the role no longer exists after the first).
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
    /// @dev A non-zero root needs `now < sunset <= now + MAX_ALLOWLIST_WINDOW`; clearing needs
    ///      `sunset == 0`. Re-setting overwrites both fields atomically; every change goes through the
    ///      timelock delay (SR-61). Per instance: `.arc` and `.circle` can run different windows.
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

    /// @notice Pause `register`. `PAUSER_ROLE` (Admin Safe, no delay) or the admin.
    function pause() external {
        if (!hasRole(PAUSER_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, PAUSER_ROLE);
        }
        _pause();
    }

    /// @notice Unpause `register`; admin (timelock) only.
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

    /// @dev Upstream age checks verbatim (`>` for too new, `<=` for too old), then delete (INV-9).
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

    /// @dev ENS-legacy ordering: the registrar mints to `this` and makes `this` the ENS subnode owner,
    ///      `setRecord` hands the node to the owner and points it at the resolver, records are written
    ///      (our controller is a trusted writer on the resolver), then the token is transferred.
    function _registerWithResolver(Registration calldata registration, bytes32 labelhash)
        private
        returns (uint256 expires)
    {
        uint256 id = uint256(labelhash);
        expires = registrar.register(id, address(this), MAX_EXPIRY - block.timestamp);

        bytes32 node = keccak256(abi.encodePacked(tldNode, labelhash));
        ens.setRecord(node, registration.owner, registration.resolver, 0);

        // The tag tells C7 which TLD (and token) a node belongs to; foreign resolvers are not tagged.
        if (registration.resolver == address(resolver)) resolver.tagNode(node, tldNode, id);

        // Hand the token to its owner BEFORE writing records: C7 keys records by the registrar's current
        // `ownerOf` (SR-12), so anything written while this controller still holds the token would vanish
        // on the transfer. The controller stays authorised on C7 as a trusted TLD controller.
        registrar.transferFrom(address(this), registration.owner, id);

        // WP-145: the Arc coin-type record first, so the user's own data may override it.
        Resolver(registration.resolver)
            .setAddr(node, ArcNSConstants.evmCoinType(), abi.encodePacked(registration.owner));
        if (registration.data.length > 0) {
            // the per-call return payloads carry no information for the controller (ENS v1.7.0 discards them too)
            // slither-disable-next-line unused-return
            Resolver(registration.resolver).multicallWithNodeCheck(node, registration.data);
        }

        if (registration.reverseRecord) {
            // returns the reverse node, which is derivable from msg.sender (ENS v1.7.0 discards it too)
            // slither-disable-next-line unused-return
            reverseRegistrar.setNameForAddr(
                msg.sender, msg.sender, registration.resolver, string.concat(registration.label, ".", _tld)
            );
        }
    }

    /// @dev Fee pushed to the Treasury Safe (ours: a revert must surface); overpayment credited to the
    ///      payer's pull ledger, never pushed (SR-11/31, Arc blocklist hazard).
    function _settle(bytes32 labelhash, uint256 price) private {
        if (price > 0) {
            (bool ok,) = payable(treasury).call{value: price}("");
            if (!ok) revert TreasuryPaymentFailed(treasury, price);
            emit TreasuryFee(labelhash, price);
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
