// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Base64 decoder for asserting on fully on-chain `tokenURI` / `contractURI` payloads.
library Base64Decoder {
    bytes internal constant TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    /// @dev Strips a `data:...;base64,` prefix when present and decodes the remainder.
    function decodeDataUri(string memory uri) internal pure returns (bytes memory) {
        bytes memory b = bytes(uri);
        uint256 start = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") {
                start = i + 1;
                break;
            }
        }
        bytes memory payload = new bytes(b.length - start);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = b[start + i];
        }
        return decode(payload);
    }

    function decode(bytes memory data) internal pure returns (bytes memory) {
        if (data.length == 0) return "";
        require(data.length % 4 == 0, "base64: bad length");
        uint256 padding;
        if (data[data.length - 1] == "=") padding++;
        if (data[data.length - 2] == "=") padding++;
        bytes memory out = new bytes(data.length / 4 * 3 - padding);
        uint256 o;
        for (uint256 i = 0; i < data.length; i += 4) {
            uint256 chunk =
                (_val(data[i]) << 18) | (_val(data[i + 1]) << 12) | (_val(data[i + 2]) << 6) | _val(data[i + 3]);
            if (o < out.length) out[o++] = bytes1(uint8(chunk >> 16));
            if (o < out.length) out[o++] = bytes1(uint8(chunk >> 8));
            if (o < out.length) out[o++] = bytes1(uint8(chunk));
        }
        return out;
    }

    function _val(bytes1 c) private pure returns (uint256) {
        if (c == "=") return 0;
        for (uint256 i = 0; i < 64; i++) {
            if (TABLE[i] == c) return i;
        }
        revert("base64: bad char");
    }
}

/// @dev A treasury stand-in whose `receive` reverts (Arc blocklisted-address semantics).
contract RevertingReceiver {
    error Nope();

    receive() external payable {
        revert Nope();
    }
}

/// @dev A payer that can hold value and forward calls (to test the pull ledger with a contract payer).
contract ValueSink {
    receive() external payable {}
}
