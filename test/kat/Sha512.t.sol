// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Sha512} from "../../src/lib/Sha512.sol";

/// @notice FIPS 180-4 / NIST CAVP known-answer tests for the pure-Solidity SHA-512.
contract Sha512KatTest is Test {
    function _hex(bytes memory b) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory s = new bytes(b.length * 2);
        for (uint256 i = 0; i < b.length; i++) {
            s[2 * i] = alphabet[uint8(b[i]) >> 4];
            s[2 * i + 1] = alphabet[uint8(b[i]) & 0x0f];
        }
        return string(s);
    }

    function test_kat_empty() public pure {
        assertEq(
            _hex(Sha512.hash("")),
            "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
        );
    }

    function test_kat_abc() public pure {
        assertEq(
            _hex(Sha512.hash("abc")),
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        );
    }

    /// @dev NIST 56-byte vector: 56 + 17 <= 128, so it still fits one block (the 112-byte one below needs two).
    function test_kat_56_bytes() public pure {
        assertEq(
            _hex(Sha512.hash("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
            "204a8fc6dda82f0a0ced7beb8e08a41657c16ef468b228a8279be331a703c33596fd15c13b1b07f9aa1d3bea57789ca031ad85c7a71dd70354ec631238ca3445"
        );
    }

    /// @dev NIST 112-byte vector: two compression blocks (112 + 17 > 128).
    function test_kat_112_bytes() public pure {
        assertEq(
            _hex(
                Sha512.hash(
                    "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
                )
            ),
            "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909"
        );
    }

    /// @dev Exactly one byte short of the single-block boundary (111 bytes) and exactly at it (112, 128).
    function test_kat_boundaries() public pure {
        bytes memory m111 = new bytes(111);
        bytes memory m112 = new bytes(112);
        bytes memory m128 = new bytes(128);
        for (uint256 i = 0; i < 128; i++) {
            if (i < 111) m111[i] = "a";
            if (i < 112) m112[i] = "a";
            m128[i] = "a";
        }
        assertEq(
            _hex(Sha512.hash(m111)),
            "fa9121c7b32b9e01733d034cfc78cbf67f926c7ed83e82200ef86818196921760b4beff48404df811b953828274461673c68d04e297b0eb7b2b4d60fc6b566a2"
        );
        assertEq(
            _hex(Sha512.hash(m112)),
            "c01d080efd492776a1c43bd23dd99d0a2e626d481e16782e75d54c2503b5dc32bd05f0f1ba33e568b88fd2d970929b719ecbb152f58f130a407c8830604b70ca"
        );
        assertEq(
            _hex(Sha512.hash(m128)),
            "b73d1929aa615934e61a871596b3f3b33359f42b8175602e89f7e06e5f658a243667807ed300314b95cacdd579f3e33abdfbe351909519a846d465c59582f321"
        );
    }

    function test_gas_two_blocks() public view {
        bytes memory m = new bytes(96);
        uint256 g = gasleft();
        Sha512.digest(m);
        uint256 used = g - gasleft();
        assertLt(used, 120_000);
    }
}
