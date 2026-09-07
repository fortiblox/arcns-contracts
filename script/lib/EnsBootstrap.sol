// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ENS} from "@ensdomains/ens-contracts/registry/ENS.sol";
import {ENSRegistry} from "@ensdomains/ens-contracts/registry/ENSRegistry.sol";
import {Root} from "@ensdomains/ens-contracts/root/Root.sol";
import {ReverseRegistrar} from "@ensdomains/ens-contracts/reverseRegistrar/ReverseRegistrar.sol";

/// @title EnsBootstrap — deterministic deployment of the verbatim ENS trio (C3 registry + Root, C8 reverse)
/// @notice The verbatim ens-contracts assign ownership to `msg.sender` in their constructors. Deploying them
///         straight through the Arachnid CREATE2 factory would make the factory the owner, so this one-shot
///         bootstrap (itself deployed with CREATE2) is `msg.sender` for the three contracts, wires
///         `addr.reverse` exactly like the ENS mainnet deploy, then hands every ownership to `owner`
///         (the deployer EOA, which hands to the timelock at the end of `DeployAll`). Its own address is
///         deterministic, and the three ENS contracts are CREATE'd from its nonces 1..3, so the whole ENS
///         stack has the same addresses on Arc mainnet when the same salt and deployer are used.
///         Contains no privileged function after construction; holds nothing.
contract EnsBootstrap {
    ENSRegistry public immutable registry;
    Root public immutable root;
    ReverseRegistrar public immutable reverseRegistrar;

    bytes32 private constant REVERSE_LABEL = keccak256("reverse");
    bytes32 private constant ADDR_LABEL = keccak256("addr");

    constructor(address owner) {
        require(owner != address(0), "EnsBootstrap: owner=0");
        registry = new ENSRegistry(); // root node owner = this
        root = new Root(ENS(address(registry))); // Ownable(this)
        reverseRegistrar = new ReverseRegistrar(ENS(address(registry))); // Ownable(this)

        bytes32 reverseNode = registry.setSubnodeOwner(bytes32(0), REVERSE_LABEL, address(this));
        registry.setSubnodeOwner(reverseNode, ADDR_LABEL, address(reverseRegistrar));
        registry.setOwner(reverseNode, owner);
        registry.setOwner(bytes32(0), address(root));
        root.transferOwnership(owner);
        reverseRegistrar.transferOwnership(owner);
    }
}
