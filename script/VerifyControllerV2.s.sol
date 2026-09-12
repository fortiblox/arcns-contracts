// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ArcNSConstants} from "../src/lib/ArcNSConstants.sol";
import {MarketScriptBase} from "./lib/MarketScriptBase.sol";

interface IBaseRegistrarView {
    function controllers(address) external view returns (bool);
}

interface ITldDirectoryView {
    function controllerOf(bytes32 tldNode) external view returns (address);
}

/// @title VerifyControllerV2 — WP #7772: read-only role/wiring check for the integrator-v2 cutover
/// @notice Mirrors `VerifyMarketRoles.s.sol`'s pattern exactly: read-only, no key, one `ROLES_VERIFIED`
///         or `ROLES_FAILED` marker at the end, one `FAIL` line per broken invariant naming the precise
///         diff. The invariants checked are the POST-CUTOVER target state:
///           - `HandleRegistry.hasRole(REGISTRAR_ROLE, HandleControllerV2) == true`
///           - `HandleRegistry.hasRole(REGISTRAR_ROLE, HandleController[V1]) == false` (revoked)
///           - each `TldRegistrar.controllers(TldRegistrarControllerV2[tld]) == true`
///           - each `TldRegistrar.controllers(TldRegistrarController[tld][V1]) == false` (removed)
///           - each `TldDirectory.controllerOf(tldNode) == TldRegistrarControllerV2[tld]`
///
/// @dev **As of this branch, NO cutover has run.** `DeployControllerV2.s.sol` only deploys; it grants
///      nothing. Running this script against the current live/rehearsed state is therefore EXPECTED to
///      print `ROLES_FAILED` with a `FAIL` line for every grant above — that is the honest, correct
///      report of "not cut over yet", not a bug in this script. This script exists so that, AFTER a
///      human/Safe has actually run the governance sequence in
///      `deploy/runbooks/integrator-v2-cutover.md`, the SAME command flips to `ROLES_VERIFIED` with no
///      code change here — exactly how `VerifyMarketRoles.s.sol` behaves across its own phase 2.
///
///        ARCNS_ADDRESS_BOOK=deployments/5042002.json forge script script/VerifyControllerV2.s.sol --rpc-url $ARC_RPC_URL
contract VerifyControllerV2 is MarketScriptBase {
    bytes32 internal constant REGISTRAR_ROLE = ArcNSConstants.REGISTRAR_ROLE;

    struct Inputs {
        address handleRegistry;
        address handleControllerV1;
        address handleControllerV2;
        string[] tldLabels;
        address[] registrars; // BaseRegistrar per label
        address[] controllersV1; // TldRegistrarController (V1) per label
        address[] controllersV2; // TldRegistrarControllerV2 per label
        address directory;
        bytes32[] tldNodes;
    }

    bool internal ok = true;
    string[] internal failures;

    function run() external {
        string memory bookPath = _bookPath();
        string memory book = vm.readFile(bookPath);
        (string memory cv2Json, string memory cv2Path) = _readControllerV2Book(book, bookPath);
        _logBook("ADDRESS_BOOK", bookPath);
        _logBook("CONTROLLER_V2_BOOK", cv2Path);

        Inputs memory i = _inputs(book, cv2Json);
        bool passed = verify(i);
        console2.log(passed ? "ROLES_VERIFIED" : "ROLES_FAILED");
        require(passed, "ROLES_FAILED");
    }

    /// @dev Same shape as `MarketScriptBase._readMarketBook`, for `.controllerV2` instead of `.market`.
    function _readControllerV2Book(string memory bookJson, string memory bookPath)
        internal
        view
        returns (string memory json, string memory path)
    {
        if (vm.keyExistsJson(bookJson, ".controllerV2")) return (bookJson, bookPath);
        path = string.concat("deployments/", vm.toString(block.chainid), ".controllerV2-dry-run.json");
        require(
            vm.exists(path),
            string.concat("controllerV2 address book missing: no .controllerV2 in ", bookPath, " and no ", path)
        );
        return (vm.readFile(path), path);
    }

    function _inputs(string memory book, string memory cv2Json) internal pure returns (Inputs memory i) {
        i.handleRegistry = vm.parseJsonAddress(book, ".HandleRegistry");
        i.handleControllerV1 = vm.parseJsonAddress(book, ".HandleController");
        i.handleControllerV2 = vm.parseJsonAddress(cv2Json, ".controllerV2.HandleControllerV2");
        i.directory = vm.parseJsonAddress(book, ".TldDirectory");

        string[] memory labels = new string[](2);
        labels[0] = "arc";
        labels[1] = "circle";
        i.tldLabels = labels;

        i.registrars = new address[](2);
        i.controllersV1 = new address[](2);
        i.controllersV2 = new address[](2);
        i.tldNodes = new bytes32[](2);

        i.registrars[0] = vm.parseJsonAddress(book, ".tlds.arc.BaseRegistrar");
        i.controllersV1[0] = vm.parseJsonAddress(book, ".tlds.arc.Controller");
        i.controllersV2[0] = vm.parseJsonAddress(cv2Json, ".controllerV2.TldRegistrarControllerV2Arc");
        i.tldNodes[0] = vm.parseJsonBytes32(book, ".tlds.arc.node");

        i.registrars[1] = vm.parseJsonAddress(book, ".tlds.circle.BaseRegistrar");
        i.controllersV1[1] = vm.parseJsonAddress(book, ".tlds.circle.Controller");
        i.controllersV2[1] = vm.parseJsonAddress(cv2Json, ".controllerV2.TldRegistrarControllerV2Circle");
        i.tldNodes[1] = vm.parseJsonBytes32(book, ".tlds.circle.node");
    }

    /// @dev The whole check as one call over explicit inputs (no file I/O), so a test can run it before
    ///      and after a simulated cutover, mirroring `VerifyMarketRoles.verify`.
    function verify(Inputs memory i) public returns (bool) {
        ok = true;
        delete failures;

        bool handleV2Code = _code(i.handleControllerV2, "HandleControllerV2");
        if (handleV2Code) {
            _check(
                IAccessControl(i.handleRegistry).hasRole(REGISTRAR_ROLE, i.handleControllerV2),
                string.concat(
                    "HandleRegistry: REGISTRAR_ROLE granted to HandleControllerV2 ",
                    Strings.toChecksumHexString(i.handleControllerV2)
                )
            );
        }
        _check(
            !IAccessControl(i.handleRegistry).hasRole(REGISTRAR_ROLE, i.handleControllerV1),
            string.concat(
                "HandleRegistry: REGISTRAR_ROLE revoked from HandleController[V1] ",
                Strings.toChecksumHexString(i.handleControllerV1)
            )
        );

        for (uint256 k = 0; k < i.tldLabels.length; k++) {
            string memory label = i.tldLabels[k];
            bool v2Code = _code(i.controllersV2[k], string.concat("TldRegistrarControllerV2[", label, "]"));
            if (v2Code) {
                _check(
                    IBaseRegistrarView(i.registrars[k]).controllers(i.controllersV2[k]),
                    string.concat(
                        "TldRegistrar[",
                        label,
                        "]: controller added for TldRegistrarControllerV2 ",
                        Strings.toChecksumHexString(i.controllersV2[k])
                    )
                );
                _check(
                    ITldDirectoryView(i.directory).controllerOf(i.tldNodes[k]) == i.controllersV2[k],
                    string.concat("TldDirectory[", label, "]: controllerOf == TldRegistrarControllerV2")
                );
            }
            _check(
                !IBaseRegistrarView(i.registrars[k]).controllers(i.controllersV1[k]),
                string.concat(
                    "TldRegistrar[",
                    label,
                    "]: controller removed for TldRegistrarController[V1] ",
                    Strings.toChecksumHexString(i.controllersV1[k])
                )
            );
        }
        return ok;
    }

    function failureCount() external view returns (uint256) {
        return failures.length;
    }

    function failure(uint256 k) external view returns (string memory) {
        return failures[k];
    }

    function _code(address a, string memory name) internal returns (bool present) {
        present = a != address(0) && a.code.length != 0;
        _check(present, string.concat(name, " ", Strings.toChecksumHexString(a), ": code present (deploy step ran)"));
    }

    function _check(bool cond, string memory what) internal {
        console2.log(cond ? "  ok   " : "  FAIL ", what);
        if (!cond) failures.push(what);
        ok = ok && cond;
    }
}
