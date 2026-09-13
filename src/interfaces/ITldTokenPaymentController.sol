// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IIntegratorRegistry} from "./IIntegratorRegistry.sol";
import {ITldRegistrarController} from "./ITldRegistrarController.sol";

/// @title ITldTokenPaymentController — sibling to `ITldRegistrarController`, paid in an ERC20
///        payment token (FORTI-Arc groundwork, issue #192) instead of Arc's native gas token.
/// @notice Deployed ADDITIVELY next to an already-live, already-genesis-sealed
///         `TldRegistrarControllerV2` for the same TLD: authorized as a SECOND controller on the
///         shared `TldRegistrar` (`TldRegistrar.addController`), never replacing or touching the
///         native controller's own authorization or behaviour. Reuses
///         `ITldRegistrarController.Registration` verbatim so the commit/reveal shape is unchanged.
///
///         Deliberately narrower than `TldRegistrarControllerV2`: no genesis/reserved-batch surface
///         (genesis already ran, once, on the native controller for any TLD this sits alongside) and
///         no launch allowlist (FORTI-Arc does not exist at any TLD's launch, so there is nothing to
///         gate). Adding either later is a separate, scoped change.
interface ITldTokenPaymentController {
    error ZeroAddress();
    error NotCanonical(string label);
    error NameNotAvailable(string label);
    error RegistrationsClosed();
    error ResolverRequiredWhenDataSupplied();
    error ResolverRequiredForReverseRecord();
    error CommitmentNotFound(bytes32 commitment);
    error CommitmentTooNew(bytes32 commitment, uint256 minimumCommitmentTimestamp, uint256 currentTimestamp);
    error CommitmentTooOld(bytes32 commitment, uint256 maximumCommitmentTimestamp, uint256 currentTimestamp);
    error UnexpiredCommitmentExists(bytes32 commitment);
    error PriceChanged(uint256 quoted, uint256 maxPrice);
    /// @notice The oracle has no fixed rate configured for this controller's `paymentToken`.
    error PaymentTokenNotSupported(address paymentToken);
    /// @notice Thrown by `registerWithIntegrator` for `integrator == address(0)`.
    error IntegratorRequired();
    error NothingToWithdraw();
    error MinCommitmentAgeBelowFloor(uint256 provided, uint256 floor);
    error MaxCommitmentAgeInvalid(uint256 provided);
    /// @notice `setVeFortiBonusBps(bps)` where `bps` exceeds `MAX_DISCOUNT_BPS - BASE_DISCOUNT_BPS`.
    error DiscountAboveCap(uint16 bps, uint16 cap);
    error BuybackAboveCap(uint16 bps, uint16 cap);
    /// @notice `setBuyback(address(0), bps)` with `bps > 0` — a non-zero share needs a recipient.
    error BuybackRecipientRequired();

    event CommitmentMade(bytes32 indexed commitment, uint256 timestamp);
    // Verbatim ENS-style shape (same 7-arg signature `ITldRegistrarController.NameRegistered` uses) so
    // indexers built against the native controller can reuse the same decode path.
    event NameRegistered(
        string label,
        bytes32 indexed labelhash,
        address indexed owner,
        uint256 baseCost,
        uint256 premium,
        uint256 expires,
        bytes32 referrer
    );
    event TreasuryFee(bytes32 indexed labelhash, uint256 amount);
    event Credited(address indexed to, uint256 amount);
    /// @notice `buybackShareBps` of `price` credited (pull ledger) to the buyback recipient.
    event BuybackCredited(bytes32 indexed labelhash, address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event VeFortiSet(address indexed veForti);
    event VeFortiBonusSet(uint16 bps);
    event BuybackSet(address indexed recipient, uint16 bps);

    function tld() external view returns (string memory);
    function tldNode() external view returns (bytes32);
    function namespaceId() external view returns (bytes32);
    function treasury() external view returns (address);
    function paymentToken() external view returns (address);
    function integratorRegistry() external view returns (IIntegratorRegistry);
    /// @notice `address(0)` disables the veFORTI bonus discount tier entirely (the default);
    ///         `BASE_DISCOUNT_BPS` still applies regardless.
    function veForti() external view returns (address);
    /// @notice Immutable floor of the discount (Arc Token Constitution v1.0 §6: "~10% base
    ///         discount") — applied to every FORTI-paid registration, never owner-settable.
    function BASE_DISCOUNT_BPS() external view returns (uint16);
    /// @notice Additional bps on top of `BASE_DISCOUNT_BPS` when `msg.sender` has non-zero `veForti`
    ///         voting power — owner-settable, capped so the total can never exceed `MAX_DISCOUNT_BPS`.
    function veFortiBonusBps() external view returns (uint16);
    /// @notice Immutable ceiling on `BASE_DISCOUNT_BPS + veFortiBonusBps`.
    function MAX_DISCOUNT_BPS() external view returns (uint16);
    /// @notice Pull-ledger destination for the buyback cut; `address(0)` while `buybackShareBps == 0`.
    function buybackRecipient() external view returns (address);
    /// @notice bps of the (post-discount) price routed to `buybackRecipient` before the integrator/treasury split.
    function buybackShareBps() external view returns (uint16);
    function minCommitmentAge() external view returns (uint256);
    function maxCommitmentAge() external view returns (uint256);
    function commitments(bytes32 commitment) external view returns (uint256);
    /// @notice Pull ledger — integrator shares, buyback shares, all drained only by `withdraw()`.
    function withdrawable(address who) external view returns (uint256);
    /// @notice Amount actually paid for `labelhash`, in `paymentToken` base units.
    function paidAmount(bytes32 labelhash) external view returns (uint256);
    function labelOf(bytes32 labelhash) external view returns (string memory);

    function valid(string calldata label) external pure returns (bool);
    function available(string calldata label) external view returns (bool);
    /// @notice `oracle.quoteInToken(namespaceId, label, paymentToken)` — before the `BASE_DISCOUNT_BPS`
    ///         floor or any veFORTI bonus.
    function quote(string calldata label) external view returns (uint256 price, bool supported);
    /// @notice `quote(label)` with `who`'s full two-tier discount applied (`BASE_DISCOUNT_BPS` always,
    ///         plus `veFortiBonusBps` if `who` holds non-zero `veForti` voting power) — i.e. exactly
    ///         what `register`/`registerWithIntegrator` would charge `who` right now.
    function quoteFor(string calldata label, address who) external view returns (uint256 price, bool supported);
    function makeCommitment(ITldRegistrarController.Registration calldata registration) external view returns (bytes32);
    function commit(bytes32 commitment) external;
    function register(ITldRegistrarController.Registration calldata registration, uint256 maxPrice) external;
    function registerWithIntegrator(
        ITldRegistrarController.Registration calldata registration,
        uint256 maxPrice,
        address integrator
    ) external;
    function withdraw() external;

    // ---- governance (DEFAULT_ADMIN_ROLE = timelock)
    function setVeForti(address veForti_) external;
    function setVeFortiBonusBps(uint16 bps) external;
    function setBuyback(address recipient, uint16 shareBps) external;
}
