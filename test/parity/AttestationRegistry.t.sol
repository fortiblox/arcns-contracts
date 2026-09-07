// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {AttestationRegistry} from "../../src/parity/AttestationRegistry.sol";
import {IAttestationRegistry} from "../../src/interfaces/IAttestationRegistry.sol";

/// @notice Unit tests for `AttestationRegistry` (WP-128, C11): EIP-712 attest/revoke, allow-listed
///         attestors, cross-field replay resistance, revoke-then-re-attest, Kind.Domain/Kind.Social
///         independence.
contract AttestationRegistryTest is Test {
    bytes32 internal constant ATTEST_TYPEHASH =
        keccak256("Attest(address collection,uint256 tokenId,uint8 kind,bytes32 evidenceHash,uint256 deadline)");
    bytes32 internal constant EIP712DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    AttestationRegistry internal reg;

    address internal admin = makeAddr("admin");
    address internal attacker = makeAddr("attacker");
    // Placeholder "collection" address — this module never calls ownerOf/etc on it, it only keys
    // storage off (collection, tokenId, kind), so a plain address stands in for an NFT collection.
    address internal collection = address(0xC011EC71011);

    uint256 internal attestorKey = 0xA11CE;
    address internal attestor;
    uint256 internal otherAttestorKey = 0xB0B;
    address internal otherAttestor;

    uint256 internal constant T0 = 1_700_000_000;

    function setUp() public {
        vm.warp(T0);
        attestor = vm.addr(attestorKey);
        otherAttestor = vm.addr(otherAttestorKey);
        reg = new AttestationRegistry(admin);
        vm.prank(admin);
        reg.setAttestor(attestor, true);
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    function _digest(
        address collection_,
        uint256 tokenId,
        IAttestationRegistry.Kind kind,
        bytes32 evidenceHash,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                EIP712DOMAIN_TYPEHASH, keccak256("arcns-attestation"), keccak256("1"), block.chainid, address(reg)
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(ATTEST_TYPEHASH, collection_, tokenId, uint8(kind), evidenceHash, deadline));
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _validSig(
        uint256 key,
        address collection_,
        uint256 tokenId,
        IAttestationRegistry.Kind kind,
        bytes32 evidenceHash,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(key, _digest(collection_, tokenId, kind, evidenceHash, deadline));
    }

    // ---------------------------------------------------------------------------------------------
    // constructor / admin
    // ---------------------------------------------------------------------------------------------

    function test_constructor_zero_admin_reverts() public {
        vm.expectRevert(IAttestationRegistry.ZeroAddress.selector);
        new AttestationRegistry(address(0));
    }

    function test_setAttestor_admin_only_and_zero_address() public {
        vm.expectRevert(IAttestationRegistry.ZeroAddress.selector);
        vm.prank(admin);
        reg.setAttestor(address(0), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, reg.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        reg.setAttestor(otherAttestor, true);

        assertFalse(reg.isAttestor(otherAttestor));
        vm.prank(admin);
        reg.setAttestor(otherAttestor, true);
        assertTrue(reg.isAttestor(otherAttestor));
        vm.prank(admin);
        reg.setAttestor(otherAttestor, false);
        assertFalse(reg.isAttestor(otherAttestor));
    }

    function test_domain_separator_matches_hand_rolled() public view {
        bytes32 domain = keccak256(
            abi.encode(
                EIP712DOMAIN_TYPEHASH, keccak256("arcns-attestation"), keccak256("1"), block.chainid, address(reg)
            )
        );
        assertEq(reg.DOMAIN_SEPARATOR(), domain);
    }

    // ---------------------------------------------------------------------------------------------
    // attest — happy path
    // ---------------------------------------------------------------------------------------------

    function test_attest_valid_succeeds() public {
        uint256 tokenId = 42;
        bytes32 evidence = keccak256("dns-txt-record");
        uint256 deadline = T0 + 1 hours;
        bytes memory sig =
            _validSig(attestorKey, collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline);

        vm.expectEmit(true, true, true, true, address(reg));
        emit IAttestationRegistry.Attested(collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, attestor);
        reg.attest(collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline, sig);

        IAttestationRegistry.Attestation memory a =
            reg.attestationOf(collection, tokenId, IAttestationRegistry.Kind.Domain);
        assertEq(a.attestor, attestor);
        assertEq(a.evidenceHash, evidence);
        assertEq(a.createdAt, T0);
        assertFalse(a.revoked);
        assertTrue(reg.isAttested(collection, tokenId, IAttestationRegistry.Kind.Domain));
    }

    /// @dev Anyone may submit — the caller need not be the attestor.
    function test_attest_callable_by_anyone() public {
        uint256 tokenId = 1;
        bytes32 evidence = keccak256("ev");
        uint256 deadline = T0 + 1 hours;
        bytes memory sig =
            _validSig(attestorKey, collection, tokenId, IAttestationRegistry.Kind.Social, evidence, deadline);

        vm.prank(attacker);
        reg.attest(collection, tokenId, IAttestationRegistry.Kind.Social, evidence, deadline, sig);
        assertTrue(reg.isAttested(collection, tokenId, IAttestationRegistry.Kind.Social));
    }

    // ---------------------------------------------------------------------------------------------
    // attest — failure paths
    // ---------------------------------------------------------------------------------------------

    function test_attest_expired_deadline_reverts() public {
        uint256 tokenId = 1;
        bytes32 evidence = keccak256("ev");
        uint256 deadline = T0 - 1;
        // deadline in the past relative to "now" — warp forward past it first.
        vm.warp(T0 + 10);
        bytes memory sig =
            _validSig(attestorKey, collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline);

        vm.expectRevert(
            abi.encodeWithSelector(IAttestationRegistry.SignatureExpired.selector, deadline, block.timestamp)
        );
        reg.attest(collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline, sig);
    }

    function test_attest_exactly_at_deadline_succeeds() public {
        uint256 tokenId = 1;
        bytes32 evidence = keccak256("ev");
        uint256 deadline = T0;
        bytes memory sig =
            _validSig(attestorKey, collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline);
        // block.timestamp == deadline: `> deadline` check does not trip.
        reg.attest(collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline, sig);
        assertTrue(reg.isAttested(collection, tokenId, IAttestationRegistry.Kind.Domain));
    }

    function test_attest_nonAllowlisted_signer_reverts() public {
        uint256 tokenId = 1;
        bytes32 evidence = keccak256("ev");
        uint256 deadline = T0 + 1 hours;
        // otherAttestor is a valid key but never allow-listed.
        bytes memory sig =
            _validSig(otherAttestorKey, collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline);

        vm.expectRevert(abi.encodeWithSelector(IAttestationRegistry.NotAllowedAttestor.selector, otherAttestor));
        reg.attest(collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline, sig);
    }

    function test_attest_crossField_replay_reverts_notAllowedAttestor() public {
        // Attestor signs a message for tokenId=1, but the caller submits it for tokenId=2. The
        // recovered signer is a *different*, non-allow-listed address (garbage recovery), so this
        // surfaces as NotAllowedAttestor rather than silently succeeding for the wrong token.
        bytes32 evidence = keccak256("ev");
        uint256 deadline = T0 + 1 hours;
        bytes memory sig = _validSig(attestorKey, collection, 1, IAttestationRegistry.Kind.Domain, evidence, deadline);

        address recoveredForWrongTokenId =
            ECDSA.recover(_digest(collection, 2, IAttestationRegistry.Kind.Domain, evidence, deadline), sig);
        assertTrue(recoveredForWrongTokenId != attestor);

        vm.expectRevert(
            abi.encodeWithSelector(IAttestationRegistry.NotAllowedAttestor.selector, recoveredForWrongTokenId)
        );
        reg.attest(collection, 2, IAttestationRegistry.Kind.Domain, evidence, deadline, sig);
    }

    function test_attest_crossField_replay_wrongKind_reverts() public {
        bytes32 evidence = keccak256("ev");
        uint256 deadline = T0 + 1 hours;
        bytes memory sig = _validSig(attestorKey, collection, 1, IAttestationRegistry.Kind.Domain, evidence, deadline);

        address recovered =
            ECDSA.recover(_digest(collection, 1, IAttestationRegistry.Kind.Social, evidence, deadline), sig);
        assertTrue(recovered != attestor);
        vm.expectRevert(abi.encodeWithSelector(IAttestationRegistry.NotAllowedAttestor.selector, recovered));
        reg.attest(collection, 1, IAttestationRegistry.Kind.Social, evidence, deadline, sig);
    }

    function test_attest_crossField_replay_wrongEvidence_reverts() public {
        uint256 deadline = T0 + 1 hours;
        bytes memory sig =
            _validSig(attestorKey, collection, 1, IAttestationRegistry.Kind.Domain, keccak256("ev-A"), deadline);

        address recovered =
            ECDSA.recover(_digest(collection, 1, IAttestationRegistry.Kind.Domain, keccak256("ev-B"), deadline), sig);
        assertTrue(recovered != attestor);
        vm.expectRevert(abi.encodeWithSelector(IAttestationRegistry.NotAllowedAttestor.selector, recovered));
        reg.attest(collection, 1, IAttestationRegistry.Kind.Domain, keccak256("ev-B"), deadline, sig);
    }

    function test_attest_crossField_replay_wrongDeadline_reverts() public {
        bytes32 evidence = keccak256("ev");
        uint256 signedDeadline = T0 + 1 hours;
        bytes memory sig =
            _validSig(attestorKey, collection, 1, IAttestationRegistry.Kind.Domain, evidence, signedDeadline);

        uint256 submittedDeadline = T0 + 2 hours;
        address recovered =
            ECDSA.recover(_digest(collection, 1, IAttestationRegistry.Kind.Domain, evidence, submittedDeadline), sig);
        assertTrue(recovered != attestor);
        vm.expectRevert(abi.encodeWithSelector(IAttestationRegistry.NotAllowedAttestor.selector, recovered));
        reg.attest(collection, 1, IAttestationRegistry.Kind.Domain, evidence, submittedDeadline, sig);
    }

    function test_attest_crossField_replay_wrongCollection_reverts() public {
        bytes32 evidence = keccak256("ev");
        uint256 deadline = T0 + 1 hours;
        bytes memory sig = _validSig(attestorKey, collection, 1, IAttestationRegistry.Kind.Domain, evidence, deadline);

        address otherCollection = address(0xBEEF);
        address recovered =
            ECDSA.recover(_digest(otherCollection, 1, IAttestationRegistry.Kind.Domain, evidence, deadline), sig);
        assertTrue(recovered != attestor);
        vm.expectRevert(abi.encodeWithSelector(IAttestationRegistry.NotAllowedAttestor.selector, recovered));
        reg.attest(otherCollection, 1, IAttestationRegistry.Kind.Domain, evidence, deadline, sig);
    }

    function test_attest_malformed_signature_reverts_InvalidSignature() public {
        bytes32 evidence = keccak256("ev");
        uint256 deadline = T0 + 1 hours;
        bytes memory garbage = new bytes(65); // all-zero r,s,v — ecrecover fails cleanly

        vm.expectRevert(IAttestationRegistry.InvalidSignature.selector);
        reg.attest(collection, 1, IAttestationRegistry.Kind.Domain, evidence, deadline, garbage);
    }

    function test_attest_wrongLength_signature_reverts_InvalidSignature() public {
        bytes32 evidence = keccak256("ev");
        uint256 deadline = T0 + 1 hours;
        bytes memory tooShort = new bytes(64);

        vm.expectRevert(IAttestationRegistry.InvalidSignature.selector);
        reg.attest(collection, 1, IAttestationRegistry.Kind.Domain, evidence, deadline, tooShort);
    }

    function test_attest_highS_signature_reverts_InvalidSignature() public {
        uint256 tokenId = 1;
        bytes32 evidence = keccak256("ev");
        uint256 deadline = T0 + 1 hours;
        bytes32 digest = _digest(collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorKey, digest);
        // secp256k1 order N; flip s to the malleable (high) half and v accordingly.
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        bytes memory malleableSig = abi.encodePacked(r, highS, flippedV);

        vm.expectRevert(IAttestationRegistry.InvalidSignature.selector);
        reg.attest(collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline, malleableSig);
    }

    function test_attest_double_without_revoke_reverts() public {
        uint256 tokenId = 1;
        bytes32 evidence = keccak256("ev");
        uint256 deadline = T0 + 1 hours;
        bytes memory sig =
            _validSig(attestorKey, collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline);
        reg.attest(collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline, sig);

        bytes memory sig2 =
            _validSig(attestorKey, collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationRegistry.AttestationExists.selector, collection, tokenId, IAttestationRegistry.Kind.Domain
            )
        );
        reg.attest(collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline + 1, sig2);
    }

    // ---------------------------------------------------------------------------------------------
    // revoke / re-attest
    // ---------------------------------------------------------------------------------------------

    function test_closeAttestation_by_attestor_then_reAttest_succeeds() public {
        uint256 tokenId = 1;
        bytes32 evidence = keccak256("ev");
        uint256 deadline = T0 + 1 hours;
        bytes memory sig =
            _validSig(attestorKey, collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline);
        reg.attest(collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline, sig);

        vm.expectEmit(true, true, true, true, address(reg));
        emit IAttestationRegistry.AttestationRevoked(collection, tokenId, IAttestationRegistry.Kind.Domain, attestor);
        vm.prank(attestor);
        reg.closeAttestation(collection, tokenId, IAttestationRegistry.Kind.Domain);

        IAttestationRegistry.Attestation memory a =
            reg.attestationOf(collection, tokenId, IAttestationRegistry.Kind.Domain);
        assertTrue(a.revoked);
        assertFalse(reg.isAttested(collection, tokenId, IAttestationRegistry.Kind.Domain));

        // re-attest after revoke succeeds and creates a fresh, non-revoked record.
        bytes32 evidence2 = keccak256("ev2");
        uint256 deadline2 = T0 + 2 hours;
        bytes memory sig2 =
            _validSig(attestorKey, collection, tokenId, IAttestationRegistry.Kind.Domain, evidence2, deadline2);
        reg.attest(collection, tokenId, IAttestationRegistry.Kind.Domain, evidence2, deadline2, sig2);

        IAttestationRegistry.Attestation memory a2 =
            reg.attestationOf(collection, tokenId, IAttestationRegistry.Kind.Domain);
        assertFalse(a2.revoked);
        assertEq(a2.evidenceHash, evidence2);
        assertTrue(reg.isAttested(collection, tokenId, IAttestationRegistry.Kind.Domain));
    }

    function test_closeAttestation_by_admin_succeeds() public {
        uint256 tokenId = 1;
        bytes32 evidence = keccak256("ev");
        uint256 deadline = T0 + 1 hours;
        bytes memory sig =
            _validSig(attestorKey, collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline);
        reg.attest(collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline, sig);

        vm.prank(admin);
        reg.closeAttestation(collection, tokenId, IAttestationRegistry.Kind.Domain);
        assertFalse(reg.isAttested(collection, tokenId, IAttestationRegistry.Kind.Domain));
    }

    function test_closeAttestation_unauthorized_reverts() public {
        uint256 tokenId = 1;
        bytes32 evidence = keccak256("ev");
        uint256 deadline = T0 + 1 hours;
        bytes memory sig =
            _validSig(attestorKey, collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline);
        reg.attest(collection, tokenId, IAttestationRegistry.Kind.Domain, evidence, deadline, sig);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationRegistry.NotRevoker.selector,
                collection,
                tokenId,
                IAttestationRegistry.Kind.Domain,
                attacker
            )
        );
        vm.prank(attacker);
        reg.closeAttestation(collection, tokenId, IAttestationRegistry.Kind.Domain);
    }

    function test_closeAttestation_noAttestation_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationRegistry.NoAttestation.selector, collection, uint256(1), IAttestationRegistry.Kind.Domain
            )
        );
        vm.prank(admin);
        reg.closeAttestation(collection, 1, IAttestationRegistry.Kind.Domain);
    }

    // ---------------------------------------------------------------------------------------------
    // Kind.Domain / Kind.Social independence
    // ---------------------------------------------------------------------------------------------

    function test_domain_and_social_are_independent_slots() public {
        uint256 tokenId = 7;
        bytes32 evidenceDomain = keccak256("dns");
        bytes32 evidenceSocial = keccak256("twitter");
        uint256 deadline = T0 + 1 hours;

        bytes memory sigDomain =
            _validSig(attestorKey, collection, tokenId, IAttestationRegistry.Kind.Domain, evidenceDomain, deadline);
        bytes memory sigSocial =
            _validSig(attestorKey, collection, tokenId, IAttestationRegistry.Kind.Social, evidenceSocial, deadline);

        reg.attest(collection, tokenId, IAttestationRegistry.Kind.Domain, evidenceDomain, deadline, sigDomain);
        reg.attest(collection, tokenId, IAttestationRegistry.Kind.Social, evidenceSocial, deadline, sigSocial);

        assertTrue(reg.isAttested(collection, tokenId, IAttestationRegistry.Kind.Domain));
        assertTrue(reg.isAttested(collection, tokenId, IAttestationRegistry.Kind.Social));

        // revoking one does not touch the other.
        vm.prank(attestor);
        reg.closeAttestation(collection, tokenId, IAttestationRegistry.Kind.Domain);
        assertFalse(reg.isAttested(collection, tokenId, IAttestationRegistry.Kind.Domain));
        assertTrue(reg.isAttested(collection, tokenId, IAttestationRegistry.Kind.Social));

        IAttestationRegistry.Attestation memory social =
            reg.attestationOf(collection, tokenId, IAttestationRegistry.Kind.Social);
        assertEq(social.evidenceHash, evidenceSocial);
    }
}
