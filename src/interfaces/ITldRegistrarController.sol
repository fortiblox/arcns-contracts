// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ITldRegistrarController — C5, one instance per TLD (fork of ENS ETHRegistrarController v1.7.0)
/// @notice Commit-reveal (SR-10), permanent names (expiry = type(uint64).max, Q3), no renewals,
///         `maxPrice` guard (pricing.md §4), pull ledger for overpayment (SR-11/31), fee pushed to the
///         Treasury Safe, `registerReservedBatch` (GENESIS_ROLE, pre-seal, does NOT touch `totalSold`),
///         on-chain ASCII grammar (`HandleNormalize.isCanonical`), Arc coinType record set at
///         registration (WP-145), 7-arg `NameRegistered` kept verbatim for BENS (WP-145).
interface ITldRegistrarController {
    struct Registration {
        string label;
        address owner;
        bytes32 secret;
        address resolver; // 0 ⇒ no resolver record, no data, no reverse record
        bytes[] data; // resolver multicall payloads (must target `node`)
        bool reverseRecord; // set `addr.reverse` name for msg.sender
    }

    // ENS v1.7.0 event, verbatim signature (BENS `handleNameRegisteredByUnwrappedController`)
    event NameRegistered(
        string label,
        bytes32 indexed labelhash,
        address indexed owner,
        uint256 baseCost,
        uint256 premium,
        uint256 expires,
        bytes32 referrer
    );
    event CommitmentMade(bytes32 indexed commitment, uint256 timestamp);
    event ReservedRegistered(bytes32 indexed labelhash, string label);
    event GenesisSealed(bytes32 indexed tldNode, bytes32 merkleRoot, uint256 reservedCount);
    event TreasuryFee(bytes32 indexed labelhash, uint256 amount);
    event Credited(address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    /// @notice WP-144: launch allowlist (re)configured. `root == 0` ⇒ no allowlist; otherwise proofs
    ///         are required for every `owner` until `sunset` (exclusive).
    event AllowlistSet(bytes32 indexed root, uint64 sunset);

    error CommitmentNotFound(bytes32 commitment);
    error CommitmentTooNew(bytes32 commitment, uint256 minimumCommitmentTimestamp, uint256 currentTimestamp);
    error CommitmentTooOld(bytes32 commitment, uint256 maximumCommitmentTimestamp, uint256 currentTimestamp);
    error UnexpiredCommitmentExists(bytes32 commitment);
    error NameNotAvailable(string label);
    error NotCanonical(string label);
    error PriceChanged(uint256 quoted, uint256 maxPrice);
    error InsufficientValue(uint256 required, uint256 sent);
    error ResolverRequiredWhenDataSupplied();
    error ResolverRequiredForReverseRecord();
    error RegistrationsClosed(); // genesis not sealed yet, or directory status != Active, or paused
    error GenesisAlreadySealed();
    error TreasuryPaymentFailed(address treasury, uint256 amount);
    error NothingToWithdraw();
    error WithdrawFailed(address to, uint256 amount);
    error ValueNotAccepted();
    error MinCommitmentAgeBelowFloor(uint256 provided, uint256 floor);
    error MaxCommitmentAgeInvalid(uint256 provided);
    /// @notice WP-144: the allowlist window is open and `register` (no proof) was called — use `registerWithProof`.
    error AllowlistRequired();
    /// @notice WP-144: the proof does not place `owner` in the current allowlist root.
    error NotAllowlisted(address owner);
    /// @notice WP-144: `sunset` must be strictly in the future and at most `MAX_ALLOWLIST_WINDOW` ahead
    ///         when a root is set, and exactly 0 when the root is cleared.
    error AllowlistSunsetInvalid(uint64 sunset);

    function tld() external view returns (string memory);
    function tldNode() external view returns (bytes32);
    function namespaceId() external view returns (bytes32);
    function treasury() external view returns (address);
    function minCommitmentAge() external view returns (uint256);
    function maxCommitmentAge() external view returns (uint256);
    function MIN_COMMITMENT_AGE_FLOOR() external view returns (uint256); // 30 s (SR-10)
    function genesisSealed() external view returns (bool);
    function genesisRoot() external view returns (bytes32);
    function reservedCount() external view returns (uint256);
    function commitments(bytes32 commitment) external view returns (uint256);
    function withdrawable(address who) external view returns (uint256);
    function paidWei(bytes32 labelhash) external view returns (uint256);
    function labelOf(bytes32 labelhash) external view returns (string memory);

    // ---- launch allowlist (WP-144; admin = timelock, SR-62)
    /// @notice Longest window a single `setAllowlist` may open (90 days); extend by calling again.
    function MAX_ALLOWLIST_WINDOW() external view returns (uint256);
    function allowlistRoot() external view returns (bytes32);
    function allowlistSunset() external view returns (uint64);
    /// @notice True while `allowlistRoot != 0 && block.timestamp < allowlistSunset`.
    function allowlistActive() external view returns (bool);
    /// @notice Proof check only — ignores whether the allowlist is active.
    function isAllowlisted(address owner, bytes32[] calldata proof) external view returns (bool);
    /// @notice DEFAULT_ADMIN_ROLE (timelock). `root = 0, sunset = 0` clears the allowlist.
    function setAllowlist(bytes32 root, uint64 sunset) external;

    function valid(string calldata label) external pure returns (bool);
    function available(string calldata label) external view returns (bool);
    function quote(string calldata label) external view returns (uint256 priceWei);
    function makeCommitment(Registration calldata registration) external view returns (bytes32);
    function commit(bytes32 commitment) external;
    /// @notice Reverts `AllowlistRequired` while the allowlist window is open.
    function register(Registration calldata registration, uint256 maxPrice) external payable;
    /// @notice `register` plus a Merkle proof that `registration.owner` is on the launch allowlist;
    ///         `proof` is only checked while the allowlist is active.
    function registerWithProof(Registration calldata registration, uint256 maxPrice, bytes32[] calldata proof)
        external
        payable;
    function withdraw() external;

    // ---- genesis (GENESIS_ROLE; renounced inside sealGenesis)
    function registerReservedBatch(string[] calldata labels) external;
    function sealGenesis(bytes32 merkleRoot) external;
}
