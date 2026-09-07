// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Sha512} from "./Sha512.sol";

/// @title Ed25519 — RFC 8032 §5.1.7 signature verification in pure Solidity (strict)
/// @notice Verification rules (SR-40):
///         - `s` must be canonical: `s < L` (rejects the classic `s + L` malleability forgery);
///         - `R` and `A` must be canonical encodings (`y < p`) of points on the curve; the RFC
///           decompression is applied to both and any failure rejects;
///         - the equation is checked **cofactorless**: `[s]B == R + [k]A` exactly, i.e. no
///           multiplication by 8. This is the stricter of the two RFC-permitted variants; a
///           signature that only passes with the cofactor cleared is rejected here.
///         Field inversions and the decompression square root go through the modexp precompile
///         (0x05), hence `view`; points use extended twisted-Edwards coordinates (X, Y, Z, T) with
///         the "hwcd-3" unified addition and "hwcd" doubling formulas from RFC 8032 §5.1.4.
///         `[s]B - [k]A` is computed with one interleaved (Shamir) double-and-add ladder over the
///         253-bit scalars and compared with `R` in compressed form.
library Ed25519 {
    uint256 internal constant P = 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed;
    uint256 internal constant L = 0x1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed;
    /// @dev d = -121665 / 121666 mod p
    uint256 internal constant D = 37095705934669439343138083508754565189542113879843219016388785533085940283555;
    /// @dev 2d mod p
    uint256 internal constant D2 = 16295367250680780974490674513165176452449235426866156013048779062215315747161;
    /// @dev sqrt(-1) = 2^((p-1)/4) mod p
    uint256 internal constant SQRT_M1 = 19681161376707505956807079304988542015446066515923890162744021073123829784752;
    /// @dev Base point B (x, y), y = 4/5.
    uint256 internal constant BX = 15112221349535400772501151409588531511454012693041857206046113283949847762202;
    uint256 internal constant BY = 46316835694926478169428394003475163141307993866256225615783033603165251855960;
    /// @dev 2^256 mod L, used to reduce the 512-bit hash output.
    uint256 internal constant TWO256_MOD_L =
        7237005577332262213973186563042994240413239274941949949428319933631315875101;
    /// @dev (p - 5) / 8, the decompression exponent.
    uint256 internal constant SQRT_EXP = 7237005577332262213973186563042994240829374041602535252466099000494570602493;

    /// @notice Verify `signature` (R || s, 64 bytes) over `message` under `publicKey` (32 bytes, LE).
    /// @return ok true iff the signature is valid under the strict rules above; never reverts on
    ///         malformed input except when `signature.length != 64`.
    function verify(bytes32 publicKey, bytes memory signature, bytes memory message) public view returns (bool ok) {
        require(signature.length == 64, "Ed25519: bad signature length");
        bytes32 rBytes;
        bytes32 sBytes;
        assembly ("memory-safe") {
            rBytes := mload(add(signature, 32))
            sBytes := mload(add(signature, 64))
        }
        uint256 s = _fromLe(uint256(sBytes));
        if (s >= L) return false;

        uint256[4] memory a = _alloc();
        if (!_decompress(publicKey, a)) return false;
        uint256[4] memory r = _alloc();
        if (!_decompress(rBytes, r)) return false;

        // k = SHA-512(R || A || M) mod L
        uint256 k;
        {
            (bytes32 h0, bytes32 h1) = Sha512.digest(abi.encodePacked(rBytes, publicKey, message));
            uint256 lo = _fromLe(uint256(h0));
            uint256 hi = _fromLe(uint256(h1));
            k = addmod(lo % L, mulmod(hi % L, TWO256_MOD_L, L), L);
        }

        // negate A: (-x, y, z, -t)
        a[0] = a[0] == 0 ? 0 : P - a[0];
        a[3] = a[3] == 0 ? 0 : P - a[3];

        uint256[4] memory b = _alloc();
        b[0] = BX;
        b[1] = BY;
        b[2] = 1;
        b[3] = mulmod(BX, BY, P);
        uint256[4] memory ba = _alloc();
        _add(b, a, ba);

        // acc = [s]B + [k](-A), interleaved ladder from bit 252 down
        uint256[4] memory acc = _alloc();
        acc[1] = 1;
        acc[2] = 1;
        bool started;
        for (uint256 i = 253; i > 0;) {
            unchecked {
                --i;
            }
            if (started) _double(acc);
            uint256 bs = (s >> i) & 1;
            uint256 bk = (k >> i) & 1;
            if (bs == 1 && bk == 1) {
                _add(acc, ba, acc);
                started = true;
            } else if (bs == 1) {
                _add(acc, b, acc);
                started = true;
            } else if (bk == 1) {
                _add(acc, a, acc);
                started = true;
            }
        }
        return _compress(acc) == rBytes;
    }

    // ---------------------------------------------------------------------------------------------
    // encoding
    // ---------------------------------------------------------------------------------------------

    /// @dev Reinterpret a 32-byte word as a little-endian integer (byte reversal).
    function _fromLe(uint256 v) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            v := or(
                shr(8, and(v, 0xFF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00)),
                shl(8, and(v, 0x00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF))
            )
            v := or(
                shr(16, and(v, 0xFFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000)),
                shl(16, and(v, 0x0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF))
            )
            v := or(
                shr(32, and(v, 0xFFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000)),
                shl(32, and(v, 0x00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF))
            )
            v := or(
                shr(64, and(v, 0xFFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFF0000000000000000)),
                shl(64, and(v, 0x0000000000000000FFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFF))
            )
            r := or(shr(128, v), shl(128, v))
        }
    }

    /// @dev Decode a compressed point (32 bytes LE, sign bit in the top bit) into extended coordinates.
    ///      Returns false for `y >= p`, off-curve, or `x == 0` with the sign bit set (RFC 8032 §5.1.3).
    function _decompress(bytes32 enc, uint256[4] memory out) internal view returns (bool) {
        uint256 y = _fromLe(uint256(enc));
        uint256 sign = y >> 255;
        y &= (1 << 255) - 1;
        if (y >= P) return false;
        uint256 y2 = mulmod(y, y, P);
        uint256 u = addmod(y2, P - 1, P);
        uint256 v = addmod(mulmod(D, y2, P), 1, P);
        // x = u v^3 (u v^7)^((p-5)/8)
        uint256 v3 = mulmod(mulmod(v, v, P), v, P);
        uint256 x = mulmod(mulmod(u, v3, P), _modexp(mulmod(mulmod(u, v3, P), mulmod(v3, v, P), P), SQRT_EXP), P);
        uint256 vx2 = mulmod(v, mulmod(x, x, P), P);
        if (vx2 != u) {
            if (vx2 != P - u) return false;
            x = mulmod(x, SQRT_M1, P);
        }
        if (x == 0 && sign == 1) return false;
        if ((x & 1) != sign) x = P - x;
        out[0] = x;
        out[1] = y;
        out[2] = 1;
        out[3] = mulmod(x, y, P);
        return true;
    }

    /// @dev Compress an extended point to the 32-byte LE encoding with the x-parity in the top bit.
    function _compress(uint256[4] memory p) internal view returns (bytes32) {
        uint256 zinv = _modexp(p[2], P - 2);
        uint256 x = mulmod(p[0], zinv, P);
        uint256 y = mulmod(p[1], zinv, P);
        return bytes32(_fromLe(y | ((x & 1) << 255)));
    }

    /// @dev `base ^ exp mod p` through the modexp precompile.
    function _modexp(uint256 base, uint256 exponent) internal view returns (uint256 result) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x20)
            mstore(add(ptr, 0x20), 0x20)
            mstore(add(ptr, 0x40), 0x20)
            mstore(add(ptr, 0x60), base)
            mstore(add(ptr, 0x80), exponent)
            mstore(add(ptr, 0xa0), P)
            if iszero(staticcall(gas(), 0x05, ptr, 0xc0, ptr, 0x20)) { revert(0, 0) }
            result := mload(ptr)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // group law (extended twisted Edwards, a = -1)
    // ---------------------------------------------------------------------------------------------

    function _alloc() private pure returns (uint256[4] memory p) {
        return p;
    }

    /// @dev out = p + q (RFC 8032 §5.1.4, "add-2008-hwcd-3"); `out` may alias `p`.
    function _add(uint256[4] memory p, uint256[4] memory q, uint256[4] memory out) internal pure {
        assembly ("memory-safe") {
            let pp := 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed
            let x1 := mload(p)
            let y1 := mload(add(p, 0x20))
            let x2 := mload(q)
            let y2 := mload(add(q, 0x20))
            // A = (Y1 - X1) * (Y2 - X2); B = (Y1 + X1) * (Y2 + X2)
            let aa := mulmod(addmod(y1, sub(pp, x1), pp), addmod(y2, sub(pp, x2), pp), pp)
            let bb := mulmod(addmod(y1, x1, pp), addmod(y2, x2, pp), pp)
            // C = T1 * 2d * T2; D = Z1 * 2 * Z2
            let cc :=
                mulmod(
                    mulmod(mload(add(p, 0x60)), mload(add(q, 0x60)), pp),
                    16295367250680780974490674513165176452449235426866156013048779062215315747161,
                    pp
                )
            let dd := mulmod(mulmod(mload(add(p, 0x40)), mload(add(q, 0x40)), pp), 2, pp)
            // E = B - A; F = D - C; G = D + C; H = B + A
            let e := addmod(bb, sub(pp, aa), pp)
            let f := addmod(dd, sub(pp, cc), pp)
            let g := addmod(dd, cc, pp)
            let h := addmod(bb, aa, pp)
            mstore(out, mulmod(e, f, pp))
            mstore(add(out, 0x20), mulmod(g, h, pp))
            mstore(add(out, 0x40), mulmod(f, g, pp))
            mstore(add(out, 0x60), mulmod(e, h, pp))
        }
    }

    /// @dev p = 2p in place (RFC 8032 §5.1.4, "dbl-2008-hwcd").
    function _double(uint256[4] memory p) internal pure {
        assembly ("memory-safe") {
            let pp := 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed
            let x1 := mload(p)
            let y1 := mload(add(p, 0x20))
            let z1 := mload(add(p, 0x40))
            // A = X1^2; B = Y1^2; C = 2 Z1^2; H = A + B; E = H - (X1 + Y1)^2; G = A - B; F = C + G
            let aa := mulmod(x1, x1, pp)
            let bb := mulmod(y1, y1, pp)
            let cc := mulmod(mulmod(z1, z1, pp), 2, pp)
            let h := addmod(aa, bb, pp)
            let xy := addmod(x1, y1, pp)
            let e := addmod(h, sub(pp, mulmod(xy, xy, pp)), pp)
            let g := addmod(aa, sub(pp, bb), pp)
            let f := addmod(cc, g, pp)
            mstore(p, mulmod(e, f, pp))
            mstore(add(p, 0x20), mulmod(g, h, pp))
            mstore(add(p, 0x40), mulmod(f, g, pp))
            mstore(add(p, 0x60), mulmod(e, h, pp))
        }
    }
}
