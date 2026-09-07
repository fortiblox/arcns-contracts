// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title BtcMessage — Bitcoin "Signed Message" digest and scriptPubKey derivation (BIP-137 support)
/// @notice Port of `x1-handles/programs/x1-handles/src/btc.rs` (`compact_size`, `message_digest`,
///         `compress_pubkey`, `hash160`) for `ArcNSResolver.verifyAddrBtc`. On EVM the record is the
///         ENSIP-9 scriptPubKey bytes, so the address string derivation (base58 / bech32) is replaced by
///         building the script directly: P2PKH `76a914<hash160>88ac`, P2WPKH `0014<hash160>`.
library BtcMessage {
    /// @dev The fixed magic every Bitcoin-signed-message digest is built from (24 bytes).
    bytes internal constant MAGIC = "Bitcoin Signed Message:\n";

    /// @notice Bitcoin `CompactSize` varint of `len` (btc.rs `compact_size`).
    function compactSize(uint256 len) internal pure returns (bytes memory) {
        if (len < 0xfd) return abi.encodePacked(uint8(len));
        if (len <= 0xffff) return abi.encodePacked(uint8(0xfd), _le2(uint16(len)));
        if (len <= 0xffffffff) return abi.encodePacked(uint8(0xfe), _le4(uint32(len)));
        return abi.encodePacked(uint8(0xff), _le8(uint64(len)));
    }

    /// @notice `SHA256(SHA256(varint(24) || magic || varint(len(msg)) || msg))` — what `signmessage` signs.
    function digest(bytes memory message) internal pure returns (bytes32) {
        bytes memory framed = abi.encodePacked(compactSize(MAGIC.length), MAGIC, compactSize(message.length), message);
        return sha256(abi.encodePacked(sha256(framed)));
    }

    /// @notice SEC1 compressed form of a 64-byte (X || Y) public key: `(0x02 | (Y & 1)) || X`.
    function compress(bytes memory pubkey64) internal pure returns (bytes memory out) {
        require(pubkey64.length == 64, "BtcMessage: pubkey must be 64 bytes");
        bytes32 x;
        assembly ("memory-safe") {
            x := mload(add(pubkey64, 32))
        }
        uint8 prefix = (uint8(pubkey64[63]) & 1) == 1 ? 0x03 : 0x02;
        out = abi.encodePacked(prefix, x);
    }

    /// @notice Bitcoin `HASH160` = `RIPEMD160(SHA256(data))`.
    function hash160(bytes memory data) internal pure returns (bytes20) {
        return ripemd160(abi.encodePacked(sha256(data)));
    }

    /// @notice P2PKH scriptPubKey: `OP_DUP OP_HASH160 <20> h160 OP_EQUALVERIFY OP_CHECKSIG` (25 bytes).
    function p2pkhScript(bytes20 h160) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"76a914", h160, hex"88ac");
    }

    /// @notice P2WPKH (witness v0) scriptPubKey: `OP_0 <20> h160` (22 bytes).
    function p2wpkhScript(bytes20 h160) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"0014", h160);
    }

    function _le2(uint16 v) private pure returns (bytes2) {
        return bytes2(uint16((v << 8) | (v >> 8)));
    }

    function _le4(uint32 v) private pure returns (bytes4) {
        uint32 r = ((v & 0xff) << 24) | ((v & 0xff00) << 8) | ((v >> 8) & 0xff00) | (v >> 24);
        return bytes4(r);
    }

    function _le8(uint64 v) private pure returns (bytes8) {
        uint256 r;
        for (uint256 i = 0; i < 8; i++) {
            r |= ((uint256(v) >> (8 * i)) & 0xff) << (8 * (7 - i));
        }
        return bytes8(uint64(r));
    }
}
