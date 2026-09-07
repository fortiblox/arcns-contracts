// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ENSIP19, COIN_TYPE_ETH} from "@ensdomains/ens-contracts/utils/ENSIP19.sol";
import {IArcNSResolver} from "../interfaces/IArcNSResolver.sol";
import {ArcNSConstants} from "../lib/ArcNSConstants.sol";
import {Challenge} from "../lib/Challenge.sol";
import {BtcMessage} from "../lib/BtcMessage.sol";
import {Ed25519} from "../lib/Ed25519.sol";
import {AddrResolverV} from "./profiles/AddrResolverV.sol";

/// @title VerifiedAddrResolver — X1 `Record.verified` on top of the ENSIP-9 address profile
/// @notice Port of x1-handles `verify_record_eth` / `verify_record_svm` / `verify_record_btc` (port-map rows
///         21–23, onchain-design §5). The flag lives under the same version key as the record, so an ownership
///         change (or `clearRecords`) makes it unreachable together with the record; any `setAddr` clears it
///         (X1 `update_record` rule). Every proof binds the current version key, so a proof captured under a
///         previous owner never validates for the next one (x1-handles#111):
///         - EVM signers (secp256k1 EOAs, ERC-1271 wallets) sign EIP-712 typed data (SR-41): domain
///           {name:"arcns", version:"1", chainId, verifyingContract = this resolver}, struct
///           `RecordProof(bytes32 node,uint256 coinType,bytes32 version,string nonce)` with
///           `version = versionOf(node)`. The namespace is bound through `node` because one resolver serves all
///           namespaces. `recordProofDigest` is the exact digest to sign; the SDK mirrors it (test/kat/RecordProof).
///         - non-EVM signers (BTC BIP-137, ed25519) sign the SR-41 challenge string from `challenge(...)`.
abstract contract VerifiedAddrResolver is AddrResolverV, IArcNSResolver, EIP712 {
    /// @inheritdoc IArcNSResolver
    bytes32 public constant override RECORD_PROOF_TYPEHASH =
        keccak256("RecordProof(bytes32 node,uint256 coinType,bytes32 version,string nonce)");

    struct Verification {
        bool verified;
        uint64 verifiedAt;
    }

    /// @dev versionKey => node => coinType => verification
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => Verification))) internal _verifications;

    /// @inheritdoc IArcNSResolver
    mapping(uint256 => bool) public override ed25519Enabled;

    constructor() EIP712("arcns", "1") {}

    // ---------------------------------------------------------------------------------------------
    // record write hook
    // ---------------------------------------------------------------------------------------------

    /// @dev Every address write drops the verified flag of that (node, coinType) at the current version. Same
    ///      body as `AddrResolverV.setAddr` (events verbatim) with the version key computed once.
    function setAddr(bytes32 node, uint256 coinType, bytes memory addressBytes)
        public
        virtual
        override
        authorised(node)
    {
        if (addressBytes.length != 0 && addressBytes.length != 20 && ENSIP19.isEVMCoinType(coinType)) {
            revert InvalidEVMAddress(addressBytes);
        }
        emit AddressChanged(node, coinType, addressBytes);
        if (coinType == COIN_TYPE_ETH) {
            emit AddrChanged(node, address(bytes20(addressBytes)));
        }
        bytes32 key = _versionOf(node);
        delete _verifications[key][node][coinType];
        versionable_addresses[key][node][coinType] = addressBytes;
    }

    // ---------------------------------------------------------------------------------------------
    // views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSResolver
    function verified(bytes32 node, uint256 coinType) public view override returns (bool) {
        return _verifications[_versionOf(node)][node][coinType].verified;
    }

    /// @inheritdoc IArcNSResolver
    function verifiedAt(bytes32 node, uint256 coinType) public view override returns (uint64) {
        return _verifications[_versionOf(node)][node][coinType].verifiedAt;
    }

    /// @inheritdoc IArcNSResolver
    function challenge(bytes32 node, uint256 coinType, string calldata nonce)
        public
        view
        override
        returns (string memory)
    {
        return Challenge.build(node, coinType, _versionOf(node), block.chainid, address(this), nonce);
    }

    /// @inheritdoc IArcNSResolver
    function recordProofDigest(bytes32 node, uint256 coinType, string calldata nonce)
        public
        view
        override
        returns (bytes32)
    {
        return _recordProofDigest(node, coinType, _versionOf(node), nonce);
    }

    // ---------------------------------------------------------------------------------------------
    // proofs
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSResolver
    function verifyAddrSelf(bytes32 node, uint256 coinType) external override {
        if (coinType != ArcNSConstants.evmCoinType()) revert UnsupportedCoinType(coinType);
        (bytes32 key, bytes memory record) = _liveRecord(node, coinType);
        if (record.length != 20 || address(bytes20(record)) != msg.sender) revert RecordMismatch(node, coinType);
        _setVerified(key, node, coinType, VerifyMethod.Self);
    }

    /// @inheritdoc IArcNSResolver
    function verifyAddrSelf1271(bytes32 node, uint256 coinType, string calldata nonce, bytes calldata signature)
        external
        override
    {
        if (coinType != ArcNSConstants.evmCoinType()) revert UnsupportedCoinType(coinType);
        (bytes32 key, bytes memory record) = _liveRecord(node, coinType);
        if (record.length != 20) revert RecordMismatch(node, coinType);
        bytes32 digest = _recordProofDigest(node, coinType, key, nonce);
        if (!SignatureChecker.isValidSignatureNow(address(bytes20(record)), digest, signature)) {
            revert RecordMismatch(node, coinType);
        }
        _setVerified(key, node, coinType, VerifyMethod.Self);
    }

    /// @inheritdoc IArcNSResolver
    function verifyAddrSecp256k1(bytes32 node, uint256 coinType, string calldata nonce, bytes calldata signature)
        external
        override
    {
        if (coinType != COIN_TYPE_ETH && !ENSIP19.isEVMCoinType(coinType)) revert UnsupportedCoinType(coinType);
        (bytes32 key, bytes memory record) = _liveRecord(node, coinType);
        if (record.length != 20) revert RecordMismatch(node, coinType);
        bytes32 digest = _recordProofDigest(node, coinType, key, nonce);
        // OZ ECDSA rejects high-s and v not in {27, 28} (T-SIG-1) and reverts on a malformed signature.
        if (ECDSA.recover(digest, signature) != address(bytes20(record))) revert RecordMismatch(node, coinType);
        _setVerified(key, node, coinType, VerifyMethod.Secp256k1);
    }

    /// @inheritdoc IArcNSResolver
    function verifyAddrBtc(bytes32 node, string calldata nonce, bytes calldata signature65, bytes calldata pubkey64)
        external
        override
    {
        if (signature65.length != 65) revert BadSignatureLength(signature65.length);
        if (pubkey64.length != 64) revert BadPublicKey();
        (bool segwit, uint8 recid) = _btcHeader(uint8(signature65[0]));
        (bytes32 key, bytes memory record) = _liveRecord(node, ArcNSConstants.COIN_TYPE_BTC);
        _checkBtcSigner(node, key, nonce, signature65, recid, pubkey64);
        bytes20 h160 = BtcMessage.hash160(BtcMessage.compress(pubkey64));
        bytes memory script = segwit ? BtcMessage.p2wpkhScript(h160) : BtcMessage.p2pkhScript(h160);
        if (keccak256(record) != keccak256(script)) revert RecordMismatch(node, ArcNSConstants.COIN_TYPE_BTC);
        _setVerified(key, node, ArcNSConstants.COIN_TYPE_BTC, VerifyMethod.Bitcoin);
    }

    /// @dev BIP-137 header byte routing (btc.rs): 31..34 compressed P2PKH, 39..42 P2WPKH; 27..30 (uncompressed
    ///      P2PKH) and 35..38 (P2SH-segwit) are refused, anything else is not a BIP-137 header at all. Recovery
    ///      ids 2 and 3 are unreachable through `ecrecover`, so they are refused as `BadRecoveryId` too.
    function _btcHeader(uint8 header) internal pure returns (bool segwit, uint8 recid) {
        if (header >= 31 && header <= 34) {
            recid = header - 31;
        } else if (header >= 39 && header <= 42) {
            recid = header - 39;
            segwit = true;
        } else if ((header >= 27 && header <= 30) || (header >= 35 && header <= 38)) {
            revert UnsupportedBtcAddressType(header);
        } else {
            revert BadRecoveryId(header);
        }
        if (recid > 1) revert BadRecoveryId(header);
    }

    /// @dev The recovered signer of the Bitcoin-framed challenge digest must be the supplied 64-byte pubkey.
    function _checkBtcSigner(
        bytes32 node,
        bytes32 key,
        string calldata nonce,
        bytes calldata signature65,
        uint8 recid,
        bytes calldata pubkey64
    ) internal view {
        bytes32 digest = BtcMessage.digest(bytes(_challengeFor(node, ArcNSConstants.COIN_TYPE_BTC, key, nonce)));
        address signer = ECDSA.recover(digest, 27 + recid, bytes32(signature65[1:33]), bytes32(signature65[33:65]));
        if (signer != address(uint160(uint256(keccak256(pubkey64))))) revert BadPublicKey();
    }

    /// @inheritdoc IArcNSResolver
    function verifyAddrEd25519(
        bytes32 node,
        uint256 coinType,
        string calldata nonce,
        bytes calldata signature64,
        bytes32 publicKey
    ) external override {
        if (!ed25519Enabled[coinType]) revert Ed25519Disabled(coinType);
        if (coinType != ArcNSConstants.COIN_TYPE_SOL && coinType != ArcNSConstants.COIN_TYPE_X1) {
            revert UnsupportedCoinType(coinType);
        }
        if (signature64.length != 64) revert BadSignatureLength(signature64.length);
        (bytes32 key, bytes memory record) = _liveRecord(node, coinType);
        if (record.length != 32 || bytes32(record) != publicKey) revert RecordMismatch(node, coinType);
        bytes memory message = bytes(_challengeFor(node, coinType, key, nonce));
        if (!Ed25519.verify(publicKey, signature64, message)) revert RecordMismatch(node, coinType);
        _setVerified(key, node, coinType, VerifyMethod.Ed25519);
    }

    // ---------------------------------------------------------------------------------------------
    // internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Hook: revert when `node` may not carry records right now (retired TLD). Default: no-op.
    function _checkResolvableNode(bytes32 node) internal view virtual {}

    /// @dev Current version key and the raw stored record (no EVM-default fallback) for (node, coinType).
    function _liveRecord(bytes32 node, uint256 coinType) internal view returns (bytes32 key, bytes memory record) {
        _checkResolvableNode(node);
        key = _versionOf(node);
        record = versionable_addresses[key][node][coinType];
        if (record.length == 0) revert NoRecord(node, coinType);
    }

    function _challengeFor(bytes32 node, uint256 coinType, bytes32 key, string calldata nonce)
        internal
        view
        returns (string memory)
    {
        return Challenge.build(node, coinType, key, block.chainid, address(this), nonce);
    }

    /// @dev EIP-712 digest of RecordProof{node, coinType, version = key, nonce}; nonce rules as for the challenge.
    function _recordProofDigest(bytes32 node, uint256 coinType, bytes32 key, string calldata nonce)
        internal
        view
        returns (bytes32)
    {
        if (!Challenge.isValidNonce(nonce)) revert BadNonce(nonce);
        return
            _hashTypedDataV4(keccak256(abi.encode(RECORD_PROOF_TYPEHASH, node, coinType, key, keccak256(bytes(nonce)))));
    }

    function _setVerified(bytes32 key, bytes32 node, uint256 coinType, VerifyMethod method) internal {
        _verifications[key][node][coinType] = Verification({verified: true, verifiedAt: uint64(block.timestamp)});
        emit AddressVerified(node, coinType, uint8(method));
    }

    function _setEd25519Enabled(uint256 coinType, bool enabled) internal {
        ed25519Enabled[coinType] = enabled;
        emit Ed25519Enabled(coinType, enabled);
    }
}
