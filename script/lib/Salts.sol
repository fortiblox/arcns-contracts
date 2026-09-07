// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Salts — CREATE2 salts (toolchain.md §4): `keccak256("arcns:v1:<ContractName>")`.
library Salts {
    string internal constant PREFIX = "arcns:v1:";
    /// @dev Arachnid deterministic-deployment proxy, present on Arc testnet (onchain-design §0).
    address internal constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function forName(string memory name) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PREFIX, name));
    }

    function ofTld(string memory contractName, string memory tld) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PREFIX, contractName, ":", tld));
    }
}
