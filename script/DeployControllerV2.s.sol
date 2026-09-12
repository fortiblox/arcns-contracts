// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";

import {HandleControllerV2} from "../src/handle/HandleControllerV2.sol";
import {TldRegistrarControllerV2} from "../src/tld/TldRegistrarControllerV2.sol";
import {MarketScriptBase} from "./lib/MarketScriptBase.sol";

/// @title DeployControllerV2 — WP #7772: deploy `HandleControllerV2` + both `TldRegistrarControllerV2`
///        instances, wired to the EXISTING live M1/M2/market stack
/// @notice Deploys three new contracts — `HandleControllerV2` and one `TldRegistrarControllerV2` per
///         TLD (`.arc`, `.circle`) — pointed at addresses ALREADY LIVE in `deployments/<chainId>.json`
///         (`HandleRegistry`, `ArcNSPriceOracle`, `ENSRegistry`, `ArcNSResolver`, `ReverseRegistrar`,
///         `TldDirectory`, each TLD's `BaseRegistrar`, `treasury`, `market.IntegratorRegistry`) plus the
///         book's own `minCommitmentAge`/`maxCommitmentAge` (unchanged from V1 — same commit-reveal
///         semantics). Writes a new, key-scoped `controllerV2{HandleControllerV2,
///         TldRegistrarControllerV2Arc, TldRegistrarControllerV2Circle}` object; every other key in the
///         book is untouched (`vm.writeJson` with a key path, same discipline as `DeployMarket.s.sol`).
///
/// @dev **THIS SCRIPT ONLY DEPLOYS CONTRACTS. IT DOES NOT CUT ANYTHING OVER.** It must NEVER, and does
///      NOT:
///        - call `sealGenesis` on either new controller (a separate, later step — see
///          `deploy/runbooks/integrator-v2-cutover.md` step 1, which reads the live `genesisRoot`
///          straight off the V1 controllers this script does not touch),
///        - grant any role anywhere (`HandleRegistry.grantRole(REGISTRAR_ROLE, ...)`,
///          `TldRegistrar.addController`/`removeController`, `TldDirectory.setController`, or anything
///          on `IntegratorRegistry`),
///        - revoke or otherwise touch a single V1 role or address.
///      Every one of those is a separate, timelocked governance operation a human/Safe executes only
///      after the CEO has reviewed the deploy and the cutover runbook — never from this script, never
///      from this lane. New contracts freshly deployed here hold ZERO privileges anywhere until that
///      separate step runs; deploying them is inert with respect to the live registration flow.
///
///      Deploy-or-reuse: if the book already has a `.controllerV2.<Name>` address with code at it (a
///      prior partial run), that contract is reused rather than redeployed — mirrors the resumability
///      discipline of `DeployMarket.s.sol`/`MarketDeployLib`, without needing CREATE2 salts (this
///      script's contracts are not referenced by address anywhere else pre-cutover, so a plain `new`
///      per missing contract is sufficient; nothing depends on a deterministic address).
///
///      Environment (names only, `contracts/.env.example`):
///        ARCNS_ADDRESS_BOOK   path of the book to read/append (default `deployments/<chainId>.json`,
///                             or `.dry-run.json` with ARCNS_DRY_RUN=1)
///        ARCNS_DRY_RUN        `1` forces output to `deployments/<chainId>.controllerV2-dry-run.json`;
///                             any run without `--broadcast` writes there anyway (never the live book)
///
///      Local dry-run / simulation (no `--broadcast`, no keys — proves the script compiles and executes
///      without reverting; this is the ONLY way this script has been run so far, see WP #7772 report):
///        forge script script/DeployControllerV2.s.sol --sig 'run()'
///      Fork rehearsal against the live book (no broadcast):
///        ARCNS_ADDRESS_BOOK=deployments/5042002.json forge script script/DeployControllerV2.s.sol \
///          --sig 'run()' --rpc-url $ARC_RPC_URL --sender 0xd91d1F6abB7243910B38Fe86CdCd0754a00cB152
///      Live (CEO only, separate go-ahead required — never `--broadcast` from this lane):
///        forge script script/DeployControllerV2.s.sol --sig 'run()' --rpc-url $ARC_RPC_URL --ledger \
///          --broadcast --with-gas-price 20gwei --priority-gas-price 1gwei --verify --verifier blockscout \
///          --verifier-url https://testnet.arcscan.app/api/
contract DeployControllerV2 is MarketScriptBase {
    string[] internal tldLabels = ["arc", "circle"];

    struct Inputs {
        address admin; // DEFAULT_ADMIN_ROLE on the new controllers — the TimelockController (unchanged from V1)
        address genesisAdmin; // GENESIS_ROLE until sealGenesis — the deployer EOA (unchanged from V1)
        address pauser; // PAUSER_ROLE — the Admin Safe (unchanged from V1)
        address registry; // HandleRegistry (EXISTING, live)
        address oracle; // ArcNSPriceOracle (EXISTING, live)
        address treasury; // Treasury Safe (EXISTING, live)
        address integratorRegistry; // market.IntegratorRegistry (EXISTING, live)
        address ens; // ENSRegistry (EXISTING, live)
        address resolver; // ArcNSResolver (EXISTING, live)
        address reverseRegistrar; // ReverseRegistrar (EXISTING, live)
        address directory; // TldDirectory (EXISTING, live)
        uint256 minCommitmentAge;
        uint256 maxCommitmentAge;
    }

    function run() external {
        string memory bookPath = _bookPath();
        string memory json = vm.readFile(bookPath);
        _logBook("ADDRESS_BOOK", bookPath);

        Inputs memory i = _inputs(json);

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        console2.log("sender", sender, "chainid", block.chainid);

        address handleV2 = _deployOrReuse(json, ".controllerV2.HandleControllerV2", "HandleControllerV2");
        if (handleV2 == address(0)) {
            handleV2 = address(
                new HandleControllerV2(
                    HandleControllerV2.Init({
                        admin: i.admin,
                        genesisAdmin: i.genesisAdmin,
                        pauser: i.pauser,
                        registry: i.registry,
                        oracle: i.oracle,
                        treasury: i.treasury,
                        integratorRegistry: i.integratorRegistry,
                        minCommitmentAge: i.minCommitmentAge,
                        maxCommitmentAge: i.maxCommitmentAge
                    })
                )
            );
            console2.log("DEPLOYED HandleControllerV2", handleV2);
        } else {
            console2.log("REUSED   HandleControllerV2", handleV2);
        }

        address arcV2 = _deployOrReuse(json, ".controllerV2.TldRegistrarControllerV2Arc", "TldRegistrarControllerV2Arc");
        if (arcV2 == address(0)) {
            arcV2 = address(new TldRegistrarControllerV2(_tldInit(json, i, "arc")));
            console2.log("DEPLOYED TldRegistrarControllerV2Arc", arcV2);
        } else {
            console2.log("REUSED   TldRegistrarControllerV2Arc", arcV2);
        }

        address circleV2 =
            _deployOrReuse(json, ".controllerV2.TldRegistrarControllerV2Circle", "TldRegistrarControllerV2Circle");
        if (circleV2 == address(0)) {
            circleV2 = address(new TldRegistrarControllerV2(_tldInit(json, i, "circle")));
            console2.log("DEPLOYED TldRegistrarControllerV2Circle", circleV2);
        } else {
            console2.log("REUSED   TldRegistrarControllerV2Circle", circleV2);
        }
        vm.stopBroadcast();

        console2.log("CONTROLLER_V2_DEPLOY_ASSERTIONS_OK");
        _assertNoRolesGranted(handleV2, i.registry);
        _writeJson(bookPath, json, handleV2, arcV2, circleV2);
    }

    /// @dev Every constructor arg for a fresh `HandleControllerV2`/`TldRegistrarControllerV2` comes
    ///      from EXISTING book keys (M1/M2/market) — nothing here is a new deploy-time choice.
    function _inputs(string memory json) internal view returns (Inputs memory i) {
        i.admin = vm.parseJsonAddress(json, ".TimelockController");
        i.genesisAdmin = vm.parseJsonAddress(json, ".deployer");
        i.pauser = vm.parseJsonAddress(json, ".AdminSafe");
        i.registry = vm.parseJsonAddress(json, ".HandleRegistry");
        i.oracle = vm.parseJsonAddress(json, ".ArcNSPriceOracle");
        i.treasury = vm.parseJsonAddress(json, ".treasury");
        i.integratorRegistry = vm.parseJsonAddress(json, ".market.IntegratorRegistry");
        i.ens = vm.parseJsonAddress(json, ".ENSRegistry");
        i.resolver = vm.parseJsonAddress(json, ".ArcNSResolver");
        i.reverseRegistrar = vm.parseJsonAddress(json, ".ReverseRegistrar");
        i.directory = vm.parseJsonAddress(json, ".TldDirectory");
        i.minCommitmentAge = vm.parseJsonUint(json, ".minCommitmentAge");
        i.maxCommitmentAge = vm.parseJsonUint(json, ".maxCommitmentAge");

        _requireAddr(i.admin, "TimelockController");
        _requireAddr(i.genesisAdmin, "deployer");
        _requireAddr(i.pauser, "AdminSafe");
        _requireAddr(i.registry, "HandleRegistry");
        _requireAddr(i.oracle, "ArcNSPriceOracle");
        _requireAddr(i.treasury, "treasury");
        _requireAddr(i.integratorRegistry, "market.IntegratorRegistry");
        _requireAddr(i.ens, "ENSRegistry");
        _requireAddr(i.resolver, "ArcNSResolver");
        _requireAddr(i.reverseRegistrar, "ReverseRegistrar");
        _requireAddr(i.directory, "TldDirectory");
        require(i.maxCommitmentAge > i.minCommitmentAge, "DeployControllerV2: bad commitment ages in book");
    }

    function _tldInit(string memory json, Inputs memory i, string memory label)
        internal
        pure
        returns (TldRegistrarControllerV2.Init memory)
    {
        address registrar = vm.parseJsonAddress(json, string.concat(".tlds.", label, ".BaseRegistrar"));
        require(registrar != address(0), string.concat("DeployControllerV2: missing tlds.", label, ".BaseRegistrar"));
        return TldRegistrarControllerV2.Init({
            admin: i.admin,
            genesisAdmin: i.genesisAdmin,
            pauser: i.pauser,
            registrar: registrar,
            ens: i.ens,
            oracle: i.oracle,
            resolver: i.resolver,
            reverseRegistrar: i.reverseRegistrar,
            directory: i.directory,
            treasury: i.treasury,
            integratorRegistry: i.integratorRegistry,
            minCommitmentAge: i.minCommitmentAge,
            maxCommitmentAge: i.maxCommitmentAge,
            tld: label
        });
    }

    /// @dev Resume support without CREATE2: if the book already names a `.controllerV2.<key>` address
    ///      that has code, reuse it; otherwise return `address(0)` so the caller deploys fresh.
    function _deployOrReuse(string memory json, string memory jsonPath, string memory label)
        internal
        view
        returns (address existing)
    {
        if (!vm.keyExistsJson(json, jsonPath)) return address(0);
        address a = vm.parseJsonAddress(json, jsonPath);
        if (a.code.length == 0) return address(0);
        console2.log("RESUME: found existing code for", label, a);
        return a;
    }

    /// @dev Belt-and-braces: the freshly deployed `HandleControllerV2` must NOT hold `REGISTRAR_ROLE`
    ///      on the live `HandleRegistry` (that grant is a separate, later, timelocked step — see the
    ///      top-of-file NatSpec and `deploy/runbooks/integrator-v2-cutover.md`). If this ever fails it
    ///      means something OTHER than this script granted the role out of band; it is not something
    ///      `DeployControllerV2` itself could cause.
    function _assertNoRolesGranted(address handleV2, address registry) internal view {
        (bool ok, bytes memory ret) = registry.staticcall(
            abi.encodeWithSignature("hasRole(bytes32,address)", keccak256("REGISTRAR_ROLE"), handleV2)
        );
        if (ok && ret.length == 32) {
            require(
                abi.decode(ret, (bool)) == false, "DeployControllerV2: V2 unexpectedly already holds REGISTRAR_ROLE"
            );
        }
    }

    function _writeJson(
        string memory bookPath,
        string memory bookJson,
        address handleV2,
        address arcV2,
        address circleV2
    ) internal {
        string memory hashes = "controllerV2.bytecodeHashes";
        vm.serializeBytes32(hashes, "HandleControllerV2", keccak256(handleV2.code));
        vm.serializeBytes32(hashes, "TldRegistrarControllerV2Arc", keccak256(arcV2.code));
        string memory hashesJson =
            vm.serializeBytes32(hashes, "TldRegistrarControllerV2Circle", keccak256(circleV2.code));

        string memory root = "controllerV2";
        vm.serializeAddress(root, "HandleControllerV2", handleV2);
        vm.serializeAddress(root, "TldRegistrarControllerV2Arc", arcV2);
        vm.serializeAddress(root, "TldRegistrarControllerV2Circle", circleV2);
        vm.serializeUint(root, "deployBlock", block.number);
        string memory controllerV2Json = vm.serializeString(root, "bytecodeHashes", hashesJson);

        if (_isLiveWrite()) {
            vm.writeJson(controllerV2Json, bookPath, ".controllerV2");
            console2.log("CONTROLLER_V2_DEPLOYMENTS_WRITTEN", bookPath);
            return;
        }
        string memory outer = "dry-run";
        vm.serializeUint(outer, "chainId", block.chainid);
        vm.serializeString(outer, "sourceBook", bookPath);
        string memory out = vm.serializeString(outer, "controllerV2", controllerV2Json);
        vm.writeJson(out, _controllerV2DryRunPath());
        console2.log("CONTROLLER_V2_DRY_RUN_WRITTEN", _controllerV2DryRunPath(), "(input book untouched)");
        bookJson;
    }

    function _controllerV2DryRunPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".controllerV2-dry-run.json");
    }
}
