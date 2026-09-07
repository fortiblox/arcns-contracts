// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IArcNSResolver} from "../interfaces/IArcNSResolver.sol";

/// @title Challenge — the exact bytes a wallet signs to prove it controls an address record (SR-41)
/// @notice `arcns:v1:rec:<0x-node-hex>:<coinType decimal>:<0x-versionKey-hex>:<chainId decimal>:<0x-resolver-hex-lowercase>:<nonce>`
///         Every field is load-bearing (port of `x1-handles/crates/handle-normalize/src/challenge.rs`):
///         the protocol tag separates us from other products signing with the same key, `rec` is the
///         purpose (control proofs use `ctl`, so the two spaces are disjoint by construction), the node
///         and coin type bind the proof to one record, `versionKey` binds it to the current ownership
///         epoch (a transfer changes it, so no historical signature can ever satisfy a later challenge —
///         x1-handles#111), chain id + resolver address stop cross-deployment replay, and the nonce is
///         server-issued. No segment may contain `:`: the hex/decimal fields cannot, and the nonce is
///         restricted to ASCII alphanumerics (1..64 bytes) so it cannot smuggle a separator either.
///         Pure so the SDK KAT (`test/kat/Challenge.t.sol`) can mirror it byte for byte.
library Challenge {
    string internal constant PREFIX = "arcns:v1:rec:";
    uint256 internal constant MAX_NONCE_LEN = 64;

    /// @notice true iff `nonce` is 1..64 ASCII alphanumeric bytes.
    function isValidNonce(string memory nonce) internal pure returns (bool) {
        bytes memory b = bytes(nonce);
        if (b.length == 0 || b.length > MAX_NONCE_LEN) return false;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            bool ok = (c >= "0" && c <= "9") || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z");
            if (!ok) return false;
        }
        return true;
    }

    /// @notice Build the challenge string; reverts `BadNonce` when the nonce is not alphanumeric 1..64.
    function build(
        bytes32 node,
        uint256 coinType,
        bytes32 versionKey,
        uint256 chainId,
        address resolver,
        string memory nonce
    ) internal pure returns (string memory) {
        if (!isValidNonce(nonce)) revert IArcNSResolver.BadNonce(nonce);
        return string(
            abi.encodePacked(
                PREFIX,
                Strings.toHexString(uint256(node), 32),
                ":",
                Strings.toString(coinType),
                ":",
                Strings.toHexString(uint256(versionKey), 32),
                ":",
                Strings.toString(chainId),
                ":",
                Strings.toHexString(resolver),
                ":",
                nonce
            )
        );
    }
}
