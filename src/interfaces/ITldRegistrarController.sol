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

    function valid(string calldata label) external pure returns (bool);
    function available(string calldata label) external view returns (bool);
    function quote(string calldata label) external view returns (uint256 priceWei);
    function makeCommitment(Registration calldata registration) external view returns (bytes32);
    function commit(bytes32 commitment) external;
    function register(Registration calldata registration, uint256 maxPrice) external payable;
    function withdraw() external;

    // ---- genesis (GENESIS_ROLE; renounced inside sealGenesis)
    function registerReservedBatch(string[] calldata labels) external;
    function sealGenesis(bytes32 merkleRoot) external;
}
