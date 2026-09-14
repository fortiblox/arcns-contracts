// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ArcNSConstants} from "../src/lib/ArcNSConstants.sol";
import {NameGiftsScriptBase} from "./lib/NameGiftsScriptBase.sol";

interface INameGiftsView {
    function isCollectionAllowed(address collection) external view returns (bool);
}

/// @title VerifyNameGiftsRoles — M3b phase 3: INV-8 parity for `NameGifts`, MARKET_ROLE included
/// @notice Read-only, no key. Sibling of `VerifyMarketRoles.s.sol`: reads the M1/M2 book + the
///         `.nameGifts` object (from the book, or from `deployments/<chainId>.nameGifts-dry-run.json`
///         in a rehearsal), checks every line below and prints exactly one final marker —
///         `NAME_GIFTS_ROLES_VERIFIED`, or `NAME_GIFTS_ROLES_FAILED` after one `FAIL` line per broken
///         invariant. This is the hard deploy-verification gate for the exact failure mode the M3b
///         brief calls out: "forgot to grant MARKET_ROLE" silently narrows gifting to tokenized handles
///         only — this script's `HandleRegistry.hasRole(MARKET_ROLE, nameGifts)` line is the one check
///         that catches it before launch.
///
///         Checks: code present at `NameGifts`; deployer holds no `DEFAULT_ADMIN_ROLE` and the timelock
///         holds it; every collection (HandleRegistry + each `tlds.<label>.BaseRegistrar`) allow-listed;
///         `HandleRegistry.hasRole(MARKET_ROLE, nameGifts)` (the phase-2 governance op has executed).
///
///           ARCNS_ADDRESS_BOOK=deployments/5042002.json forge script script/VerifyNameGiftsRoles.s.sol --rpc-url $ARC_RPC_URL
contract VerifyNameGiftsRoles is NameGiftsScriptBase {
    bytes32 internal constant ADMIN = 0x00;

    struct Inputs {
        address deployer;
        address timelock;
        address handleRegistry;
        address[] collections; // HandleRegistry first, then every TLD BaseRegistrar
        address nameGifts;
    }

    bool internal ok = true;
    string[] internal failures;

    function run() external {
        string memory bookPath = _bookPath();
        string memory book = vm.readFile(bookPath);
        (string memory nameGiftsJson, string memory nameGiftsPath) = _readNameGiftsBook(book, bookPath);
        _logBook("ADDRESS_BOOK", bookPath);
        _logBook("NAME_GIFTS_BOOK", nameGiftsPath);

        Inputs memory i;
        i.deployer = vm.parseJsonAddress(book, ".deployer");
        i.timelock = vm.parseJsonAddress(book, ".TimelockController");
        i.handleRegistry = vm.parseJsonAddress(book, ".HandleRegistry");
        string[] memory labels = vm.parseJsonKeys(book, ".tlds");
        i.collections = new address[](1 + labels.length);
        i.collections[0] = i.handleRegistry;
        for (uint256 k = 0; k < labels.length; k++) {
            i.collections[1 + k] = vm.parseJsonAddress(book, string.concat(".tlds.", labels[k], ".BaseRegistrar"));
        }
        i.nameGifts = vm.parseJsonAddress(nameGiftsJson, ".nameGifts.NameGifts");

        bool passed = verify(i);
        console2.log(passed ? "NAME_GIFTS_ROLES_VERIFIED" : "NAME_GIFTS_ROLES_FAILED");
        require(passed, "NAME_GIFTS_ROLES_FAILED");
    }

    /// @dev The whole check as one call over explicit addresses (no file I/O), same shape
    ///      `VerifyMarketRoles.verify` uses, so a future `test/market/NameGiftsGrant.t.sol` can run it
    ///      before and after the timelock op the same way `test/market/MarketGrant.t.sol` does.
    function verify(Inputs memory i) public returns (bool) {
        ok = true;
        delete failures;

        bool nameGiftsCode = _code(i.nameGifts, "NameGifts");
        if (nameGiftsCode) {
            _check(!IAccessControl(i.nameGifts).hasRole(ADMIN, i.deployer), "NameGifts: deployer has no admin");
            _check(IAccessControl(i.nameGifts).hasRole(ADMIN, i.timelock), "NameGifts: timelock is admin");
            for (uint256 k = 0; k < i.collections.length; k++) {
                _check(
                    INameGiftsView(i.nameGifts).isCollectionAllowed(i.collections[k]),
                    string.concat("NameGifts: collection allow-listed ", Strings.toChecksumHexString(i.collections[k]))
                );
            }
        }

        // The phase-2 governance grant — the check that catches a missed MARKET_ROLE grant before it
        // ships. HandleRegistry is live from M1, so this line is meaningful even when NameGifts itself
        // is only predicted (rehearsal): it reports exactly what is still missing.
        _check(
            IAccessControl(i.handleRegistry).hasRole(ArcNSConstants.MARKET_ROLE, i.nameGifts),
            string.concat(
                "HandleRegistry ",
                Strings.toChecksumHexString(i.handleRegistry),
                ": MARKET_ROLE granted to NameGifts ",
                Strings.toChecksumHexString(i.nameGifts)
            )
        );
        _check(
            !IAccessControl(i.handleRegistry).hasRole(ArcNSConstants.MARKET_ROLE, i.deployer),
            "HandleRegistry: deployer has no MARKET_ROLE"
        );
        _check(IAccessControl(i.handleRegistry).hasRole(ADMIN, i.timelock), "HandleRegistry: timelock is admin");
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
        _check(present, string.concat(name, " ", Strings.toChecksumHexString(a), ": code present (phase 1 broadcast)"));
    }

    function _check(bool cond, string memory what) internal {
        console2.log(cond ? "  ok   " : "  FAIL ", what);
        if (!cond) failures.push(what);
        ok = ok && cond;
    }
}
