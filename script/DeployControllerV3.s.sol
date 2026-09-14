// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";

import {HandleControllerV3} from "../src/handle/HandleControllerV3.sol";
import {TldRegistrarControllerV3} from "../src/tld/TldRegistrarControllerV3.sol";
import {MarketScriptBase} from "./lib/MarketScriptBase.sol";

/// @title DeployControllerV3 — deploy `HandleControllerV3` + both `TldRegistrarControllerV3` instances,
///        wired to the EXISTING live M1/M2/market stack
/// @notice Sibling of `DeployControllerV2.s.sol`, same deploy-or-reuse / assert-no-roles / dry-run
///         shape. Deploys three new contracts — `HandleControllerV3` and one `TldRegistrarControllerV3`
///         per TLD (`.arc`, `.circle`) — pointed at addresses ALREADY LIVE in
///         `deployments/<chainId>.json` (`HandleRegistry`, `ArcNSPriceOracle`, `ENSRegistry` (unused by
///         V3 but read for parity with the book's own shape), `TldDirectory`, each TLD's
///         `BaseRegistrar`, `treasury`, `market.IntegratorRegistry`). V3's `Init` is smaller than V2's:
///         no `minCommitmentAge`/`maxCommitmentAge` (V3 has no commit-reveal — `registerDirect` is a
///         single transaction) and, for the TLD controller, no `resolver`/`reverseRegistrar` (V3 sets
///         no resolver data and no reverse record — see `TldRegistrarControllerV3Test`'s
///         `test_no_resolver_taking_register_selector_exists_on_v3` /
///         `test_registerDirect_signature_has_no_resolver_data_reverseRecord_params`). Writes a new,
///         key-scoped `controllerV3{HandleControllerV3, TldRegistrarControllerV3Arc,
///         TldRegistrarControllerV3Circle}` object; every other key in the book is untouched.
///
/// @dev **THIS SCRIPT ONLY DEPLOYS CONTRACTS. IT DOES NOT CUT ANYTHING OVER.** Same discipline as
///      `DeployControllerV2.s.sol` — it must NEVER, and does NOT:
///        - call `sealGenesis` on either new controller,
///        - grant any role anywhere (`HandleRegistry.grantRole(REGISTRAR_ROLE, ...)`,
///          `TldRegistrar.addController`, `TldDirectory.setController`, or anything on
///          `IntegratorRegistry`),
///        - set an allowlist root/sunset on either controller (both default closed —
///          `MAX_ALLOWLIST_WINDOW` is a ceiling on a later setter call, not a constructor input),
///        - revoke or otherwise touch a single V1/V2 role or address.
///      Every one of those is a separate, timelocked governance operation a human/Safe executes only
///      after the CEO has reviewed the deploy — never from this script, never from this lane. New
///      contracts freshly deployed here hold ZERO privileges anywhere until that separate step runs:
///      with no `REGISTRAR_ROLE`/`addController` grant, `registerDirect` cannot mint anything — the
///      single-transaction, no-commit-reveal registration path this contract implements is fully inert
///      until a deliberate, separately-reviewed cutover.
///
///      Deploy-or-reuse: if the book already has a `.controllerV3.<Name>` address with code at it (a
///      prior partial run), that contract is reused rather than redeployed.
///
///      Environment (names only, `contracts/.env.example`):
///        ARCNS_ADDRESS_BOOK   path of the book to read/append (default `deployments/<chainId>.json`,
///                             or `.dry-run.json` with ARCNS_DRY_RUN=1)
///        ARCNS_DRY_RUN        `1` forces output to `deployments/<chainId>.controllerV3-dry-run.json`;
///                             any run without `--broadcast` writes there anyway (never the live book)
///
///      Local dry-run / simulation (no `--broadcast`, no keys):
///        forge script script/DeployControllerV3.s.sol --sig 'run()'
///      Fork rehearsal against the live book (no broadcast):
///        ARCNS_ADDRESS_BOOK=deployments/5042002.json forge script script/DeployControllerV3.s.sol \
///          --sig 'run()' --rpc-url $ARC_RPC_URL --sender 0xd91d1F6abB7243910B38Fe86CdCd0754a00cB152
///      Live (CEO go-ahead required):
///        forge script script/DeployControllerV3.s.sol --sig 'run()' --rpc-url $ARC_RPC_URL \
///          --keystore <deployer> --broadcast --with-gas-price 25gwei --priority-gas-price 1.15gwei
contract DeployControllerV3 is MarketScriptBase {
    string[] internal tldLabels = ["arc", "circle"];

    struct Inputs {
        address admin; // DEFAULT_ADMIN_ROLE on the new controllers — the TimelockController
        address genesisAdmin; // GENESIS_ROLE until sealGenesis — the deployer EOA
        address pauser; // PAUSER_ROLE — the Admin Safe
        address registry; // HandleRegistry (EXISTING, live)
        address oracle; // ArcNSPriceOracle (EXISTING, live)
        address treasury; // Treasury Safe (EXISTING, live)
        address integratorRegistry; // market.IntegratorRegistry (EXISTING, live)
        address directory; // TldDirectory (EXISTING, live)
    }

    function run() external {
        string memory bookPath = _bookPath();
        string memory json = vm.readFile(bookPath);
        _logBook("ADDRESS_BOOK", bookPath);

        Inputs memory i = _inputs(json);

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        console2.log("sender", sender, "chainid", block.chainid);

        address handleV3 = _deployOrReuse(json, ".controllerV3.HandleControllerV3", "HandleControllerV3");
        if (handleV3 == address(0)) {
            handleV3 = address(
                new HandleControllerV3(
                    HandleControllerV3.Init({
                        admin: i.admin,
                        genesisAdmin: i.genesisAdmin,
                        pauser: i.pauser,
                        registry: i.registry,
                        oracle: i.oracle,
                        treasury: i.treasury,
                        integratorRegistry: i.integratorRegistry
                    })
                )
            );
            console2.log("DEPLOYED HandleControllerV3", handleV3);
        } else {
            console2.log("REUSED   HandleControllerV3", handleV3);
        }

        address arcV3 = _deployOrReuse(json, ".controllerV3.TldRegistrarControllerV3Arc", "TldRegistrarControllerV3Arc");
        if (arcV3 == address(0)) {
            arcV3 = address(new TldRegistrarControllerV3(_tldInit(json, i, "arc")));
            console2.log("DEPLOYED TldRegistrarControllerV3Arc", arcV3);
        } else {
            console2.log("REUSED   TldRegistrarControllerV3Arc", arcV3);
        }

        address circleV3 =
            _deployOrReuse(json, ".controllerV3.TldRegistrarControllerV3Circle", "TldRegistrarControllerV3Circle");
        if (circleV3 == address(0)) {
            circleV3 = address(new TldRegistrarControllerV3(_tldInit(json, i, "circle")));
            console2.log("DEPLOYED TldRegistrarControllerV3Circle", circleV3);
        } else {
            console2.log("REUSED   TldRegistrarControllerV3Circle", circleV3);
        }
        vm.stopBroadcast();

        console2.log("CONTROLLER_V3_DEPLOY_ASSERTIONS_OK");
        _assertNoRolesGranted(handleV3, i.registry);
        _writeJson(bookPath, json, handleV3, arcV3, circleV3);
    }

    /// @dev Every constructor arg for a fresh `HandleControllerV3`/`TldRegistrarControllerV3` comes
    ///      from EXISTING book keys (M1/M2/market) — nothing here is a new deploy-time choice.
    function _inputs(string memory json) internal view returns (Inputs memory i) {
        i.admin = vm.parseJsonAddress(json, ".TimelockController");
        i.genesisAdmin = vm.parseJsonAddress(json, ".deployer");
        i.pauser = vm.parseJsonAddress(json, ".AdminSafe");
        i.registry = vm.parseJsonAddress(json, ".HandleRegistry");
        i.oracle = vm.parseJsonAddress(json, ".ArcNSPriceOracle");
        i.treasury = vm.parseJsonAddress(json, ".treasury");
        i.integratorRegistry = vm.parseJsonAddress(json, ".market.IntegratorRegistry");
        i.directory = vm.parseJsonAddress(json, ".TldDirectory");

        _requireAddr(i.admin, "TimelockController");
        _requireAddr(i.genesisAdmin, "deployer");
        _requireAddr(i.pauser, "AdminSafe");
        _requireAddr(i.registry, "HandleRegistry");
        _requireAddr(i.oracle, "ArcNSPriceOracle");
        _requireAddr(i.treasury, "treasury");
        _requireAddr(i.integratorRegistry, "market.IntegratorRegistry");
        _requireAddr(i.directory, "TldDirectory");
    }

    function _tldInit(string memory json, Inputs memory i, string memory label)
        internal
        pure
        returns (TldRegistrarControllerV3.Init memory)
    {
        address registrar = vm.parseJsonAddress(json, string.concat(".tlds.", label, ".BaseRegistrar"));
        require(registrar != address(0), string.concat("DeployControllerV3: missing tlds.", label, ".BaseRegistrar"));
        return TldRegistrarControllerV3.Init({
            admin: i.admin,
            genesisAdmin: i.genesisAdmin,
            pauser: i.pauser,
            registrar: registrar,
            oracle: i.oracle,
            directory: i.directory,
            treasury: i.treasury,
            integratorRegistry: i.integratorRegistry,
            tld: label
        });
    }

    /// @dev Resume support without CREATE2: if the book already names a `.controllerV3.<key>` address
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

    /// @dev Belt-and-braces: the freshly deployed `HandleControllerV3` must NOT hold `REGISTRAR_ROLE`
    ///      on the live `HandleRegistry` (that grant is a separate, later, timelocked step). If this
    ///      ever fails it means something OTHER than this script granted the role out of band; it is
    ///      not something `DeployControllerV3` itself could cause.
    function _assertNoRolesGranted(address handleV3, address registry) internal view {
        (bool ok, bytes memory ret) = registry.staticcall(
            abi.encodeWithSignature("hasRole(bytes32,address)", keccak256("REGISTRAR_ROLE"), handleV3)
        );
        if (ok && ret.length == 32) {
            require(
                abi.decode(ret, (bool)) == false, "DeployControllerV3: V3 unexpectedly already holds REGISTRAR_ROLE"
            );
        }
    }

    function _writeJson(
        string memory bookPath,
        string memory bookJson,
        address handleV3,
        address arcV3,
        address circleV3
    ) internal {
        string memory hashes = "controllerV3.bytecodeHashes";
        vm.serializeBytes32(hashes, "HandleControllerV3", keccak256(handleV3.code));
        vm.serializeBytes32(hashes, "TldRegistrarControllerV3Arc", keccak256(arcV3.code));
        string memory hashesJson =
            vm.serializeBytes32(hashes, "TldRegistrarControllerV3Circle", keccak256(circleV3.code));

        string memory root = "controllerV3";
        vm.serializeAddress(root, "HandleControllerV3", handleV3);
        vm.serializeAddress(root, "TldRegistrarControllerV3Arc", arcV3);
        vm.serializeAddress(root, "TldRegistrarControllerV3Circle", circleV3);
        vm.serializeUint(root, "deployBlock", block.number);
        string memory controllerV3Json = vm.serializeString(root, "bytecodeHashes", hashesJson);

        if (_isLiveWrite()) {
            vm.writeJson(controllerV3Json, bookPath, ".controllerV3");
            console2.log("CONTROLLER_V3_DEPLOYMENTS_WRITTEN", bookPath);
            return;
        }
        string memory outer = "dry-run";
        vm.serializeUint(outer, "chainId", block.chainid);
        vm.serializeString(outer, "sourceBook", bookPath);
        string memory out = vm.serializeString(outer, "controllerV3", controllerV3Json);
        vm.writeJson(out, _controllerV3DryRunPath());
        console2.log("CONTROLLER_V3_DRY_RUN_WRITTEN", _controllerV3DryRunPath(), "(input book untouched)");
        bookJson;
    }

    function _controllerV3DryRunPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".controllerV3-dry-run.json");
    }
}
