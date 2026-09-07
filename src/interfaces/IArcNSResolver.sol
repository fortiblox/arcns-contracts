// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IArcNSResolver — the arcns-specific surface of C7 on top of the ENS profiles
/// @notice C7 also implements the ENS interfaces verbatim in ABI terms: ENSIP-9 `addr(bytes32,uint256)`
///         (`0xf1cb7e06`), legacy `addr(bytes32)` (`0x3b3b57de`), ENSIP-10 `resolve(bytes,bytes)`
///         (`0x9061b923`), `text`, `contenthash`, `name`, `multicall`, `clearRecords`,
///         `recordVersions`. Record storage is keyed by `versionOf(node)`, which changes on every
///         ownership change of the name (SR-12): for handle-namespace nodes it folds in
///         `HandleRegistry.epochOf`, for tagged TLD nodes the registrar's current `ownerOf`, for any
///         other node the ENS registry owner. Old records become unreachable structurally.
interface IArcNSResolver {
    /// @dev Proof methods for `AddressVerified.method`.
    enum VerifyMethod {
        Self, // msg.sender == record (EOA) or ERC-1271 (contract wallet) on this chain
        Secp256k1, // EIP-191 personal_sign over the challenge, ecrecover
        Bitcoin, // BIP-137 over the challenge; record is scriptPubKey bytes (P2PKH / P2WPKH)
        Ed25519 // RFC 8032 over the challenge; record is the 32-byte public key
    }

    event AddressVerified(bytes32 indexed node, uint256 coinType, uint8 method);
    event NodeTagged(bytes32 indexed node, bytes32 indexed tldNode, uint256 tokenId);
    event Ed25519Enabled(uint256 indexed coinType, bool enabled);

    error NotAuthorised(bytes32 node, address caller);
    error NotTldController(bytes32 tldNode, address caller);
    error NoRecord(bytes32 node, uint256 coinType);
    error RecordMismatch(bytes32 node, uint256 coinType);
    error BadNonce(string nonce);
    error UnsupportedCoinType(uint256 coinType);
    error Ed25519Disabled(uint256 coinType);
    error BadSignatureLength(uint256 length);
    error UnsupportedBtcAddressType(uint8 header);
    error BadRecoveryId(uint8 header);
    error BadPublicKey();
    error TldNotResolvable(bytes32 tldNode);

    // ---- node tagging (written by a TLD controller at registration, onchain-design §3.5)
    function tagNode(bytes32 node, bytes32 tldNode, uint256 tokenId) external;
    function tldOf(bytes32 node) external view returns (bytes32);
    function tokenIdOfNode(bytes32 node) external view returns (uint256);

    // ---- version / authority
    function versionOf(bytes32 node) external view returns (bytes32);
    function isAuthorisedFor(bytes32 node, address who) external view returns (bool);
    /// @notice namespace of a node: 0 = unknown/plain ENS, 1 = handle namespace (or sub-handle), 2 = TLD name
    function namespaceOf(bytes32 node) external view returns (uint8);

    // ---- verified flags (X1 `Record.verified`)
    function verified(bytes32 node, uint256 coinType) external view returns (bool);
    function verifiedAt(bytes32 node, uint256 coinType) external view returns (uint64);
    function ed25519Enabled(uint256 coinType) external view returns (bool);

    // ---- challenge (SR-41 shape; `version` is `versionOf(node)` so a transfer invalidates it)
    //      arcns:v1:rec:<node-hex>:<coinType>:<version-hex>:<chainId>:<resolver-hex>:<nonce>
    //      Signed as-is by non-EVM signers (BTC BIP-137, ed25519).
    function challenge(bytes32 node, uint256 coinType, string calldata nonce) external view returns (string memory);

    // ---- EIP-712 record proof (SR-41: EVM record proofs are typed data). Domain
    //      {name:"arcns", version:"1", chainId, verifyingContract = this resolver}; struct
    //      RecordProof(bytes32 node,uint256 coinType,bytes32 version,string nonce) with `version = versionOf(node)`.
    //      The namespace is bound through `node` because one resolver serves every namespace. `eip712Domain()`
    //      (ERC-5267) is exposed by the implementation. Nonce rules as for `challenge` (BadNonce).
    function RECORD_PROOF_TYPEHASH() external view returns (bytes32);
    function recordProofDigest(bytes32 node, uint256 coinType, string calldata nonce) external view returns (bytes32);

    // ---- proofs (onchain-design §5, port-map rows 21–23)
    function verifyAddrSelf(bytes32 node, uint256 coinType) external;
    function verifyAddrSelf1271(bytes32 node, uint256 coinType, string calldata nonce, bytes calldata signature)
        external;
    function verifyAddrSecp256k1(bytes32 node, uint256 coinType, string calldata nonce, bytes calldata signature)
        external;
    function verifyAddrBtc(bytes32 node, string calldata nonce, bytes calldata signature65, bytes calldata pubkey64)
        external;
    function verifyAddrEd25519(
        bytes32 node,
        uint256 coinType,
        string calldata nonce,
        bytes calldata signature64,
        bytes32 publicKey
    ) external;

    // ---- primary name (one per address across namespaces, onchain-design §3.4; SR-23 forward-confirm)
    /// @return name canonical display form (at-sign handle or `alice.arc`) or "" when none / stale
    /// @return namespace 0 none, 1 handle, 2 tld
    function primaryOf(address addr) external view returns (string memory name, uint8 namespace);

    // ---- governance
    function setEd25519Enabled(uint256 coinType, bool enabled) external;
}
