// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {MarketGrantLib} from "./MarketGrantLib.sol";

/// @title MarketScriptBase — address-book plumbing shared by the three WP-7632 market scripts
/// @notice Which JSON file each phase reads and writes (`docs/runbooks/market-deploy.md` §1):
///
///           input book   ARCNS_ADDRESS_BOOK if set (e.g. `deployments/5042002.json` for a fork rehearsal
///                        against the LIVE M1/M2 book), else `deployments/<chainId>.dry-run.json` when
///                        ARCNS_DRY_RUN=1, else `deployments/<chainId>.json`.
///           market book  the `.market` object: read from the input book when present (a broadcast phase 1
///                        appended it), else from `deployments/<chainId>.market-dry-run.json` (a rehearsed
///                        phase 1 wrote it there) — never from anywhere else.
///           live write   only a real `forge script --broadcast` / `--resume` with ARCNS_DRY_RUN unset
///                        may touch the input book; every other run (simulation, `--rpc-url` without
///                        `--broadcast`, ARCNS_DRY_RUN=1) writes `deployments/<chainId>.market-dry-run.json`
///                        so a rehearsal can never overwrite `deployments/5042002.json`.
abstract contract MarketScriptBase is Script {
    function _bookPath() internal view returns (string memory) {
        string memory explicit = vm.envOr("ARCNS_ADDRESS_BOOK", string(""));
        if (bytes(explicit).length != 0) return explicit;
        string memory suffix = vm.envOr("ARCNS_DRY_RUN", false) ? ".dry-run.json" : ".json";
        return string.concat("deployments/", vm.toString(block.chainid), suffix);
    }

    function _marketDryRunPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".market-dry-run.json");
    }

    function _grantPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".market-grant.json");
    }

    /// @dev Same path `DeployControllerV2.s.sol`'s own private `_controllerV2DryRunPath()` computes —
    ///      duplicated (not shared) deliberately: that script pre-dates this helper and its copy is
    ///      non-`virtual`, so a shared name here would collide as an accidental override.
    function _controllerV2RehearsalPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".controllerV2-dry-run.json");
    }

    function _cutoverPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".controllerV2-cutover.json");
    }

    /// @dev Same shape as `_readMarketBook`, for `.controllerV2` instead of `.market` — shared by
    ///      `VerifyControllerV2.s.sol` and `GrantControllerV2.s.sol` so both scripts pick the SAME V2
    ///      address book (the live book once `DeployControllerV2` broadcasts, else the rehearsal file).
    function _readControllerV2Book(string memory bookJson, string memory bookPath)
        internal
        view
        returns (string memory json, string memory path)
    {
        if (vm.keyExistsJson(bookJson, ".controllerV2")) return (bookJson, bookPath);
        path = _controllerV2RehearsalPath();
        require(
            vm.exists(path),
            string.concat("controllerV2 address book missing: no .controllerV2 in ", bookPath, " and no ", path)
        );
        return (vm.readFile(path), path);
    }

    /// @dev True only when this run may append to the input book (see the title NatSpec).
    function _isLiveWrite() internal view returns (bool) {
        if (vm.envOr("ARCNS_DRY_RUN", false)) return false;
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    /// @dev Returns the JSON holding the `.market` object and the path it came from (for the logs).
    function _readMarketBook(string memory bookJson, string memory bookPath)
        internal
        view
        returns (string memory json, string memory path)
    {
        if (vm.keyExistsJson(bookJson, ".market")) return (bookJson, bookPath);
        path = _marketDryRunPath();
        require(
            vm.exists(path),
            string.concat(
                "market address book missing: no .market in ", bookPath, " and no ", path, " (run phase 1 first)"
            )
        );
        return (vm.readFile(path), path);
    }

    /// @dev Serialises one Safe `execTransaction` (plain call, no gas refund fields, the given signature
    ///      bytes) under `key`, plus the fully encoded `execTransactionCalldata` — shared by phases 2 and 4.
    function _serializeSafeTx(string memory key, address to, bytes memory data, bytes memory sig)
        internal
        returns (string memory)
    {
        vm.serializeAddress(key, "to", to);
        vm.serializeUint(key, "value", 0);
        vm.serializeBytes(key, "data", data);
        vm.serializeUint(key, "operation", MarketGrantLib.SAFE_OPERATION_CALL);
        vm.serializeUint(key, "safeTxGas", 0);
        vm.serializeUint(key, "baseGas", 0);
        vm.serializeUint(key, "gasPrice", 0);
        vm.serializeAddress(key, "gasToken", address(0));
        vm.serializeAddress(key, "refundReceiver", address(0));
        vm.serializeBytes(key, "signatures", sig);
        return
            vm.serializeBytes(key, "execTransactionCalldata", MarketGrantLib.safeExecTransactionCalldata(to, data, sig));
    }

    function _stateName(TimelockController.OperationState st) internal pure returns (string memory) {
        if (st == TimelockController.OperationState.Unset) return "Unset";
        if (st == TimelockController.OperationState.Waiting) return "Waiting";
        if (st == TimelockController.OperationState.Ready) return "Ready";
        return "Done";
    }

    function _requireAddr(address a, string memory what) internal pure {
        require(a != address(0), string.concat("address book incomplete: ", what));
    }

    function _logBook(string memory role, string memory path) internal pure {
        console2.log(string.concat(role, " ", path));
    }
}
