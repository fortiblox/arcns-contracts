// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ENS} from "@ensdomains/ens-contracts/registry/ENS.sol";
import {ENSRegistry} from "@ensdomains/ens-contracts/registry/ENSRegistry.sol";
import {Root} from "@ensdomains/ens-contracts/root/Root.sol";
import {ReverseRegistrar} from "@ensdomains/ens-contracts/reverseRegistrar/ReverseRegistrar.sol";
import {UniversalResolver} from "@ensdomains/ens-contracts/universalResolver/UniversalResolver.sol";
import {GatewayProvider} from "@ensdomains/ens-contracts/ccipRead/GatewayProvider.sol";

import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {ArcNSPriceOracle} from "../../src/pricing/ArcNSPriceOracle.sol";
import {TldDirectory} from "../../src/tld/TldDirectory.sol";
import {TldMetadata} from "../../src/tld/TldMetadata.sol";
import {TldRegistrar} from "../../src/tld/TldRegistrar.sol";
import {TldRegistrarController} from "../../src/tld/TldRegistrarController.sol";
import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {HandleController} from "../../src/handle/HandleController.sol";
import {ArcNSResolver} from "../../src/resolver/ArcNSResolver.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {ITldDirectory} from "../../src/interfaces/ITldDirectory.sol";
import {EnsBootstrap} from "./EnsBootstrap.sol";
import {Salts} from "./Salts.sol";

/// @title ArcNSDeployLib — the whole M1 stack, deterministic, initialised in the creation transactions
/// @notice Used by `script/DeployAll.s.sol` (broadcast) and by `test/integration/*` (in-process). Every
///         contract is initialised by its constructor (WP-113: no separate `initialize` tx exists). The
///         deployer keeps DEFAULT_ADMIN_ROLE only for the wiring calls inside the same script run and hands
///         it to the timelock in `handoff` (asserted by `script/VerifyRoles.s.sol`, INV-8). GENESIS_ROLE
///         stays with the deployer until `sealGenesis` revokes it (SR-16).
library ArcNSDeployLib {
    struct Params {
        address deployer; // EOA running the script; temporary admin, permanent GENESIS_ROLE until seal
        address pauser; // Admin Safe (no delay) — PAUSER_ROLE on controllers and the directory
        address treasury; // Treasury Safe (hot wallet on testnet per CEO 2026-09-06)
        address timelock; // OZ TimelockController, final DEFAULT_ADMIN everywhere
        uint64 launchTs; // oracle launch timestamp (early-bird anchor), per namespace
        uint256 minCommitmentAge; // 60 s (SR-10)
        uint256 maxCommitmentAge; // 24 h
        uint64 recoveryTimelock; // 7 days
        uint256[10] handleTiersWei;
        uint256[10] tokenizeTiersWei;
        uint256[10] tldTiersWei; // same table for every TLD at launch (CEO 3a/4a)
    }

    struct Tld {
        string label;
        bytes32 node;
        TldRegistrar registrar;
        TldRegistrarController controller;
    }

    struct Book {
        EnsBootstrap bootstrap;
        ENSRegistry registry;
        Root root;
        ReverseRegistrar reverseRegistrar;
        GatewayProvider gatewayProvider;
        UniversalResolver universalResolver;
        ArcNSPriceOracle oracle;
        TldDirectory directory;
        HandleRegistry handles;
        ArcNSResolver resolver;
        HandleController handleController;
        TldMetadata tldMetadata;
        Tld[] tlds;
    }

    /// @dev Deploys the shared contracts (C3, C3a, C6, C7, C8, C9, C1, C2). Caller must be `p.deployer`.
    function deployShared(Params memory p) internal returns (Book memory b) {
        b.bootstrap = new EnsBootstrap{salt: Salts.forName("EnsBootstrap")}(p.deployer);
        b.registry = b.bootstrap.registry();
        b.root = b.bootstrap.root();
        b.reverseRegistrar = b.bootstrap.reverseRegistrar();
        b.root.setController(p.deployer, true);

        string[] memory noGateways = new string[](0); // SR-24: no CCIP-Read gateway in v1
        b.gatewayProvider = new GatewayProvider{salt: Salts.forName("GatewayProvider")}(p.timelock, noGateways);
        b.universalResolver = new UniversalResolver{salt: Salts.forName("UniversalResolver")}(
            p.timelock, ENS(address(b.registry)), b.gatewayProvider
        );

        b.oracle = new ArcNSPriceOracle{salt: Salts.forName("ArcNSPriceOracle")}(p.deployer);
        b.directory = new TldDirectory{salt: Salts.forName("TldDirectory")}(p.deployer, p.pauser);
        b.handles = new HandleRegistry{salt: Salts.forName("HandleRegistry")}(
            p.deployer, p.treasury, IArcNSPriceOracle(address(b.oracle)), p.recoveryTimelock
        );
        b.resolver = new ArcNSResolver{salt: Salts.forName("ArcNSResolver")}(
            ENS(address(b.registry)),
            IHandleRegistry(address(b.handles)),
            ITldDirectory(address(b.directory)),
            address(b.reverseRegistrar),
            p.deployer
        );
        b.reverseRegistrar.setDefaultResolver(address(b.resolver));

        b.handleController = new HandleController{salt: Salts.forName("HandleController")}(
            HandleController.Init({
                admin: p.deployer,
                genesisAdmin: p.deployer,
                pauser: p.pauser,
                registry: address(b.handles),
                oracle: address(b.oracle),
                treasury: p.treasury,
                minCommitmentAge: p.minCommitmentAge,
                maxCommitmentAge: p.maxCommitmentAge
            })
        );
        b.handles.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(b.handleController));
        b.oracle
            .initNamespace(
                ArcNSConstants.HANDLE_ROOT,
                address(b.handleController),
                address(b.handles),
                p.launchTs,
                p.handleTiersWei,
                p.tokenizeTiersWei
            );
        b.tldMetadata = new TldMetadata{salt: Salts.forName("TldMetadata")}(ITldDirectory(address(b.directory)));
    }

    /// @dev "TLDs are data": one (registrar, controller) pair per label, wired into Root, directory and oracle.
    ///      Pre-handoff form (deployer is Root controller and admin). Post-handoff the same calls are a
    ///      timelock proposal — `script/AddTld.s.sol` prints that batch.
    function addTld(Book memory b, Params memory p, string memory label) internal returns (Tld memory t) {
        t.label = label;
        t.node = keccak256(abi.encodePacked(bytes32(0), keccak256(bytes(label))));
        t.registrar = new TldRegistrar{salt: Salts.ofTld("TldRegistrar", label)}(
            ENS(address(b.registry)), t.node, label, address(b.tldMetadata), p.deployer
        );
        t.controller = new TldRegistrarController{salt: Salts.ofTld("TldRegistrarController", label)}(
            TldRegistrarController.Init({
                admin: p.deployer,
                genesisAdmin: p.deployer,
                pauser: p.pauser,
                registrar: address(t.registrar),
                ens: address(b.registry),
                oracle: address(b.oracle),
                resolver: address(b.resolver),
                reverseRegistrar: address(b.reverseRegistrar),
                directory: address(b.directory),
                treasury: p.treasury,
                minCommitmentAge: p.minCommitmentAge,
                maxCommitmentAge: p.maxCommitmentAge,
                tld: label
            })
        );
        b.root.setSubnodeOwner(keccak256(bytes(label)), address(t.registrar));
        t.registrar.addController(address(t.controller));
        // ENS pattern: the controller sets the registrant's reverse record on their behalf (`setNameForAddr`).
        b.reverseRegistrar.setController(address(t.controller), true);
        b.directory.add(t.node, label, address(t.registrar), address(t.controller), t.node);
        uint256[10] memory noTokenize;
        b.oracle.initNamespace(t.node, address(t.controller), address(0), p.launchTs, p.tldTiersWei, noTokenize);
        t.registrar.transferOwnership(p.timelock);
    }

    /// @dev Hands every admin authority to the timelock and drops the deployer's (INV-8). GENESIS_ROLE is
    ///      deliberately kept by the deployer until `sealGenesis` (SR-16) — VerifyRoles checks it after seal.
    function handoff(Book memory b, Params memory p) internal {
        bytes32 admin = 0x00;
        b.oracle.grantRole(admin, p.timelock);
        b.oracle.renounceRole(admin, p.deployer);
        b.directory.grantRole(admin, p.timelock);
        b.directory.renounceRole(admin, p.deployer);
        b.handles.grantRole(admin, p.timelock);
        b.handles.renounceRole(admin, p.deployer);
        b.resolver.grantRole(admin, p.timelock);
        b.resolver.renounceRole(admin, p.deployer);
        b.handleController.grantRole(admin, p.timelock);
        b.handleController.renounceRole(admin, p.deployer);
        for (uint256 i = 0; i < b.tlds.length; i++) {
            b.tlds[i].controller.grantRole(admin, p.timelock);
            b.tlds[i].controller.renounceRole(admin, p.deployer);
        }
        b.root.setController(p.deployer, false);
        b.root.transferOwnership(p.timelock);
        b.reverseRegistrar.transferOwnership(p.timelock);
        bytes32 reverseNode = keccak256(abi.encodePacked(bytes32(0), keccak256("reverse")));
        b.registry.setOwner(reverseNode, p.timelock);
    }
}
