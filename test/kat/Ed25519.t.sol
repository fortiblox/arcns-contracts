// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ed25519} from "../../src/lib/Ed25519.sol";

/// @notice RFC 8032 §7.1 known-answer tests plus forgeries and the gas budget for the strict verifier.
contract Ed25519KatTest is Test {
    // TEST 1
    bytes32 internal constant PK1 = 0xd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a;
    bytes internal constant SIG1 =
        hex"e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";
    // TEST 2
    bytes32 internal constant PK2 = 0x3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c;
    bytes internal constant SIG2 =
        hex"92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00";
    // TEST 3
    bytes32 internal constant PK3 = 0xfc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025;
    bytes internal constant SIG3 =
        hex"6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a";

    function test_rfc8032_test1_empty_message() public view {
        assertTrue(Ed25519.verify(PK1, SIG1, ""));
    }

    function test_rfc8032_test2_one_byte() public view {
        assertTrue(Ed25519.verify(PK2, SIG2, hex"72"));
    }

    function test_rfc8032_test3_two_bytes() public view {
        assertTrue(Ed25519.verify(PK3, SIG3, hex"af82"));
    }

    /// @dev s + L is the textbook malleability forgery: same R, s' = s + L verifies under a lax
    ///      verifier. Strict RFC 8032 rejects s >= L.
    function test_forgery_s_plus_L_rejected() public view {
        bytes memory sig = SIG1;
        uint256 s = _le(sig, 32);
        uint256 sPlusL = s + Ed25519.L;
        assertLt(sPlusL, type(uint256).max);
        _putLe(sig, 32, sPlusL);
        assertFalse(Ed25519.verify(PK1, sig, ""));
    }

    function test_forgery_flipped_bit_in_R_rejected() public view {
        bytes memory sig = SIG1;
        sig[3] ^= 0x01;
        assertFalse(Ed25519.verify(PK1, sig, ""));
    }

    function test_forgery_flipped_bit_in_s_rejected() public view {
        bytes memory sig = SIG2;
        sig[40] ^= 0x10;
        assertFalse(Ed25519.verify(PK2, sig, hex"72"));
    }

    function test_forgery_wrong_message_rejected() public view {
        assertFalse(Ed25519.verify(PK3, SIG3, hex"af83"));
        assertFalse(Ed25519.verify(PK3, SIG3, ""));
    }

    function test_forgery_wrong_key_rejected() public view {
        assertFalse(Ed25519.verify(PK2, SIG1, ""));
    }

    function test_non_canonical_public_key_rejected() public view {
        // y = p + 1 (>= p) is a non-canonical encoding of the point with y = 1
        bytes32 nonCanonical = 0xeeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f;
        assertFalse(Ed25519.verify(nonCanonical, SIG1, ""));
    }

    function test_off_curve_point_rejected() public view {
        // y = 2 is not the y-coordinate of any point on the curve
        bytes32 offCurve = 0x0200000000000000000000000000000000000000000000000000000000000000;
        assertFalse(Ed25519.verify(offCurve, SIG1, ""));
        bytes memory sig = SIG1;
        for (uint256 i = 0; i < 32; i++) {
            sig[i] = offCurve[i];
        }
        assertFalse(Ed25519.verify(PK1, sig, ""));
    }

    function test_bad_signature_length_reverts() public {
        vm.expectRevert(bytes("Ed25519: bad signature length"));
        this.callVerify(PK1, hex"00", "");
    }

    function callVerify(bytes32 pk, bytes calldata sig, bytes calldata msg_) external view returns (bool) {
        return Ed25519.verify(pk, sig, msg_);
    }

    function test_gas_verify_under_600k() public view {
        uint256 g = gasleft();
        bool ok = Ed25519.verify(PK3, SIG3, hex"af82");
        uint256 used = g - gasleft();
        assertTrue(ok);
        assertLe(used, 600_000);
    }

    function _le(bytes memory b, uint256 off) internal pure returns (uint256 v) {
        for (uint256 i = 0; i < 32; i++) {
            v |= uint256(uint8(b[off + i])) << (8 * i);
        }
    }

    function _putLe(bytes memory b, uint256 off, uint256 v) internal pure {
        for (uint256 i = 0; i < 32; i++) {
            b[off + i] = bytes1(uint8(v >> (8 * i)));
        }
    }
}
