// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Verbatim ens-contracts v1.7.0 ABIs (interfaces only; no OZ 4 contract enters this graph).
import {ENS} from "@ensdomains/ens-contracts/registry/ENS.sol";
import {IReverseRegistrar} from "@ensdomains/ens-contracts/reverseRegistrar/IReverseRegistrar.sol";
import {Resolver} from "@ensdomains/ens-contracts/resolvers/Resolver.sol";

import {IArcNSPriceOracle} from "../interfaces/IArcNSPriceOracle.sol";
import {IArcNSResolver} from "../interfaces/IArcNSResolver.sol";
import {IIntegratorRegistry} from "../interfaces/IIntegratorRegistry.sol";
import {ITldDirectory} from "../interfaces/ITldDirectory.sol";
import {ITldRegistrarController} from "../interfaces/ITldRegistrarController.sol";
import {ITldTokenPaymentController} from "../interfaces/ITldTokenPaymentController.sol";
import {IVeForti} from "../interfaces/IVeForti.sol";
import {ArcNSConstants} from "../lib/ArcNSConstants.sol";
import {HandleNormalize} from "../lib/HandleNormalize.sol";
import {TldRegistrar} from "./TldRegistrar.sol";

/// @title TldTokenPaymentController — sibling to `TldRegistrarControllerV2`, paid in an ERC20 token
///        instead of Arc's native gas token (issue #192, FORTI-Arc groundwork)
/// @notice Same commit-reveal registration shape as `TldRegistrarControllerV2`
///         (`ITldRegistrarController.Registration`, `makeCommitment`, `commit`, the ENS-legacy
///         resolver-wiring order), but `register`/`registerWithIntegrator` are plain (non-`payable`)
///         and pull `paymentToken` via `SafeERC20.safeTransferFrom` instead of `msg.value`, priced
///         through `IArcNSPriceOracle.quoteInToken` instead of `quote`. On top of the existing
///         integrator revenue-share split (`IIntegratorRegistry`, identical mechanics to
///         `TldRegistrarControllerV2`), this controller adds:
///           - a two-tier FORTI discount matching the ratified ArcNS utility row (Arc Token
///             Constitution v1.0 §6: "~10% base discount + deeper veFORTI-locker bonus (flash-proof)"):
///             `BASE_DISCOUNT_BPS` (10%, an immutable constant — every FORTI-paid registration gets
///             it, unconditionally, simply for paying in FORTI) plus an optional `veFortiBonusBps`
///             (owner-settable, default 0, hard-capped so `BASE_DISCOUNT_BPS + veFortiBonusBps` can
///             never exceed `MAX_DISCOUNT_BPS`) for any caller with non-zero `IVeForti` voting power
///             (`veForti` defaults to `address(0)`, i.e. the bonus tier is disabled until an admin
///             points it at a real deployment). Gating the bonus on veFORTI *voting power* rather than
///             a spot FORTI balance is what makes it flash-loan-proof — a lock takes time, a balance
///             does not — mirroring the constitution's §7 rule for swap fee tiers.
///           - an optional buyback cut (`buybackShareBps`, default 0) skimmed off the top of every
///             sale, credited to `buybackRecipient` through the same pull ledger as everything else.
///
/// @dev Deployment model (WP #192 acceptance: "additive authorization, do not touch the existing
///      controller"): this contract is authorized as a SECOND controller on the SAME `TldRegistrar`
///      the live `TldRegistrarControllerV2` already uses (`TldRegistrar.addController`), for a TLD
///      whose genesis already ran on that native controller. It deliberately carries no
///      genesis/reserved-batch surface and no launch allowlist — both are already-settled, one-time
///      concerns owned by the native controller for any TLD this sits alongside.
///
///      Naming note: the constitution calls this integration a "FORTI Names Gateway beside the
///      *renounced* ArcNS registry." As of this change the base registrar/registry is NOT renounced —
///      `TldRegistrar` (`BaseRegistrarImplementation`) is a live `Ownable` contract whose owner is the
///      timelock (see `TldStackFixture`/deploy scripts: `reg.transferOwnership(admin)`, never
///      `renounceOwnership`), which is exactly what makes the additive `addController` sibling model
///      here possible. "Renounced" appears to describe a possible later end-state, not the current
///      code; this contract is named/shaped as a `Controller` (this repo's existing pattern) rather
///      than a "Gateway" and can be revisited if the registry is ever actually renounced.
///
///      Cross-product tier unification (constitution §6: "a primary handle name plus veFORTI unlocks the
///      deepest tier across swaps + names") is explicitly OUT OF SCOPE here — this controller reads
///      only `IVeForti`, never a handle/primary-name signal, and the Arc router does not read ArcNS
///      state today. TODO(future, cross-repo): once both sides exist, a unified "deepest tier" read
///      needs a shared design between `fortiblox-arc-token`'s router and this controller.
///
///      Oracle wiring is READ-ONLY: `quoteInToken` is a view, and `oracle.recordSale` is NEVER called
///      here. `ArcNSPriceOracle.recordSale` is gated to the single `namespaceInfo(namespaceId).controller`
///      address (set once via `initNamespace`/`setController`, unchanged by this file) — this
///      controller does not attempt to become that address, so the native controller's oracle wiring
///      is completely unmodified. The practical consequence: FORTI-paid registrations do not advance
///      the time/volume ramp; only native-paid ones do. Widening `recordSale` to accept more than one
///      controller per namespace is a separate, scoped change to `ArcNSPriceOracle`, not done here.
///
///      Pull-ledger discipline (SR-11/31 lineage): `withdrawable[...]` is used for the integrator
///      share and the buyback share — exactly the two recipients that are not the fixed, admin-set
///      `treasury` — mirroring `_settle()`'s own choice to push only to `treasury` and pull everything
///      else. Since payment is `SafeERC20.safeTransferFrom` for the EXACT quoted (post-discount) price
///      rather than an arbitrary `msg.value`, there is no overpayment case to credit here.
contract TldTokenPaymentController is AccessControl, Pausable, ReentrancyGuardTransient, ITldTokenPaymentController {
    using SafeERC20 for IERC20;

    /// @notice Constructor arguments (struct so the deploy script and tests share one shape).
    struct Init {
        address admin;
        address pauser;
        address registrar;
        address ens;
        address oracle;
        address resolver;
        address reverseRegistrar;
        address directory;
        address treasury;
        address integratorRegistry;
        address paymentToken;
        uint256 minCommitmentAge;
        uint256 maxCommitmentAge;
        string tld;
    }

    /// @notice May pause `register`/`registerWithIntegrator` (only those) without a timelock delay (SR-62 lineage).
    bytes32 public constant PAUSER_ROLE = ArcNSConstants.PAUSER_ROLE;
    uint256 public constant MIN_COMMITMENT_AGE_FLOOR = 30 seconds;
    uint256 private constant MAX_COMMITMENT_AGE_CAP = 24 hours;
    /// @dev Q3 permanence, same as `TldRegistrarControllerV2`: every name expires at `type(uint64).max`.
    uint256 private constant MAX_EXPIRY = type(uint64).max;
    uint256 private constant BPS_DENOM = 10_000;
    /// @notice Immutable floor of the FORTI discount (Arc Token Constitution v1.0 §6: "~10% base
    ///         discount"). Applied to EVERY FORTI-paid registration, unconditionally — not
    ///         owner-settable, not skippable, not part of `veFortiBonusBps`'s cap arithmetic input.
    uint16 public constant BASE_DISCOUNT_BPS = 1000;
    /// @notice Immutable ceiling on the TOTAL discount (`BASE_DISCOUNT_BPS + veFortiBonusBps`) —
    ///         a discount can never exceed 50 % of price no matter how governance sets the bonus.
    uint16 public constant MAX_DISCOUNT_BPS = 5000;
    /// @notice Upper bound on `buybackShareBps` — the buyback cut can never exceed 50 % of price.
    uint16 public constant MAX_BUYBACK_BPS = 5000;

    TldRegistrar public immutable registrar;
    ENS public immutable ens;
    IArcNSPriceOracle public immutable oracle;
    IArcNSResolver public immutable resolver;
    IReverseRegistrar public immutable reverseRegistrar;
    ITldDirectory public immutable directory;
    /// @inheritdoc ITldTokenPaymentController
    address public immutable treasury;
    /// @inheritdoc ITldTokenPaymentController
    IIntegratorRegistry public immutable integratorRegistry;
    /// @dev Immutable: the ERC20 this controller ever pulls. `paymentToken()` (the interface view)
    ///      returns `address(_paymentToken)`.
    IERC20 private immutable _paymentToken;
    bytes32 public immutable tldNode;
    bytes32 public immutable namespaceId;
    /// @inheritdoc ITldTokenPaymentController
    uint256 public immutable minCommitmentAge;
    /// @inheritdoc ITldTokenPaymentController
    uint256 public immutable maxCommitmentAge;

    string private _tld;

    /// @dev `veForti()` (the interface view) returns `address(_veForti)`.
    IVeForti private _veForti;
    /// @inheritdoc ITldTokenPaymentController
    uint16 public veFortiBonusBps;
    /// @inheritdoc ITldTokenPaymentController
    address public buybackRecipient;
    /// @inheritdoc ITldTokenPaymentController
    uint16 public buybackShareBps;

    /// @inheritdoc ITldTokenPaymentController
    mapping(bytes32 commitment => uint256 timestamp) public commitments;
    /// @inheritdoc ITldTokenPaymentController
    mapping(address who => uint256 amount) public withdrawable;
    /// @inheritdoc ITldTokenPaymentController
    mapping(bytes32 labelhash => uint256 amount) public paidAmount;
    mapping(bytes32 labelhash => string label) public labels;

    constructor(Init memory init) {
        if (init.minCommitmentAge < MIN_COMMITMENT_AGE_FLOOR) {
            revert MinCommitmentAgeBelowFloor(init.minCommitmentAge, MIN_COMMITMENT_AGE_FLOOR);
        }
        if (init.maxCommitmentAge <= init.minCommitmentAge || init.maxCommitmentAge > MAX_COMMITMENT_AGE_CAP) {
            revert MaxCommitmentAgeInvalid(init.maxCommitmentAge);
        }
        if (
            init.admin == address(0) || init.pauser == address(0) || init.registrar == address(0)
                || init.ens == address(0) || init.oracle == address(0) || init.resolver == address(0)
                || init.reverseRegistrar == address(0) || init.directory == address(0) || init.treasury == address(0)
                || init.integratorRegistry == address(0) || init.paymentToken == address(0)
        ) revert ZeroAddress();
        if (!HandleNormalize.isCanonical(init.tld)) revert NotCanonical(init.tld);

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(PAUSER_ROLE, init.pauser);

        registrar = TldRegistrar(init.registrar);
        ens = ENS(init.ens);
        oracle = IArcNSPriceOracle(init.oracle);
        resolver = IArcNSResolver(init.resolver);
        reverseRegistrar = IReverseRegistrar(init.reverseRegistrar);
        directory = ITldDirectory(init.directory);
        treasury = init.treasury;
        integratorRegistry = IIntegratorRegistry(init.integratorRegistry);
        _paymentToken = IERC20(init.paymentToken);
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

    /// @inheritdoc ITldTokenPaymentController
    function tld() external view returns (string memory) {
        return _tld;
    }

    /// @inheritdoc ITldTokenPaymentController
    function paymentToken() external view returns (address) {
        return address(_paymentToken);
    }

    /// @inheritdoc ITldTokenPaymentController
    function labelOf(bytes32 labelhash) external view returns (string memory) {
        return labels[labelhash];
    }

    /// @inheritdoc ITldTokenPaymentController
    function veForti() external view returns (address) {
        return address(_veForti);
    }

    /// @inheritdoc ITldTokenPaymentController
    function valid(string calldata label) public pure returns (bool) {
        return HandleNormalize.isCanonical(label);
    }

    /// @inheritdoc ITldTokenPaymentController
    function available(string calldata label) public view returns (bool) {
        return valid(label) && registrar.available(uint256(keccak256(bytes(label))));
    }

    /// @inheritdoc ITldTokenPaymentController
    function quote(string calldata label) public view returns (uint256 price, bool supported) {
        (price, supported) = oracle.quoteInToken(namespaceId, label, address(_paymentToken));
    }

    /// @inheritdoc ITldTokenPaymentController
    function quoteFor(string calldata label, address who) external view returns (uint256 price, bool supported) {
        (uint256 base, bool ok) = quote(label);
        if (!ok) return (0, false);
        return (_applyDiscount(base, who), true);
    }

    /// @inheritdoc ITldTokenPaymentController
    /// @dev The integrator is deliberately NOT part of the commitment, same rationale as
    ///      `TldRegistrarControllerV2.makeCommitment`: it only routes the payment split.
    function makeCommitment(ITldRegistrarController.Registration calldata registration) public view returns (bytes32) {
        if (registration.data.length > 0 && registration.resolver == address(0)) {
            revert ResolverRequiredWhenDataSupplied();
        }
        if (registration.reverseRecord && registration.resolver == address(0)) {
            revert ResolverRequiredForReverseRecord();
        }
        ITldRegistrarController.Registration memory r = registration;
        return keccak256(
            abi.encode(
                _tld, r.label, r.owner, r.secret, block.chainid, address(this), r.resolver, r.data, r.reverseRecord
            )
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Commit / reveal
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ITldTokenPaymentController
    function commit(bytes32 commitment) external {
        if (commitments[commitment] + maxCommitmentAge >= block.timestamp) {
            revert UnexpiredCommitmentExists(commitment);
        }
        commitments[commitment] = block.timestamp;
        emit CommitmentMade(commitment, block.timestamp);
    }

    /// @inheritdoc ITldTokenPaymentController
    function register(ITldRegistrarController.Registration calldata registration, uint256 maxPrice)
        external
        nonReentrant
        whenNotPaused
    {
        _register(registration, maxPrice, address(0));
    }

    /// @inheritdoc ITldTokenPaymentController
    function registerWithIntegrator(
        ITldRegistrarController.Registration calldata registration,
        uint256 maxPrice,
        address integrator
    ) external nonReentrant whenNotPaused {
        if (integrator == address(0)) revert IntegratorRequired();
        _register(registration, maxPrice, integrator);
    }

    /// @dev Shared by both register entry points. `integrator == address(0)` skips the split entirely
    ///      (100 % of the post-discount, post-buyback remainder to `treasury`). Otherwise `rateOf` is
    ///      resolved and validated FIRST — fail-closed, no partial mutation on a bad integrator, same
    ///      ordering guarantee as `TldRegistrarControllerV2._register`.
    function _register(ITldRegistrarController.Registration calldata registration, uint256 maxPrice, address integrator)
        private
    {
        if (!directory.registrationsOpen(tldNode)) revert RegistrationsClosed();
        if (!HandleNormalize.isCanonical(registration.label)) revert NotCanonical(registration.label);

        bytes32 labelhash = keccak256(bytes(registration.label));
        if (!registrar.available(uint256(labelhash))) revert NameNotAvailable(registration.label);

        uint16 rateBps = integrator == address(0) ? 0 : integratorRegistry.rateOf(integrator);

        _consumeCommitment(makeCommitment(registration));

        (uint256 basePrice, bool supported) =
            oracle.quoteInToken(namespaceId, registration.label, address(_paymentToken));
        if (!supported) revert PaymentTokenNotSupported(address(_paymentToken));
        uint256 price = _applyDiscount(basePrice, msg.sender);
        if (price > maxPrice) revert PriceChanged(price, maxPrice);

        uint256 expires = registration.resolver == address(0)
            ? registrar.register(uint256(labelhash), registration.owner, MAX_EXPIRY - block.timestamp)
            : _registerWithResolver(registration, labelhash);

        paidAmount[labelhash] = price;
        labels[labelhash] = registration.label;
        registrar.emitMetadataUpdate(uint256(labelhash));
        // oracle.recordSale is intentionally NOT called — see contract-level NatSpec: recordSale is
        // gated to the single native-controller address the oracle already trusts per namespace, and
        // this controller never attempts to become that address.

        if (price > 0) _paymentToken.safeTransferFrom(msg.sender, address(this), price);

        _settleToken(labelhash, price, integrator, rateBps);

        bytes32 referrer = integrator == address(0) ? bytes32(0) : bytes32(uint256(uint160(integrator)));
        emit NameRegistered(registration.label, labelhash, registration.owner, price, 0, expires, referrer);
    }

    /// @inheritdoc ITldTokenPaymentController
    function withdraw() external nonReentrant {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0;
        _paymentToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Governance (DEFAULT_ADMIN_ROLE = timelock)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ITldTokenPaymentController
    /// @dev `address(0)` disables the veFORTI bonus tier unconditionally, regardless of
    ///      `veFortiBonusBps` — `BASE_DISCOUNT_BPS` still applies to every FORTI-paid registration.
    function setVeForti(address veForti_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _veForti = IVeForti(veForti_);
        emit VeFortiSet(veForti_);
    }

    /// @inheritdoc ITldTokenPaymentController
    /// @dev Capped so the TOTAL discount (`BASE_DISCOUNT_BPS + bps`) can never exceed
    ///      `MAX_DISCOUNT_BPS` — a governance param bounded by an immutable ceiling, matching the
    ///      constitution's "GOVERNANCE-adjustable within bounds" fee-tier rule (§7), not an
    ///      unbounded owner-settable rate. Compares against the bonus-only cap (not a
    ///      `BASE_DISCOUNT_BPS + bps` sum) so no `uint16` input can ever overflow the check.
    function setVeFortiBonusBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint16 maxBonus = MAX_DISCOUNT_BPS - BASE_DISCOUNT_BPS;
        if (bps > maxBonus) revert DiscountAboveCap(bps, maxBonus);
        veFortiBonusBps = bps;
        emit VeFortiBonusSet(bps);
    }

    /// @inheritdoc ITldTokenPaymentController
    /// @dev `shareBps == 0` clears `buybackRecipient` back to `address(0)` too, so the controller never
    ///      sits with a stale recipient and a zero share (or vice versa).
    function setBuyback(address recipient, uint16 shareBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (shareBps > MAX_BUYBACK_BPS) revert BuybackAboveCap(shareBps, MAX_BUYBACK_BPS);
        if (shareBps > 0 && recipient == address(0)) revert BuybackRecipientRequired();
        buybackRecipient = shareBps == 0 ? address(0) : recipient;
        buybackShareBps = shareBps;
        emit BuybackSet(buybackRecipient, shareBps);
    }

    // ---------------------------------------------------------------------------------------------
    // Pause (only register*; SR-62 lineage)
    // ---------------------------------------------------------------------------------------------

    function pause() external {
        if (!hasRole(PAUSER_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, PAUSER_ROLE);
        }
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Upstream age checks verbatim (mirrors `TldRegistrarControllerV2._consumeCommitment`).
    function _consumeCommitment(bytes32 commitment) private {
        uint256 commitmentTimestamp = commitments[commitment];
        if (commitmentTimestamp + minCommitmentAge > block.timestamp) {
            revert CommitmentTooNew(commitment, commitmentTimestamp + minCommitmentAge, block.timestamp);
        }
        if (commitmentTimestamp + maxCommitmentAge <= block.timestamp) {
            // slither-disable-next-line incorrect-equality
            if (commitmentTimestamp == 0) revert CommitmentNotFound(commitment);
            revert CommitmentTooOld(commitment, commitmentTimestamp + maxCommitmentAge, block.timestamp);
        }
        delete commitments[commitment];
    }

    /// @dev ENS-legacy ordering, identical to `TldRegistrarControllerV2._registerWithResolver`: mint to
    ///      `this`, hand the node to the owner via `setRecord`, write records, then transfer the token.
    function _registerWithResolver(ITldRegistrarController.Registration calldata registration, bytes32 labelhash)
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

    /// @dev Two-tier discount (Arc Token Constitution v1.0 §6): `BASE_DISCOUNT_BPS` applies
    ///      unconditionally to every FORTI-paid registration — simply paying in FORTI earns it, no
    ///      veFORTI required — plus `veFortiBonusBps` on top for any `payer` who also holds non-zero
    ///      `veForti` voting power (a no-op while `veForti == address(0)` or `veFortiBonusBps == 0`,
    ///      the defaults). Gating the bonus on voting power rather than a spot balance is what makes
    ///      it flash-loan-proof: a lock takes time to acquire, a balance does not.
    function _applyDiscount(uint256 price, address payer) private view returns (uint256) {
        uint256 bps = BASE_DISCOUNT_BPS;
        if (address(_veForti) != address(0) && veFortiBonusBps > 0 && _veForti.votingPowerOf(payer) > 0) {
            bps += veFortiBonusBps;
        }
        return price - (price * bps / BPS_DENOM);
    }

    /// @dev Fee split + settle, mirroring `TldRegistrarControllerV2._settle`'s exact split discipline:
    ///      `treasury` is pushed directly (a fixed, admin-set address — ERC20 `safeTransfer` carries
    ///      none of the raw-ETH-push blocklist hazard `_settle` avoids for arbitrary recipients, so a
    ///      direct push here is safe); the integrator share and the buyback share — the two arbitrary,
    ///      admin-or-governance-supplied recipients — are credited to the pull ledger (`withdrawable`)
    ///      exactly like `_settle` already does for the integrator. `buybackShare + integratorShare +
    ///      treasuryShare == price` exactly by construction (`treasuryShare` is always the final
    ///      remainder, never independently computed) — no dust created or lost for any
    ///      `buybackShareBps`/`rateBps` in their configured ranges.
    function _settleToken(bytes32 labelhash, uint256 price, address integrator, uint16 rateBps) private {
        uint256 buybackShare = buybackShareBps == 0 ? 0 : price * buybackShareBps / BPS_DENOM;
        if (buybackShare > 0) {
            withdrawable[buybackRecipient] += buybackShare;
            emit BuybackCredited(labelhash, buybackRecipient, buybackShare);
        }
        uint256 remaining = price - buybackShare;

        if (integrator == address(0)) {
            if (remaining > 0) {
                _paymentToken.safeTransfer(treasury, remaining);
                emit TreasuryFee(labelhash, remaining);
            }
        } else {
            uint256 integratorShare = integratorRegistry.computeSplit(integrator, remaining);
            uint256 treasuryShare = remaining - integratorShare;
            if (integratorShare > 0) {
                withdrawable[integrator] += integratorShare;
                emit Credited(integrator, integratorShare);
            }
            emit IIntegratorRegistry.FeeSplit(integrator, remaining, integratorShare, rateBps);
            if (treasuryShare > 0) {
                _paymentToken.safeTransfer(treasury, treasuryShare);
                emit TreasuryFee(labelhash, treasuryShare);
            }
        }
    }
}
