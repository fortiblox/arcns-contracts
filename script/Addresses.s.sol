// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Salts} from "./lib/Salts.sol";

/// @title Addresses — prints the CREATE2 address book before any broadcast (toolchain.md §4)
/// @notice Only contracts whose init code does not depend on earlier addresses can be predicted from the
///         salt alone; the rest chain from these (the deploy is deterministic end-to-end given the same
///         deployer, ARCNS_* env and the same Safe salt nonce). `predict()` needs no RPC.
contract Addresses is Script {
    function predict() external view {
        console2.log("CREATE2 factory", Salts.CREATE2_FACTORY);
        string[9] memory names = [
            "EnsBootstrap",
            "ArcNSTimelock",
            "GatewayProvider",
            "UniversalResolver",
            "ArcNSPriceOracle",
            "TldDirectory",
            "HandleRegistry",
            "ArcNSResolver",
            "HandleController"
        ];
        for (uint256 i = 0; i < names.length; i++) {
            console2.log(names[i], "salt", vm.toString(Salts.forName(names[i])));
        }
        console2.log("TldRegistrar:arc salt", vm.toString(Salts.ofTld("TldRegistrar", "arc")));
        console2.log("TldRegistrarController:arc salt", vm.toString(Salts.ofTld("TldRegistrarController", "arc")));
        console2.log("TldRegistrar:circle salt", vm.toString(Salts.ofTld("TldRegistrar", "circle")));
        console2.log("TldRegistrarController:circle salt", vm.toString(Salts.ofTld("TldRegistrarController", "circle")));
        console2.log(
            "address = keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:]; initCode = creation bytecode ++ abi.encode(constructor args)"
        );
    }
}
