// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";
import {IArcNSResolver} from "../../src/interfaces/IArcNSResolver.sol";
import {ArcNSResolver} from "../../src/resolver/ArcNSResolver.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {BtcMessage} from "../../src/lib/BtcMessage.sol";
import {Challenge} from "../../src/lib/Challenge.sol";
import {ResolverFixture} from "./mocks/ResolverFixture.sol";
import {Mock1271Wallet} from "./mocks/Mock1271Wallet.sol";

/// @notice Per-chain ownership proofs (port-map rows 21–23, onchain-design §5): EVM proofs are EIP-712 typed data
///         (SR-41) and every struct / domain field binds (`cross_purpose_signatures_never_collide` port); OZ ECDSA
///         strictness, BIP-137 routing over the challenge string, ERC-1271 and the ed25519 governance switch.
contract VerifiedAddrTest is ResolverFixture {
    event AddressVerified(bytes32 indexed node, uint256 coinType, uint8 method);

    uint256 internal constant SIGNER_PK = 0xA11CE;
    address internal signer;
    bytes32 internal node;
    uint256 internal tokenId;

    // secp256k1 generator = public key of private key 1 (the standard BTC test vector)
    bytes internal constant G64 = abi.encodePacked(
        bytes32(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798),
        bytes32(0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)
    );
    bytes internal constant P2PKH_SCRIPT = hex"76a914751e76e8199196d454941c45d1b3a323f1433bd688ac";
    bytes internal constant P2WPKH_SCRIPT = hex"0014751e76e8199196d454941c45d1b3a323f1433bd6";

    function setUp() public override {
        super.setUp();
        signer = vm.addr(SIGNER_PK);
        (tokenId, node) = _handle("alice", alice);
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev EIP-712 RecordProof signature from `who` over the resolver's own digest.
    function _sign712(ArcNSResolver r, uint256 pk, bytes32 n, uint256 coinType, string memory nonce)
        internal
        view
        returns (bytes memory sig)
    {
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(pk, r.recordProofDigest(n, coinType, nonce));
        sig = abi.encodePacked(rr, ss, v);
    }

    function _sign712(uint256 pk, bytes32 n, uint256 coinType, string memory nonce)
        internal
        view
        returns (bytes memory)
    {
        return _sign712(resolver, pk, n, coinType, nonce);
    }

    function _setEthRecord(bytes32 n, address owner, uint256 coinType, address who) internal {
        vm.prank(owner);
        resolver.setAddr(n, coinType, abi.encodePacked(who));
    }

    function _btcSig(string memory c, bool segwit) internal pure returns (bytes memory sig65) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, BtcMessage.digest(bytes(c)));
        uint8 header = (segwit ? 39 : 31) + (v - 27);
        sig65 = abi.encodePacked(header, r, s);
    }

    // ---------------------------------------------------------------------------------------------
    // challenge
    // ---------------------------------------------------------------------------------------------

    function test_challenge_matches_the_pure_builder() public view {
        string memory c = resolver.challenge(node, 60, "nonce1");
        assertEq(c, Challenge.build(node, 60, resolver.versionOf(node), block.chainid, address(resolver), "nonce1"));
    }

    function test_challenge_rejects_bad_nonce() public {
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.BadNonce.selector, "a:b"));
        resolver.challenge(node, 60, "a:b");
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.BadNonce.selector, "a:b"));
        resolver.recordProofDigest(node, 60, "a:b");
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.BadNonce.selector, ""));
        resolver.recordProofDigest(node, 60, "");
    }

    function test_recordProofDigest_binds_the_current_version() public {
        bytes32 d = resolver.recordProofDigest(node, 60, "n1");
        handles.transfer(tokenId, bob);
        assertNotEq(resolver.recordProofDigest(node, 60, "n1"), d);
    }

    // ---------------------------------------------------------------------------------------------
    // secp256k1 (EIP-191)
    // ---------------------------------------------------------------------------------------------

    function test_secp256k1_happy_path() public {
        _setEthRecord(node, alice, 60, signer);
        bytes memory sig = _sign712(SIGNER_PK, node, 60, "n1");
        vm.expectEmit(true, false, false, true, address(resolver));
        emit AddressVerified(node, 60, uint8(IArcNSResolver.VerifyMethod.Secp256k1));
        uint256 g = gasleft();
        resolver.verifyAddrSecp256k1(node, 60, "n1", sig); // anyone may submit the proof
        emit log_named_uint("gas verifyAddrSecp256k1", g - gasleft());
        assertTrue(resolver.verified(node, 60));
        assertEq(resolver.verifiedAt(node, 60), uint64(block.timestamp));
    }

    function test_secp256k1_works_for_ensip11_evm_coin_types() public {
        uint256 op = 0x80000000 | 10;
        _setEthRecord(node, alice, op, signer);
        resolver.verifyAddrSecp256k1(node, op, "n1", _sign712(SIGNER_PK, node, op, "n1"));
        assertTrue(resolver.verified(node, op));
    }

    function test_secp256k1_rejects_non_evm_coin_type_and_missing_record() public {
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.UnsupportedCoinType.selector, 0));
        resolver.verifyAddrSecp256k1(node, 0, "n1", "");
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.UnsupportedCoinType.selector, 501));
        resolver.verifyAddrSecp256k1(node, 501, "n1", "");
        bytes memory sig = _sign712(SIGNER_PK, node, 60, "n1");
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NoRecord.selector, node, 60));
        resolver.verifyAddrSecp256k1(node, 60, "n1", sig);
    }

    function test_secp256k1_wrong_signer_is_a_record_mismatch() public {
        _setEthRecord(node, alice, 60, signer);
        bytes memory sig = _sign712(0xB0B, node, 60, "n1");
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 60));
        resolver.verifyAddrSecp256k1(node, 60, "n1", sig);
        assertFalse(resolver.verified(node, 60));
        // an EIP-191 signature over the challenge string is not a record proof any more (SR-41)
        (uint8 v, bytes32 r, bytes32 ss) =
            vm.sign(SIGNER_PK, MessageHashUtils.toEthSignedMessageHash(bytes(resolver.challenge(node, 60, "n1"))));
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 60));
        resolver.verifyAddrSecp256k1(node, 60, "n1", abi.encodePacked(r, ss, v));
    }

    /// @dev `cross_purpose_signatures_never_collide` port: a signature over one RecordProof must not verify
    ///      once any single struct field (node, coinType, version, nonce) or domain field (chainId,
    ///      verifyingContract) differs.
    function test_flipping_any_field_invalidates_the_proof() public {
        _setEthRecord(node, alice, 60, signer);
        bytes32 d = resolver.recordProofDigest(node, 60, "n1");
        bytes memory sig = _sign712(SIGNER_PK, node, 60, "n1");

        // node: same record on bob's handle
        (, bytes32 bobNode) = _handle("bob", bob);
        _setEthRecord(bobNode, bob, 60, signer);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, bobNode, 60));
        resolver.verifyAddrSecp256k1(bobNode, 60, "n1", sig);

        // coinType: same record under another EVM coin type
        uint256 op = 0x80000000 | 10;
        _setEthRecord(node, alice, op, signer);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, op));
        resolver.verifyAddrSecp256k1(node, op, "n1", sig);

        // nonce
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 60));
        resolver.verifyAddrSecp256k1(node, 60, "n2", sig);

        // chainId (EIP-712 domain): the OZ domain separator is rebuilt when the chain id changes
        vm.chainId(5042002);
        assertNotEq(resolver.recordProofDigest(node, 60, "n1"), d);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 60));
        resolver.verifyAddrSecp256k1(node, 60, "n1", sig);
        vm.chainId(31337);
        assertEq(resolver.recordProofDigest(node, 60, "n1"), d);

        // verifyingContract (EIP-712 domain): a second deployment with identical state
        ArcNSResolver other =
            new ArcNSResolver(registry, IHandleRegistry(address(handles)), directory, reverseAddr, admin);
        vm.prank(alice);
        other.setAddr(node, 60, abi.encodePacked(signer));
        assertNotEq(other.recordProofDigest(node, 60, "n1"), d);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 60));
        other.verifyAddrSecp256k1(node, 60, "n1", sig);
        // ... while a signature made for `other` verifies there
        other.verifyAddrSecp256k1(node, 60, "n1", _sign712(other, SIGNER_PK, node, 60, "n1"));
        assertTrue(other.verified(node, 60));

        // version: a transfer (x1-handles#111) — the new owner re-creates the same record and replays
        handles.transfer(tokenId, bob);
        _setEthRecord(node, bob, 60, signer);
        assertNotEq(resolver.recordProofDigest(node, 60, "n1"), d);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 60));
        resolver.verifyAddrSecp256k1(node, 60, "n1", sig);
        assertFalse(resolver.verified(node, 60));

        // the unchanged challenge still verifies on the original instance before any flip
        handles.transfer(tokenId, alice);
        // alice owns again, but the epoch moved on: the original proof is dead for good
        _setEthRecord(node, alice, 60, signer);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 60));
        resolver.verifyAddrSecp256k1(node, 60, "n1", sig);
    }

    function test_high_s_forgery_rejected() public {
        _setEthRecord(node, alice, 60, signer);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, resolver.recordProofDigest(node, 60, "n1"));
        // (r, n - s, v') is the malleated twin: valid under a lax ecrecover, rejected by OZ (SR-40)
        bytes32 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sHigh = bytes32(uint256(n) - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        bytes memory forged = abi.encodePacked(r, sHigh, vFlip);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, sHigh));
        resolver.verifyAddrSecp256k1(node, 60, "n1", forged);
        // malformed length
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 64));
        resolver.verifyAddrSecp256k1(node, 60, "n1", abi.encodePacked(r, s));
    }

    function test_setAddr_clears_verified_and_transfer_hides_it() public {
        _setEthRecord(node, alice, 60, signer);
        resolver.verifyAddrSecp256k1(node, 60, "n1", _sign712(SIGNER_PK, node, 60, "n1"));
        assertTrue(resolver.verified(node, 60));
        _setEthRecord(node, alice, 60, signer); // same value, still a write ⇒ X1 update_record rule
        assertFalse(resolver.verified(node, 60));
        resolver.verifyAddrSecp256k1(node, 60, "n2", _sign712(SIGNER_PK, node, 60, "n2"));
        assertTrue(resolver.verified(node, 60));
        vm.prank(alice);
        resolver.setAddr(node, signer); // 20-byte overload goes through the same hook
        assertFalse(resolver.verified(node, 60));
        resolver.verifyAddrSecp256k1(node, 60, "n3", _sign712(SIGNER_PK, node, 60, "n3"));
        handles.transfer(tokenId, bob);
        assertFalse(resolver.verified(node, 60));
        assertEq(resolver.verifiedAt(node, 60), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // self (Arc coin type)
    // ---------------------------------------------------------------------------------------------

    function test_verifyAddrSelf_on_arc() public {
        vm.chainId(5042002);
        assertEq(ArcNSConstants.evmCoinType(), 0x804cef52);
        assertEq(ArcNSConstants.evmCoinType(), ArcNSConstants.ARC_TESTNET_COIN_TYPE);
        _setEthRecord(node, alice, 0x804cef52, signer);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 0x804cef52));
        resolver.verifyAddrSelf(node, 0x804cef52);
        vm.prank(signer);
        vm.expectEmit(true, false, false, true, address(resolver));
        emit AddressVerified(node, 0x804cef52, uint8(IArcNSResolver.VerifyMethod.Self));
        uint256 g = gasleft();
        resolver.verifyAddrSelf(node, 0x804cef52);
        emit log_named_uint("gas verifyAddrSelf", g - gasleft());
        assertTrue(resolver.verified(node, 0x804cef52));
        // only the chain's own coin type qualifies for the self path
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.UnsupportedCoinType.selector, 60));
        resolver.verifyAddrSelf(node, 60);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NoRecord.selector, bytes32(uint256(1)), 0x804cef52));
        vm.prank(signer);
        resolver.verifyAddrSelf(bytes32(uint256(1)), 0x804cef52);
    }

    function test_verifyAddrSelf1271_with_a_contract_wallet() public {
        vm.chainId(5042002);
        Mock1271Wallet wallet = new Mock1271Wallet(signer);
        _setEthRecord(node, alice, 0x804cef52, address(wallet));
        bytes memory sig = _sign712(SIGNER_PK, node, 0x804cef52, "n1"); // the wallet validates the EIP-712 digest
        vm.expectEmit(true, false, false, true, address(resolver));
        emit AddressVerified(node, 0x804cef52, uint8(IArcNSResolver.VerifyMethod.Self));
        resolver.verifyAddrSelf1271(node, 0x804cef52, "n1", sig);
        assertTrue(resolver.verified(node, 0x804cef52));
        // wrong key behind the wallet
        bytes memory bad = _sign712(0xB0B, node, 0x804cef52, "n2");
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 0x804cef52));
        resolver.verifyAddrSelf1271(node, 0x804cef52, "n2", bad);
        // OZ SignatureChecker falls back to ECDSA for an EOA record, so the 1271 entry point also accepts a
        // plain EOA signature over the challenge (still the record's own key, SR-42)
        _setEthRecord(node, alice, 0x804cef52, signer);
        bytes memory eoa = _sign712(SIGNER_PK, node, 0x804cef52, "n3");
        resolver.verifyAddrSelf1271(node, 0x804cef52, "n3", eoa);
        assertTrue(resolver.verified(node, 0x804cef52));
        bytes memory eoaBad = _sign712(0xB0B, node, 0x804cef52, "n4");
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 0x804cef52));
        resolver.verifyAddrSelf1271(node, 0x804cef52, "n4", eoaBad);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.UnsupportedCoinType.selector, 60));
        resolver.verifyAddrSelf1271(node, 60, "n3", sig);
    }

    // ---------------------------------------------------------------------------------------------
    // bitcoin (BIP-137)
    // ---------------------------------------------------------------------------------------------

    function test_btc_p2pkh_happy_path() public {
        vm.prank(alice);
        resolver.setAddr(node, 0, P2PKH_SCRIPT);
        bytes memory sig = _btcSig(resolver.challenge(node, 0, "n1"), false);
        vm.expectEmit(true, false, false, true, address(resolver));
        emit AddressVerified(node, 0, uint8(IArcNSResolver.VerifyMethod.Bitcoin));
        uint256 g = gasleft();
        resolver.verifyAddrBtc(node, "n1", sig, G64);
        emit log_named_uint("gas verifyAddrBtc (P2PKH)", g - gasleft());
        assertTrue(resolver.verified(node, 0));
    }

    function test_btc_p2wpkh_happy_path() public {
        vm.prank(alice);
        resolver.setAddr(node, 0, P2WPKH_SCRIPT);
        bytes memory sig = _btcSig(resolver.challenge(node, 0, "n1"), true);
        resolver.verifyAddrBtc(node, "n1", sig, G64);
        assertTrue(resolver.verified(node, 0));
    }

    function test_btc_header_type_must_match_the_record_type() public {
        vm.prank(alice);
        resolver.setAddr(node, 0, P2PKH_SCRIPT);
        bytes memory sig = _btcSig(resolver.challenge(node, 0, "n1"), true); // segwit header, P2PKH record
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 0));
        resolver.verifyAddrBtc(node, "n1", sig, G64);
    }

    function test_btc_wrong_record_rejected() public {
        vm.prank(alice);
        resolver.setAddr(node, 0, hex"76a914000000000000000000000000000000000000000088ac");
        bytes memory sig = _btcSig(resolver.challenge(node, 0, "n1"), false);
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 0));
        resolver.verifyAddrBtc(node, "n1", sig, G64);
    }

    function test_btc_wrong_pubkey_or_nonce_rejected() public {
        vm.prank(alice);
        resolver.setAddr(node, 0, P2PKH_SCRIPT);
        bytes memory sig = _btcSig(resolver.challenge(node, 0, "n1"), false);
        bytes memory wrongKey = abi.encodePacked(bytes32(uint256(7)), bytes32(uint256(8)));
        vm.expectRevert(IArcNSResolver.BadPublicKey.selector);
        resolver.verifyAddrBtc(node, "n1", sig, wrongKey);
        vm.expectRevert(IArcNSResolver.BadPublicKey.selector);
        resolver.verifyAddrBtc(node, "n2", sig, G64);
        vm.expectRevert(IArcNSResolver.BadPublicKey.selector);
        resolver.verifyAddrBtc(node, "n1", sig, hex"79BE");
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.BadSignatureLength.selector, 1));
        resolver.verifyAddrBtc(node, "n1", hex"00", G64);
    }

    function test_btc_header_ranges_route_like_btc_rs() public {
        vm.prank(alice);
        resolver.setAddr(node, 0, P2PKH_SCRIPT);
        bytes memory rs = new bytes(64);
        for (uint8 h = 27; h <= 30; h++) {
            vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.UnsupportedBtcAddressType.selector, h));
            resolver.verifyAddrBtc(node, "n1", abi.encodePacked(h, rs), G64);
        }
        for (uint8 h = 35; h <= 38; h++) {
            vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.UnsupportedBtcAddressType.selector, h));
            resolver.verifyAddrBtc(node, "n1", abi.encodePacked(h, rs), G64);
        }
        uint8[5] memory bad = [0, 1, 26, 43, 255];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.BadRecoveryId.selector, bad[i]));
            resolver.verifyAddrBtc(node, "n1", abi.encodePacked(bad[i], rs), G64);
        }
        // recovery ids 2 and 3 (headers 33, 34, 41, 42) are unreachable through ecrecover
        uint8[4] memory unreachable = [33, 34, 41, 42];
        for (uint256 i = 0; i < unreachable.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.BadRecoveryId.selector, unreachable[i]));
            resolver.verifyAddrBtc(node, "n1", abi.encodePacked(unreachable[i], rs), G64);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // ed25519
    // ---------------------------------------------------------------------------------------------

    bytes32 internal constant ED_PK = 0xd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a;

    function test_ed25519_disabled_by_default() public {
        vm.prank(alice);
        resolver.setAddr(node, 501, abi.encodePacked(ED_PK));
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.Ed25519Disabled.selector, 501));
        resolver.verifyAddrEd25519(node, 501, "n1", new bytes(64), ED_PK);
    }

    function test_ed25519_negative_paths_when_enabled() public {
        vm.startPrank(admin);
        resolver.setEd25519Enabled(501, true);
        resolver.setEd25519Enabled(5010000, true);
        resolver.setEd25519Enabled(60, true);
        vm.stopPrank();
        vm.prank(alice);
        resolver.setAddr(node, 501, abi.encodePacked(ED_PK));
        // unsupported coin type even when a governance flag exists for it
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.UnsupportedCoinType.selector, 60));
        resolver.verifyAddrEd25519(node, 60, "n1", new bytes(64), ED_PK);
        // bad signature length
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.BadSignatureLength.selector, 63));
        resolver.verifyAddrEd25519(node, 501, "n1", new bytes(63), ED_PK);
        // record mismatch: the record must be exactly the supplied key
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 501));
        resolver.verifyAddrEd25519(node, 501, "n1", new bytes(64), bytes32(uint256(ED_PK) ^ 1));
        // right record, invalid signature
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 501));
        resolver.verifyAddrEd25519(node, 501, "n1", new bytes(64), ED_PK);
        // no record
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.NoRecord.selector, node, 5010000));
        resolver.verifyAddrEd25519(node, 5010000, "n1", new bytes(64), ED_PK);
        assertFalse(resolver.verified(node, 501));
    }

    /// @dev Positive end-to-end proof. Forge cannot sign ed25519, so the signature was produced offline with
    ///      the RFC 8032 TEST 1 secret key over the exact challenge string asserted below (which depends on
    ///      this test's deterministic deployment: chain id 5042002, the handle node of "alice" at epoch 1 with
    ///      recordVersions 0, and the resolver address created in `setUp`). If the fixture changes, re-sign the
    ///      logged challenge with the TEST 1 secret key (any RFC 8032 implementation) and update both constants.
    function test_ed25519_happy_path_with_offline_signature() public {
        vm.chainId(5042002);
        vm.prank(admin);
        resolver.setEd25519Enabled(501, true);
        vm.prank(alice);
        resolver.setAddr(node, 501, abi.encodePacked(ED_PK));
        string memory c = resolver.challenge(node, 501, "rfc8032test1");
        emit log_string(c);
        assertEq(c, ED_CHALLENGE, "fixture drifted: re-sign the logged challenge");
        vm.expectEmit(true, false, false, true, address(resolver));
        emit AddressVerified(node, 501, uint8(IArcNSResolver.VerifyMethod.Ed25519));
        uint256 g = gasleft();
        resolver.verifyAddrEd25519(node, 501, "rfc8032test1", ED_SIG, ED_PK);
        emit log_named_uint("gas verifyAddrEd25519", g - gasleft());
        assertTrue(resolver.verified(node, 501));
        // same signature, other nonce ⇒ different message ⇒ rejected
        vm.expectRevert(abi.encodeWithSelector(IArcNSResolver.RecordMismatch.selector, node, 501));
        resolver.verifyAddrEd25519(node, 501, "rfc8032test2", ED_SIG, ED_PK);
    }

    string internal constant ED_CHALLENGE =
        "arcns:v1:rec:0x7873499bb0134d2d7985a9ca683e41ea711e844381416ce71245cbb89ae62ad6:501:0xa6eef7e35abe7026729641147f7915573c7e97b47efa546f5f6e3230263bcb49:5042002:0xa4ad4f68d0b91cfd19687c881e50f3a00242828c:rfc8032test1";
    bytes internal constant ED_SIG =
        hex"0abdadc099746afa23707aaf5019bb372bf7765cf166d88698400746160e3be0dad1df90b8eb69af943fba50fba7250b50c109188c9457dddbbf1ffa497e2106";
}
