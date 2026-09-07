// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IAttestationRegistry — C11, WP-128: DNS/social attestations (onchain-design §5.1, M3b)
/// @notice Off-chain fact (DNS TXT ownership, social-account control) attested by an allow-listed
///         attestor key via EIP-712 signature; **anyone** may submit it on-chain (the attestor key
///         never needs gas or a hot wallet — an improvement over x1, where the attestor signs a tx
///         directly). Keyed by `(collection, tokenId, kind)` — one domain attestation and one social
///         attestation may be live per name at a time, each tied to the attestor who created it.
interface IAttestationRegistry {
    enum Kind {
        Domain,
        Social
    }

    struct Attestation {
        address attestor;
        bytes32 evidenceHash;
        uint40 createdAt;
        bool revoked;
    }

    event AttestorSet(address indexed attestor, bool allowed);
    event Attested(
        address indexed collection, uint256 indexed tokenId, Kind indexed kind, bytes32 evidenceHash, address attestor
    );
    event AttestationRevoked(address indexed collection, uint256 indexed tokenId, Kind indexed kind, address attestor);

    error NotAllowedAttestor(address attestor);
    error SignatureExpired(uint256 deadline, uint256 now_);
    error InvalidSignature();
    error AttestationExists(address collection, uint256 tokenId, Kind kind);
    error NoAttestation(address collection, uint256 tokenId, Kind kind);
    error NotRevoker(address collection, uint256 tokenId, Kind kind, address caller);
    error ZeroAddress();

    function isAttestor(address who) external view returns (bool);
    function attestationOf(address collection, uint256 tokenId, Kind kind) external view returns (Attestation memory);
    function isAttested(address collection, uint256 tokenId, Kind kind) external view returns (bool); // exists && !revoked

    /// @notice EIP-712 domain separator, exposed so the SDK/attestor tooling can build a matching digest.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function setAttestor(address attestor, bool allowed) external; // DEFAULT_ADMIN_ROLE (timelock)

    /// @notice `signature` is the attestor's EIP-712 signature over
    ///         `Attest(address collection,uint256 tokenId,uint8 kind,bytes32 evidenceHash,uint256 deadline)`.
    ///         Anyone may call; the signer (recovered from `signature`) must be an allowed attestor.
    function attest(
        address collection,
        uint256 tokenId,
        Kind kind,
        bytes32 evidenceHash,
        uint256 deadline,
        bytes calldata signature
    ) external;

    /// @notice The attestor who created it, or DEFAULT_ADMIN_ROLE (timelock) — x1/onchain-design §5.1
    ///         "Revocation by attestor or timelock".
    function closeAttestation(address collection, uint256 tokenId, Kind kind) external;
}
