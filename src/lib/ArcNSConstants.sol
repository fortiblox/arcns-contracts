// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ArcNSConstants — namespace ids, coin types and role ids shared by every arcns contract
/// @notice Frozen in M1 (WP-105/110/112). Values are derived, not chosen, so they can be re-verified:
///         `cast namehash arc`, `cast namehash circle`, `cast namehash addr.reverse`, and
///         `0x80000000 | 5042002` for the ENSIP-11 Arc coin type (onchain-design §1).
library ArcNSConstants {
    /// @dev ENS root node.
    bytes32 internal constant ROOT_NODE = bytes32(0);

    /// @dev Handle namespace root: keccak256(bytes32(0) ‖ keccak256(at-sign)) (onchain-design §2.1).
    ///      The at-sign is not an ENSIP-15 label and governance owns the ENS root, so no TLD name can ever
    ///      derive a node under it.
    bytes32 internal constant HANDLE_ROOT = keccak256(abi.encodePacked(bytes32(0), keccak256("@")));

    /// @dev `namehash("arc")` = 0x9a7ad1c5d8b1c60ef156c6723dbf462681d6462768a9e60c53665d7fc1337bae.
    bytes32 internal constant ARC_NODE = keccak256(abi.encodePacked(bytes32(0), keccak256("arc")));

    /// @dev `namehash("circle")` = 0xb3f3947bd9b363b1955fa597e342731ea6bde24d057527feb2cdfdeb807c2084.
    bytes32 internal constant CIRCLE_NODE = keccak256(abi.encodePacked(bytes32(0), keccak256("circle")));

    /// @dev `namehash("addr.reverse")` (verbatim ens-contracts constant).
    bytes32 internal constant ADDR_REVERSE_NODE = 0x91d1777781884d03a6757a803996e38de2a42967fb37eeaca72729271025a9e2;

    /// @dev ENSIP-11 coin type for Arc testnet: `0x80000000 | 5042002` = 2152525650.
    uint256 internal constant ARC_TESTNET_COIN_TYPE = 0x804cef52;
    /// @dev ENSIP-9 coin types used by the SDK (onchain-design §1).
    uint256 internal constant COIN_TYPE_BTC = 0;
    uint256 internal constant COIN_TYPE_ETH = 60;
    uint256 internal constant COIN_TYPE_SOL = 501;
    uint256 internal constant COIN_TYPE_X1 = 5010000;

    /// @dev Arc testnet chain id.
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5042002;

    /// @dev Namespace tags used inside commitments (SR-10) and metadata.
    string internal constant TAG_HANDLE = "handle";

    /// @dev Role ids (onchain-design §10). `DEFAULT_ADMIN_ROLE` (0x00) is the timelock everywhere.
    bytes32 internal constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    bytes32 internal constant MARKET_ROLE = keccak256("MARKET_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant GENESIS_ROLE = keccak256("GENESIS_ROLE");
    bytes32 internal constant TOKENIZER_ROLE = keccak256("TOKENIZER_ROLE");

    /// @notice ENSIP-11 coin type of the chain this contract runs on: `0x80000000 | chainid`.
    function evmCoinType() internal view returns (uint256) {
        return 0x80000000 | block.chainid;
    }

    /// @notice Handle tokenId = `uint256(keccak256(bytes(name)))` (onchain-design §2, C1).
    function handleTokenId(string memory name) internal pure returns (uint256) {
        return uint256(keccak256(bytes(name)));
    }

    /// @notice Handle node = `keccak256(HANDLE_ROOT ‖ keccak256(name))` (onchain-design §2.1).
    function handleNode(string memory name) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(HANDLE_ROOT, keccak256(bytes(name))));
    }

    /// @notice Sub-handle node = `keccak256(handleNode ‖ keccak256(label))`.
    function subHandleNode(bytes32 parentNode, string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(parentNode, keccak256(bytes(label))));
    }
}
