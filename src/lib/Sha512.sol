// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Sha512 — pure-Solidity SHA-512 (FIPS 180-4 §6.4) over arbitrary byte strings
/// @notice Used by `Ed25519` (RFC 8032 needs SHA-512 for `k = H(R || A || M)`) and by nothing else.
///         The EVM has no SHA-512 precompile, so the compression function is written in Yul with
///         64-bit lanes carried in 256-bit words (masked after every add / rotate). Known-answer
///         tests: `test/kat/Sha512.t.sol` (NIST "", "abc", 56-byte and 112-byte vectors).
library Sha512 {
    /// @dev Round constants K[0..79]: first 64 bits of the fractional parts of the cube roots of the
    ///      first eighty primes (FIPS 180-4 §4.2.3), big-endian, 8 bytes each.
    bytes internal constant K = hex"428a2f98d728ae227137449123ef65cdb5c0fbcfec4d3b2fe9b5dba58189dbbc3956c25bf348b53859f111f1b605d019"
        hex"923f82a4af194f9bab1c5ed5da6d8118d807aa98a303024212835b0145706fbe243185be4ee4b28c550c7dc3d5ffb4e2"
        hex"72be5d74f27b896f80deb1fe3b1696b19bdc06a725c71235c19bf174cf692694e49b69c19ef14ad2efbe4786384f25e3"
        hex"0fc19dc68b8cd5b5240ca1cc77ac9c652de92c6f592b02754a7484aa6ea6e4835cb0a9dcbd41fbd476f988da831153b5"
        hex"983e5152ee66dfaba831c66d2db43210b00327c898fb213fbf597fc7beef0ee4c6e00bf33da88fc2d5a79147930aa725"
        hex"06ca6351e003826f142929670a0e6e7027b70a8546d22ffc2e1b21385c26c9264d2c6dfc5ac42aed53380d139d95b3df"
        hex"650a73548baf63de766a0abb3c77b2a881c2c92e47edaee692722c851482353ba2bfe8a14cf10364a81a664bbc423001"
        hex"c24b8b70d0f89791c76c51a30654be30d192e819d6ef5218d69906245565a910f40e35855771202a106aa07032bbd1b8"
        hex"19a4c116b8d2d0c81e376c085141ab532748774cdf8eeb9934b0bcb5e19b48a8391c0cb3c5c95a634ed8aa4ae3418acb"
        hex"5b9cca4f7763e373682e6ff3d6b2b8a3748f82ee5defb2fc78a5636f43172f6084c87814a1f0ab728cc702081a6439ec"
        hex"90befffa23631e28a4506cebde82bde9bef9a3f7b2c67915c67178f2e372532bca273eceea26619cd186b8c721c0c207"
        hex"eada7dd6cde0eb1ef57d4f7fee6ed17806f067aa72176fba0a637dc5a2c898a6113f9804bef90dae1b710b35131c471b"
        hex"28db77f523047d8432caab7b40c724933c9ebe0a15c9bebc431d67c49c100d4c4cc5d4becb3e42b6597f299cfc657e2a"
        hex"5fcb6fab3ad6faec6c44198c4a475817";

    /// @notice SHA-512 of `data` as a 64-byte array (hex-friendly form used by the KATs).
    function hash(bytes memory data) internal pure returns (bytes memory out) {
        (bytes32 h0, bytes32 h1) = digest(data);
        out = abi.encodePacked(h0, h1);
    }

    /// @notice SHA-512 of `data` as two big-endian 32-byte words (`h0` = H0..H3, `h1` = H4..H7).
    function digest(bytes memory data) internal pure returns (bytes32 h0, bytes32 h1) {
        bytes memory k = K;
        uint256 len = data.length;
        // padding: 0x80, zeros, 128-bit big-endian bit length; total a multiple of 128 bytes
        uint256 padded = ((len + 17 + 127) >> 7) << 7;
        bytes memory buf = new bytes(padded);
        uint256 statePtr;
        uint256 wPtr;
        assembly ("memory-safe") {
            let dst := add(buf, 32)
            mcopy(dst, add(data, 32), len)
            mstore8(add(dst, len), 0x80)
            // bit length < 2^64 here (calldata bound), so it lives in the low 8 bytes of the last word
            let last := sub(add(dst, padded), 32)
            mstore(last, or(mload(last), mul(len, 8)))
            // scratch: 8 state words + 80 schedule words
            statePtr := mload(0x40)
            wPtr := add(statePtr, 0x100)
            mstore(0x40, add(wPtr, 0xa00))
            mstore(statePtr, 0x6a09e667f3bcc908)
            mstore(add(statePtr, 0x20), 0xbb67ae8584caa73b)
            mstore(add(statePtr, 0x40), 0x3c6ef372fe94f82b)
            mstore(add(statePtr, 0x60), 0xa54ff53a5f1d36f1)
            mstore(add(statePtr, 0x80), 0x510e527fade682d1)
            mstore(add(statePtr, 0xa0), 0x9b05688c2b3e6c1f)
            mstore(add(statePtr, 0xc0), 0x1f83d9abfb41bd6b)
            mstore(add(statePtr, 0xe0), 0x5be0cd19137e2179)
        }
        uint256 kPtr;
        assembly ("memory-safe") {
            kPtr := add(k, 32)
        }
        for (uint256 off = 0; off < padded; off += 128) {
            uint256 blockPtr;
            assembly ("memory-safe") {
                blockPtr := add(add(buf, 32), off)
            }
            _compress(statePtr, blockPtr, kPtr, wPtr);
        }
        assembly ("memory-safe") {
            h0 := or(
                or(shl(192, mload(statePtr)), shl(128, mload(add(statePtr, 0x20)))),
                or(shl(64, mload(add(statePtr, 0x40))), mload(add(statePtr, 0x60)))
            )
            h1 := or(
                or(shl(192, mload(add(statePtr, 0x80))), shl(128, mload(add(statePtr, 0xa0)))),
                or(shl(64, mload(add(statePtr, 0xc0))), mload(add(statePtr, 0xe0)))
            )
        }
    }

    /// @dev One 1024-bit block: message schedule + 80 rounds, state updated in place at `statePtr`.
    function _compress(uint256 statePtr, uint256 blockPtr, uint256 kPtr, uint256 wPtr) private pure {
        assembly ("memory-safe") {
            function rotr(x, n) -> r {
                r := and(or(shr(n, x), shl(sub(64, n), x)), 0xffffffffffffffff)
            }
            // message schedule
            {
                for { let t := 0 } lt(t, 16) { t := add(t, 1) } {
                    mstore(add(wPtr, mul(t, 32)), shr(192, mload(add(blockPtr, mul(t, 8)))))
                }
                for { let t := 16 } lt(t, 80) { t := add(t, 1) } {
                    let w2 := mload(add(wPtr, mul(sub(t, 2), 32)))
                    let w15 := mload(add(wPtr, mul(sub(t, 15), 32)))
                    let s1 := xor(xor(rotr(w2, 19), rotr(w2, 61)), shr(6, w2))
                    let s0 := xor(xor(rotr(w15, 1), rotr(w15, 8)), shr(7, w15))
                    mstore(
                        add(wPtr, mul(t, 32)),
                        and(
                            add(
                                add(s1, mload(add(wPtr, mul(sub(t, 7), 32)))),
                                add(s0, mload(add(wPtr, mul(sub(t, 16), 32))))
                            ),
                            0xffffffffffffffff
                        )
                    )
                }
            }
            let a := mload(statePtr)
            let b := mload(add(statePtr, 0x20))
            let c := mload(add(statePtr, 0x40))
            let d := mload(add(statePtr, 0x60))
            let e := mload(add(statePtr, 0x80))
            let f := mload(add(statePtr, 0xa0))
            let g := mload(add(statePtr, 0xc0))
            let h := mload(add(statePtr, 0xe0))
            for { let t := 0 } lt(t, 80) { t := add(t, 1) } {
                let t1 :=
                    add(
                        add(h, xor(xor(rotr(e, 14), rotr(e, 18)), rotr(e, 41))),
                        add(
                            xor(and(e, f), and(not(e), g)),
                            add(shr(192, mload(add(kPtr, mul(t, 8)))), mload(add(wPtr, mul(t, 32))))
                        )
                    )
                let t2 :=
                    add(xor(xor(rotr(a, 28), rotr(a, 34)), rotr(a, 39)), xor(xor(and(a, b), and(a, c)), and(b, c)))
                h := g
                g := f
                f := e
                e := and(add(d, t1), 0xffffffffffffffff)
                d := c
                c := b
                b := a
                a := and(add(t1, t2), 0xffffffffffffffff)
            }
            mstore(statePtr, and(add(mload(statePtr), a), 0xffffffffffffffff))
            mstore(add(statePtr, 0x20), and(add(mload(add(statePtr, 0x20)), b), 0xffffffffffffffff))
            mstore(add(statePtr, 0x40), and(add(mload(add(statePtr, 0x40)), c), 0xffffffffffffffff))
            mstore(add(statePtr, 0x60), and(add(mload(add(statePtr, 0x60)), d), 0xffffffffffffffff))
            mstore(add(statePtr, 0x80), and(add(mload(add(statePtr, 0x80)), e), 0xffffffffffffffff))
            mstore(add(statePtr, 0xa0), and(add(mload(add(statePtr, 0xa0)), f), 0xffffffffffffffff))
            mstore(add(statePtr, 0xc0), and(add(mload(add(statePtr, 0xc0)), g), 0xffffffffffffffff))
            mstore(add(statePtr, 0xe0), and(add(mload(add(statePtr, 0xe0)), h), 0xffffffffffffffff))
        }
    }
}
