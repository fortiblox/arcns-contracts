// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IIntegratorRegistry} from "./IIntegratorRegistry.sol";

/// @title IHandleControllerV3 — TESTNET-ONLY, single-transaction registration for the handle namespace
/// @notice A clean interface, NOT an extension of `IHandleController`/`IHandleControllerV2`: those
///         interfaces force `commit()`/`makeCommitment()`/`registerWithProof()`-shaped signatures that
///         `HandleControllerV3` deliberately does not implement (front-running protection is dropped on
///         this deployment — see `HandleControllerV3` NatSpec). Every event/error/view below is copied
///         from `IHandleController` verbatim except the commit-reveal-only surface
///         (`CommitmentMade`, `commitments`, `minCommitmentAge`, `maxCommitmentAge`,
///         `MIN_COMMITMENT_AGE_FLOOR`, `makeCommitment`, `commit`), which has no counterpart here.
interface IHandleControllerV3 {
    event NameRegistered(string name, uint256 indexed tokenId, address indexed owner, uint256 cost, uint8 handleType);
    event ReservedRegistered(uint256 indexed tokenId, string name);
    event GenesisSealed(bytes32 indexed namespaceId, bytes32 merkleRoot, uint256 reservedCount);
    event TreasuryFee(uint256 indexed tokenId, uint256 amount);
    event Credited(address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    /// @notice WP-144-style launch allowlist (re)configured. `root == 0` ⇒ no allowlist; otherwise
    ///         `registerDirect` reverts `AllowlistRequired` for everyone until `sunset` (exclusive) —
    ///         V3 has no proof-taking sibling, so there is no escape hatch while active (see
    ///         `HandleControllerV3` NatSpec).
    event AllowlistSet(bytes32 indexed root, uint64 sunset);

    error NameNotAvailable(string name);
    error NotCanonical(string name);
    error PriceChanged(uint256 quoted, uint256 maxPrice);
    error InsufficientValue(uint256 required, uint256 sent);
    error RegistrationsClosed();
    error GenesisAlreadySealed();
    error BatchLengthMismatch();
    error TreasuryPaymentFailed(address treasury, uint256 amount);
    error NothingToWithdraw();
    error WithdrawFailed(address to, uint256 amount);
    error ValueNotAccepted();
    /// @notice The allowlist window is open and `registerDirect` was called — there is no proof-taking
    ///         overload on V3, so this is unconditional and permanent until the allowlist is cleared.
    error AllowlistRequired();
    /// @notice Kept for ABI parity with `IHandleController.isAllowlisted`'s revert-free semantics; not
    ///         thrown by `registerDirect` itself (no proof parameter exists to fail), but by
    ///         `isAllowlisted` callers who choose to treat a `false` result as this condition.
    error NotAllowlisted(address owner);
    error AllowlistSunsetInvalid(uint64 sunset);

    function namespaceId() external view returns (bytes32); // HANDLE_ROOT
    function treasury() external view returns (address);
    function genesisSealed() external view returns (bool);
    function genesisRoot() external view returns (bytes32);
    function reservedCount() external view returns (uint256);
    function withdrawable(address who) external view returns (uint256);

    /// @notice The allow-list + rate resolver consulted for a non-zero integrator argument, mirroring
    ///         `IHandleControllerV2`. Retained because `_register`'s integrator-split branch is kept
    ///         verbatim from V2 even though `registerDirect` never passes a non-zero integrator today.
    function integratorRegistry() external view returns (IIntegratorRegistry);

    // ---- launch allowlist (admin = timelock)
    /// @notice Longest window a single `setAllowlist` may open (90 days); extend by calling again.
    function MAX_ALLOWLIST_WINDOW() external view returns (uint256);
    function allowlistRoot() external view returns (bytes32);
    function allowlistSunset() external view returns (uint64);
    /// @notice True while `allowlistRoot != 0 && block.timestamp < allowlistSunset`.
    function allowlistActive() external view returns (bool);
    /// @notice Proof check only — ignores whether the allowlist is active. No `registerDirect` overload
    ///         consumes a proof; this view exists for off-chain/UI use and ABI parity with V1/V2.
    function isAllowlisted(address owner, bytes32[] calldata proof) external view returns (bool);
    /// @notice DEFAULT_ADMIN_ROLE (timelock). `root = 0, sunset = 0` clears the allowlist.
    function setAllowlist(bytes32 root, uint64 sunset) external;

    function valid(string calldata name) external pure returns (bool);
    function available(string calldata name) external view returns (bool);
    function quote(string calldata name) external view returns (uint256 priceWei);

    /// @notice Single-transaction registration: no commit, no reveal, no front-running protection
    ///         (TESTNET-ONLY — see `HandleControllerV3` NatSpec). Reverts `AllowlistRequired` while the
    ///         allowlist window is open, with no proof-based escape hatch.
    function registerDirect(string calldata name, address owner, uint8 handleType, uint256 maxPrice)
        external
        payable;
    function withdraw() external;

    function registerReservedBatch(string[] calldata names, uint8[] calldata handleTypes) external;
    function sealGenesis(bytes32 merkleRoot) external;
}
