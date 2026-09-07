// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ArcNSConstants} from "../src/lib/ArcNSConstants.sol";

interface IOwned {
    function owner() external view returns (address);
}

interface IGenesis {
    function genesisSealed() external view returns (bool);
}

/// @title VerifyRoles — SR-61 / INV-8 read-only assertion over `deployments/<chainId>.json`
/// @notice Prints exactly one final marker: `ROLES_VERIFIED` or `ROLES_FAILED` (Operating Agreement §3).
///         Run after DeployAll (GENESIS_ROLE still held by the deployer — reported, not failed) and again
///         after genesis seal (GENESIS_ROLE must then be empty for the deployer).
///           forge script script/VerifyRoles.s.sol --rpc-url $ARC_RPC_URL
contract VerifyRoles is Script {
    bytes32 internal constant ADMIN = 0x00;

    string internal json;
    address internal deployer;
    address internal timelock;
    bool internal ok = true;

    function run() external {
        string memory suffix = vm.envOr("ARCNS_DRY_RUN", false) ? ".dry-run.json" : ".json";
        json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), suffix));
        deployer = vm.parseJsonAddress(json, ".deployer");
        timelock = vm.parseJsonAddress(json, ".TimelockController");
        _checkTimelock();
        _checkAccessControl("ArcNSPriceOracle");
        _checkAccessControl("TldDirectory");
        _checkAccessControl("HandleRegistry");
        _checkAccessControl("ArcNSResolver");
        _checkAccessControl("HandleController");
        _checkOwned("Root");
        _checkOwned("ReverseRegistrar");
        _checkOwned("GatewayProvider");
        _genesisCheck(vm.parseJsonAddress(json, ".HandleController"), "HandleController");
        _checkTlds();
        console2.log(ok ? "ROLES_VERIFIED" : "ROLES_FAILED");
        require(ok, "ROLES_FAILED");
    }

    function _checkTimelock() internal {
        uint256 delay = vm.parseJsonUint(json, ".timelockDelay");
        _check(TimelockController(payable(timelock)).getMinDelay() == delay, "timelock delay matches");
        if (block.chainid != ArcNSConstants.ARC_TESTNET_CHAIN_ID) _check(delay >= 48 hours, "delay >= 48h");
    }

    function _checkAccessControl(string memory name) internal {
        address a = vm.parseJsonAddress(json, string.concat(".", name));
        _check(!IAccessControl(a).hasRole(ADMIN, deployer), string.concat(name, ": deployer has no admin"));
        _check(IAccessControl(a).hasRole(ADMIN, timelock), string.concat(name, ": timelock is admin"));
    }

    function _checkOwned(string memory name) internal {
        address a = vm.parseJsonAddress(json, string.concat(".", name));
        _check(IOwned(a).owner() == timelock, string.concat(name, " owner = timelock"));
    }

    function _checkTlds() internal {
        string[] memory labels = vm.parseJsonKeys(json, ".tlds");
        for (uint256 i = 0; i < labels.length; i++) {
            string memory base = string.concat(".tlds.", labels[i]);
            address ctl = vm.parseJsonAddress(json, string.concat(base, ".Controller"));
            address reg = vm.parseJsonAddress(json, string.concat(base, ".BaseRegistrar"));
            _check(
                !IAccessControl(ctl).hasRole(ADMIN, deployer),
                string.concat(labels[i], " controller: deployer no admin")
            );
            _check(
                IAccessControl(ctl).hasRole(ADMIN, timelock), string.concat(labels[i], " controller: timelock admin")
            );
            _check(IOwned(reg).owner() == timelock, string.concat(labels[i], " registrar owner = timelock"));
            _genesisCheck(ctl, string.concat(labels[i], " controller"));
        }
    }

    function _genesisCheck(address ctl, string memory name) internal {
        bool isSealed = IGenesis(ctl).genesisSealed();
        bool hasGenesis = IAccessControl(ctl).hasRole(ArcNSConstants.GENESIS_ROLE, deployer);
        if (isSealed) {
            _check(!hasGenesis, string.concat(name, ": sealed and GENESIS_ROLE revoked"));
        } else {
            console2.log(
                string.concat(
                    "NOTE ", name, ": genesis not sealed yet; deployer holds GENESIS_ROLE (expected pre-genesis)"
                )
            );
            _check(hasGenesis, string.concat(name, ": deployer holds GENESIS_ROLE pre-seal"));
        }
    }

    function _check(bool cond, string memory what) internal {
        console2.log(cond ? "  ok   " : "  FAIL ", what);
        ok = ok && cond;
    }
}
