// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IAttestationRegistry} from "../interfaces/IAttestationRegistry.sol";

/// @title AttestationRegistry — C11, WP-128: DNS/social attestations (onchain-design §5.1, M3b)
/// @notice Off-chain fact (DNS TXT ownership, social-account control) attested by an allow-listed
///         attestor key via an EIP-712 signature; anyone may submit it on-chain (`attest`), so the
///         attestor key never needs gas or a hot wallet. Keyed by `(collection, tokenId, kind)`:
///         `Kind.Domain` and `Kind.Social` are independent slots for the same name.
///
/// @dev Roles: DEFAULT_ADMIN_ROLE = timelock (`setAttestor`, and co-authority with the original
///      attestor on `closeAttestation` — onchain-design §5.1 "Revocation by attestor or timelock").
///      EIP-712 domain is independent of `VerifiedAddrResolver`'s (SR-41 uses `{"arcns","1"}` for
///      record proofs; this module uses `{"arcns-attestation","1"}` so the two signing surfaces can
///      never be confused with, or replayed against, one another). Signature verification uses
///      OpenZeppelin `ECDSA.tryRecover` (rejects high-`s` and non-{27,28} `v`, T-SIG-1/SR-40) so every
///      malformed-signature path (bad length, invalid s, `ecrecover` returning the zero address)
///      surfaces as this contract's own `InvalidSignature()` rather than an OZ-internal error.
contract AttestationRegistry is IAttestationRegistry, AccessControl, EIP712 {
    /// @dev `keccak256("Attest(address collection,uint256 tokenId,uint8 kind,bytes32 evidenceHash,uint256 deadline)")`.
    bytes32 public constant ATTEST_TYPEHASH =
        keccak256("Attest(address collection,uint256 tokenId,uint8 kind,bytes32 evidenceHash,uint256 deadline)");

    mapping(address attestor => bool allowed) internal _isAttestor;
    mapping(address collection => mapping(uint256 tokenId => mapping(Kind kind => Attestation))) internal _attestations;

    constructor(address admin) EIP712("arcns-attestation", "1") {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IAttestationRegistry
    function isAttestor(address who) external view returns (bool) {
        return _isAttestor[who];
    }

    /// @inheritdoc IAttestationRegistry
    function attestationOf(address collection, uint256 tokenId, Kind kind) external view returns (Attestation memory) {
        return _attestations[collection][tokenId][kind];
    }

    /// @inheritdoc IAttestationRegistry
    function isAttested(address collection, uint256 tokenId, Kind kind) public view returns (bool) {
        Attestation storage a = _attestations[collection][tokenId][kind];
        return a.attestor != address(0) && !a.revoked;
    }

    /// @inheritdoc IAttestationRegistry
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IAttestationRegistry
    function setAttestor(address attestor, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (attestor == address(0)) revert ZeroAddress();
        _isAttestor[attestor] = allowed;
        emit AttestorSet(attestor, allowed);
    }

    // ---------------------------------------------------------------------------------------------
    // Attest / revoke
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IAttestationRegistry
    /// @dev A revoked attestation (`revoked == true`) does not block a fresh `attest` for the same
    ///      `(collection, tokenId, kind)` — only a currently-live one does (`AttestationExists`).
    function attest(
        address collection,
        uint256 tokenId,
        Kind kind,
        bytes32 evidenceHash,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired(deadline, block.timestamp);

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(ATTEST_TYPEHASH, collection, tokenId, uint8(kind), evidenceHash, deadline))
        );
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError) revert InvalidSignature();
        if (!_isAttestor[signer]) revert NotAllowedAttestor(signer);

        if (isAttested(collection, tokenId, kind)) revert AttestationExists(collection, tokenId, kind);

        _attestations[collection][tokenId][kind] = Attestation({
            attestor: signer, evidenceHash: evidenceHash, createdAt: uint40(block.timestamp), revoked: false
        });
        emit Attested(collection, tokenId, kind, evidenceHash, signer);
    }

    /// @inheritdoc IAttestationRegistry
    /// @dev Marks `revoked = true` rather than deleting, so `attestationOf` keeps returning the
    ///      historical record (attestor, evidence, createdAt) with `revoked: true`.
    function closeAttestation(address collection, uint256 tokenId, Kind kind) external {
        Attestation storage a = _attestations[collection][tokenId][kind];
        if (a.attestor == address(0)) revert NoAttestation(collection, tokenId, kind);
        if (msg.sender != a.attestor && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotRevoker(collection, tokenId, kind, msg.sender);
        }
        a.revoked = true;
        emit AttestationRevoked(collection, tokenId, kind, a.attestor);
    }
}
