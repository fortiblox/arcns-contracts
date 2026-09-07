// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IHandleController — C2, commit-reveal registration for the handle namespace (onchain-design §2, port-map 8–9)
/// @notice Sole REGISTRAR_ROLE on HandleRegistry. Same commit-reveal, `maxPrice`, pull-ledger, treasury
///         and genesis rules as `ITldRegistrarController`; integrators/vouchers are M3b (WP-129/130).
interface IHandleController {
    event NameRegistered(string name, uint256 indexed tokenId, address indexed owner, uint256 cost, uint8 handleType);
    event CommitmentMade(bytes32 indexed commitment, uint256 timestamp);
    event ReservedRegistered(uint256 indexed tokenId, string name);
    event GenesisSealed(bytes32 indexed namespaceId, bytes32 merkleRoot, uint256 reservedCount);
    event TreasuryFee(uint256 indexed tokenId, uint256 amount);
    event Credited(address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    error CommitmentNotFound(bytes32 commitment);
    error CommitmentTooNew(bytes32 commitment, uint256 minimumCommitmentTimestamp, uint256 currentTimestamp);
    error CommitmentTooOld(bytes32 commitment, uint256 maximumCommitmentTimestamp, uint256 currentTimestamp);
    error UnexpiredCommitmentExists(bytes32 commitment);
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
    error MinCommitmentAgeBelowFloor(uint256 provided, uint256 floor);
    error MaxCommitmentAgeInvalid(uint256 provided);

    function namespaceId() external view returns (bytes32); // HANDLE_ROOT
    function treasury() external view returns (address);
    function minCommitmentAge() external view returns (uint256);
    function maxCommitmentAge() external view returns (uint256);
    function MIN_COMMITMENT_AGE_FLOOR() external view returns (uint256);
    function genesisSealed() external view returns (bool);
    function genesisRoot() external view returns (bytes32);
    function reservedCount() external view returns (uint256);
    function commitments(bytes32 commitment) external view returns (uint256);
    function withdrawable(address who) external view returns (uint256);

    function valid(string calldata name) external pure returns (bool);
    function available(string calldata name) external view returns (bool);
    function quote(string calldata name) external view returns (uint256 priceWei);
    /// @dev commitment = keccak256(abi.encode("handle", name, owner, secret, block.chainid, address(this), handleType))
    function makeCommitment(string calldata name, address owner, bytes32 secret, uint8 handleType)
        external
        view
        returns (bytes32);
    function commit(bytes32 commitment) external;
    function register(string calldata name, address owner, bytes32 secret, uint8 handleType, uint256 maxPrice)
        external
        payable;
    function withdraw() external;

    function registerReservedBatch(string[] calldata names, uint8[] calldata handleTypes) external;
    function sealGenesis(bytes32 merkleRoot) external;
}
