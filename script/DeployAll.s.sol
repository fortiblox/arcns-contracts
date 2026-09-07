// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ArcNSConstants} from "../src/lib/ArcNSConstants.sol";
import {ArcNSDeployLib} from "./lib/ArcNSDeployLib.sol";
import {Salts} from "./lib/Salts.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafeSetup {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function VERSION() external view returns (string memory);
}

/// @title DeployAll — WP-113: the M1 stack on Arc (testnet 5042002), deterministic, one script
/// @notice Order (toolchain.md §4): Admin Safe (canonical 1.4.1 proxy factory) → Timelock → ENS trio via
///         EnsBootstrap → GatewayProvider/UniversalResolver → Oracle → Directory → HandleRegistry → Resolver →
///         HandleController → per-TLD pairs (`arc`, `circle`) → hand-off to the timelock → writes
///         `deployments/<chainId>.json`. Every contract is initialised in its creation tx.
///
///         Environment (all required, fail fast; names only in contracts/.env.example):
///           ARCNS_ADMIN            owner of the Admin Safe (sole owner on testnet — CEO 2026-09-06)
///           ARCNS_TREASURY         Treasury Safe / hot wallet that receives fees and holds genesis names
///           ARCNS_TIMELOCK_DELAY   seconds; 3600 on testnet, ≥ 172800 on mainnet (asserted)
///           ARCNS_SAFE_SALT_NONCE  uint256 salt nonce for createProxyWithNonce (same value ⇒ same Safe on mainnet)
///           ARCNS_DRY_RUN          optional, `1` on an anvil fork rehearsal: writes deployments/<chainId>.dry-run.json
///
///         Dry run (anvil fork, no broadcast):  forge script script/DeployAll.s.sol --rpc-url $ARC_RPC_URL --sender $DEPLOYER
///         Live:                                forge script script/DeployAll.s.sol --rpc-url $ARC_RPC_URL --ledger --broadcast
///                                                --with-gas-price 20gwei --priority-gas-price 1gwei --verify --verifier blockscout
///                                                --verifier-url https://testnet.arcscan.app/api/
contract DeployAll is Script {
    // safe-deployments 1.37.62, canonical 1.4.1 (verified present on Arc testnet, onchain-design §0)
    address internal constant SAFE_PROXY_FACTORY_141 = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_L2_SINGLETON_141 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_FALLBACK_HANDLER_141 = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    string[] internal tldLabels = ["arc", "circle"];

    // Script-level state (storage) keeps `run()` shallow enough for the legacy codegen (no via_ir).
    address internal admin;
    address internal treasury;
    uint256 internal delay;
    uint256 internal safeSaltNonce;
    address internal safe;
    ArcNSDeployLib.Params internal params;

    function run() external {
        _readEnv();
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        params.deployer = deployer;
        console2.log("deployer", deployer, "chainid", block.chainid);

        safe = _deploySafe();
        params.pauser = safe;
        params.timelock = _deployTimelock();

        ArcNSDeployLib.Params memory p = params;
        ArcNSDeployLib.Book memory b = ArcNSDeployLib.deployShared(p);
        b.tlds = new ArcNSDeployLib.Tld[](tldLabels.length);
        for (uint256 i = 0; i < tldLabels.length; i++) {
            b.tlds[i] = ArcNSDeployLib.addTld(b, p, tldLabels[i]);
        }
        ArcNSDeployLib.handoff(b, p);
        vm.stopBroadcast();

        _assertPostDeploy(b, p);
        _writeJson(b, p);
    }

    function _readEnv() internal {
        admin = vm.envAddress("ARCNS_ADMIN");
        treasury = vm.envAddress("ARCNS_TREASURY");
        delay = vm.envUint("ARCNS_TIMELOCK_DELAY");
        safeSaltNonce = vm.envUint("ARCNS_SAFE_SALT_NONCE");
        require(admin != address(0) && treasury != address(0), "ARCNS_ADMIN / ARCNS_TREASURY must be set");
        if (block.chainid != ArcNSConstants.ARC_TESTNET_CHAIN_ID) {
            require(delay >= 48 hours, "mainnet timelock delay must be >= 48h (Q12)");
        }
        require(SAFE_PROXY_FACTORY_141.code.length > 0, "Safe 1.4.1 proxy factory absent on this chain");
        require(Salts.CREATE2_FACTORY.code.length > 0, "Arachnid CREATE2 factory absent on this chain");

        params.treasury = treasury;
        params.launchTs = uint64(block.timestamp);
        params.minCommitmentAge = 60;
        params.maxCommitmentAge = 24 hours;
        params.recoveryTimelock = 7 days;
        _readTiers();
    }

    /// @dev 1. Admin Safe via the canonical 1.4.1 proxy factory (owners = [admin], threshold 1 on testnet).
    function _deploySafe() internal returns (address proxy) {
        address[] memory owners = new address[](1);
        owners[0] = admin;
        bytes memory init = abi.encodeCall(
            ISafeSetup.setup, (owners, 1, address(0), "", SAFE_FALLBACK_HANDLER_141, address(0), 0, payable(address(0)))
        );
        proxy =
            ISafeProxyFactory(SAFE_PROXY_FACTORY_141).createProxyWithNonce(SAFE_L2_SINGLETON_141, init, safeSaltNonce);
        require(keccak256(bytes(ISafeSetup(proxy).VERSION())) == keccak256("1.4.1"), "safe version");
        require(ISafeSetup(proxy).getThreshold() == 1, "safe threshold");
    }

    /// @dev 2. Timelock: proposer/executor/canceller = Admin Safe; admin = none (self-administered).
    function _deployTimelock() internal returns (address) {
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        return
            address(
                new TimelockController{salt: Salts.forName("ArcNSTimelock")}(delay, proposers, proposers, address(0))
            );
    }

    /// @dev Tiers come from docs/pricing-tiers.json (`ceiling_usdc` → wei) so chain == doc by construction.
    function _readTiers() internal {
        string memory json = vm.readFile("../docs/pricing-tiers.json");
        uint256[] memory h = vm.parseJsonUintArray(json, ".namespaces.handle.ceiling_usdc");
        uint256[] memory t = vm.parseJsonUintArray(json, ".namespaces.handle.tokenize_ceiling_usdc");
        uint256[] memory a = vm.parseJsonUintArray(json, ".namespaces.arc.ceiling_usdc");
        uint256[] memory c = vm.parseJsonUintArray(json, ".namespaces.circle.ceiling_usdc");
        require(h.length == 10 && t.length == 10 && a.length == 10 && c.length == 10, "tier table length");
        for (uint256 i = 0; i < 10; i++) {
            require(a[i] == c[i], "circle table must equal arc table (CEO 4a)");
            params.handleTiersWei[i] = h[i] * 1e18;
            params.tokenizeTiersWei[i] = t[i] * 1e18;
            params.tldTiersWei[i] = a[i] * 1e18;
        }
    }

    function _assertPostDeploy(ArcNSDeployLib.Book memory b, ArcNSDeployLib.Params memory p) internal view {
        bytes32 admin = 0x00;
        require(!b.oracle.hasRole(admin, p.deployer) && b.oracle.hasRole(admin, p.timelock), "oracle admin");
        require(!b.handles.hasRole(admin, p.deployer) && b.handles.hasRole(admin, p.timelock), "handles admin");
        require(!b.resolver.hasRole(admin, p.deployer) && b.resolver.hasRole(admin, p.timelock), "resolver admin");
        require(!b.directory.hasRole(admin, p.deployer) && b.directory.hasRole(admin, p.timelock), "directory admin");
        require(
            !b.handleController.hasRole(admin, p.deployer) && b.handleController.hasRole(admin, p.timelock),
            "handle controller admin"
        );
        require(b.handleController.hasRole(ArcNSConstants.GENESIS_ROLE, p.deployer), "genesis role kept until seal");
        require(b.root.owner() == p.timelock, "root owner");
        require(b.reverseRegistrar.owner() == p.timelock, "reverse owner");
        require(b.registry.owner(bytes32(0)) == address(b.root), "ens root node owner");
        for (uint256 i = 0; i < b.tlds.length; i++) {
            ArcNSDeployLib.Tld memory t = b.tlds[i];
            require(b.registry.owner(t.node) == address(t.registrar), "tld node owner");
            require(t.registrar.owner() == p.timelock, "registrar owner");
            require(t.registrar.controllers(address(t.controller)), "registrar controller");
            require(!t.controller.hasRole(admin, p.deployer) && t.controller.hasRole(admin, p.timelock), "tld admin");
        }
        console2.log("POST_DEPLOY_ASSERTIONS_OK");
    }

    /// @dev Shape agreed with the SDK lane (2026-09-07): top-level keys = contract names, `tlds.<label>.{BaseRegistrar,
    ///      Controller,node,namespaceId,status}`, `deployBlock`; plus governance/compiler facts and runtime-bytecode hashes.
    function _writeJson(ArcNSDeployLib.Book memory b, ArcNSDeployLib.Params memory p) internal {
        string memory root = "deployment";
        _writeFacts(root, p);
        _writeAddresses(root, b);
        vm.serializeString(root, "bytecodeHashes", _hashesJson(b));
        string memory out = vm.serializeString(root, "tlds", _tldsJson(b));
        // ARCNS_DRY_RUN=1 (optional) keeps a fork rehearsal from overwriting the committed live address book.
        string memory suffix = vm.envOr("ARCNS_DRY_RUN", false) ? ".dry-run.json" : ".json";
        string memory path = string.concat("deployments/", vm.toString(block.chainid), suffix);
        vm.writeJson(out, path);
        console2.log("DEPLOYMENTS_WRITTEN", path);
    }

    function _writeFacts(string memory root, ArcNSDeployLib.Params memory p) internal {
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployBlock", block.number);
        vm.serializeUint(root, "deployTimestamp", block.timestamp);
        vm.serializeAddress(root, "deployer", p.deployer);
        vm.serializeAddress(root, "admin", admin);
        vm.serializeAddress(root, "treasury", p.treasury);
        vm.serializeUint(root, "timelockDelay", delay);
        vm.serializeUint(root, "safeSaltNonce", safeSaltNonce);
        vm.serializeUint(root, "launchTs", p.launchTs);
        vm.serializeUint(root, "minCommitmentAge", p.minCommitmentAge);
        vm.serializeUint(root, "maxCommitmentAge", p.maxCommitmentAge);
        vm.serializeString(root, "solc", "0.8.30");
        vm.serializeString(root, "evmVersion", "osaka");
        vm.serializeUint(root, "optimizerRuns", 800);
        vm.serializeString(
            root,
            "broadcastLog",
            string.concat("broadcast/DeployAll.s.sol/", vm.toString(block.chainid), "/run-latest.json")
        );
        vm.serializeBytes32(root, "handleNamespaceId", ArcNSConstants.HANDLE_ROOT);
    }

    /// @dev contract names as top-level keys (SDK lane contract)
    function _writeAddresses(string memory root, ArcNSDeployLib.Book memory b) internal {
        vm.serializeAddress(root, "AdminSafe", safe);
        vm.serializeAddress(root, "TimelockController", params.timelock);
        vm.serializeAddress(root, "EnsBootstrap", address(b.bootstrap));
        vm.serializeAddress(root, "ENSRegistry", address(b.registry));
        vm.serializeAddress(root, "Root", address(b.root));
        vm.serializeAddress(root, "ReverseRegistrar", address(b.reverseRegistrar));
        vm.serializeAddress(root, "GatewayProvider", address(b.gatewayProvider));
        vm.serializeAddress(root, "UniversalResolver", address(b.universalResolver));
        vm.serializeAddress(root, "ArcNSPriceOracle", address(b.oracle));
        vm.serializeAddress(root, "TldDirectory", address(b.directory));
        vm.serializeAddress(root, "HandleRegistry", address(b.handles));
        vm.serializeAddress(root, "ArcNSResolver", address(b.resolver));
        vm.serializeAddress(root, "HandleController", address(b.handleController));
        vm.serializeAddress(root, "TldMetadata", address(b.tldMetadata));
    }

    function _hashesJson(ArcNSDeployLib.Book memory b) internal returns (string memory) {
        string memory h = "bytecodeHashes";
        vm.serializeBytes32(h, "TimelockController", keccak256(params.timelock.code));
        vm.serializeBytes32(h, "ENSRegistry", keccak256(address(b.registry).code));
        vm.serializeBytes32(h, "Root", keccak256(address(b.root).code));
        vm.serializeBytes32(h, "ReverseRegistrar", keccak256(address(b.reverseRegistrar).code));
        vm.serializeBytes32(h, "UniversalResolver", keccak256(address(b.universalResolver).code));
        vm.serializeBytes32(h, "ArcNSPriceOracle", keccak256(address(b.oracle).code));
        vm.serializeBytes32(h, "TldDirectory", keccak256(address(b.directory).code));
        vm.serializeBytes32(h, "HandleRegistry", keccak256(address(b.handles).code));
        vm.serializeBytes32(h, "ArcNSResolver", keccak256(address(b.resolver).code));
        vm.serializeBytes32(h, "HandleController", keccak256(address(b.handleController).code));
        vm.serializeBytes32(h, "TldMetadata", keccak256(address(b.tldMetadata).code));
        vm.serializeBytes32(h, "TldRegistrar", keccak256(address(b.tlds[0].registrar).code));
        return vm.serializeBytes32(h, "TldRegistrarController", keccak256(address(b.tlds[0].controller).code));
    }

    function _tldsJson(ArcNSDeployLib.Book memory b) internal returns (string memory tldsJson) {
        for (uint256 i = 0; i < b.tlds.length; i++) {
            string memory k = string.concat("tld:", b.tlds[i].label);
            vm.serializeBytes32(k, "node", b.tlds[i].node);
            vm.serializeBytes32(k, "namespaceId", b.tlds[i].node);
            vm.serializeAddress(k, "BaseRegistrar", address(b.tlds[i].registrar));
            vm.serializeString(k, "status", "Active");
            string memory one = vm.serializeAddress(k, "Controller", address(b.tlds[i].controller));
            tldsJson = vm.serializeString("tlds", b.tlds[i].label, one);
        }
    }
}
