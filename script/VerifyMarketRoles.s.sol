// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ArcNSConstants} from "../src/lib/ArcNSConstants.sol";
import {MarketScriptBase} from "./lib/MarketScriptBase.sol";

interface IMarketView {
    function isCollectionAllowed(address collection) external view returns (bool);
    function treasury() external view returns (address);
    function nameLocks() external view returns (address);
    function paused() external view returns (bool);
}

interface INameLocksView {
    function unlockTimelock() external view returns (uint64);
}

/// @title VerifyMarketRoles — WP-7632 phase 3: INV-8 parity for the M3 stack, MARKET_ROLE included
/// @notice Read-only, no key. The market-stack counterpart of `VerifyRoles.s.sol` (SR-61): reads the
///         M1/M2 book + the `.market` object (from the book, or from
///         `deployments/<chainId>.market-dry-run.json` in a rehearsal), checks every line below and
///         prints exactly one final marker — `ROLES_VERIFIED`, or `ROLES_FAILED` after one `FAIL` line
///         per broken invariant (the precise diff, e.g. before phase 2 has executed:
///         `FAIL  HandleRegistry 0x520e…: MARKET_ROLE not granted to ArcNSMarket 0x…`).
///
///         Checks: code present at all seven market addresses; deployer holds no `DEFAULT_ADMIN_ROLE`
///         and the timelock holds it on `ArcNSMarket`, `NameLocks`, `AttestationRegistry`,
///         `IntegratorRegistry`; `PAUSER_ROLE` on the market = Admin Safe; `treasury` and `nameLocks`
///         wiring; every collection (HandleRegistry + each `tlds.<label>.BaseRegistrar`) allow-listed;
///         `NameLocks.unlockTimelock() >= 7 days` (SR-14); `HandleRegistry.hasRole(MARKET_ROLE, market)`
///         (the phase-2 governance op has executed); market not paused (reported, not failed).
///
///           ARCNS_ADDRESS_BOOK=deployments/5042002.json forge script script/VerifyMarketRoles.s.sol --rpc-url $ARC_RPC_URL
contract VerifyMarketRoles is MarketScriptBase {
    bytes32 internal constant ADMIN = 0x00;

    struct Inputs {
        address deployer;
        address timelock;
        address adminSafe;
        address treasury;
        address handleRegistry;
        address[] collections; // HandleRegistry first, then every TLD BaseRegistrar
        address market;
        address nameLocks;
        address recordDelegate;
        address textRecords;
        address attestations;
        address integrators;
        address vouchers;
    }

    bool internal ok = true;
    string[] internal failures;

    function run() external {
        string memory bookPath = _bookPath();
        string memory book = vm.readFile(bookPath);
        (string memory marketJson, string memory marketPath) = _readMarketBook(book, bookPath);
        _logBook("ADDRESS_BOOK", bookPath);
        _logBook("MARKET_BOOK", marketPath);

        Inputs memory i;
        i.deployer = vm.parseJsonAddress(book, ".deployer");
        i.timelock = vm.parseJsonAddress(book, ".TimelockController");
        i.adminSafe = vm.parseJsonAddress(book, ".AdminSafe");
        i.treasury = vm.parseJsonAddress(book, ".treasury");
        i.handleRegistry = vm.parseJsonAddress(book, ".HandleRegistry");
        string[] memory labels = vm.parseJsonKeys(book, ".tlds");
        i.collections = new address[](1 + labels.length);
        i.collections[0] = i.handleRegistry;
        for (uint256 k = 0; k < labels.length; k++) {
            i.collections[1 + k] = vm.parseJsonAddress(book, string.concat(".tlds.", labels[k], ".BaseRegistrar"));
        }
        i.market = vm.parseJsonAddress(marketJson, ".market.ArcNSMarket");
        i.nameLocks = vm.parseJsonAddress(marketJson, ".market.NameLocks");
        i.recordDelegate = vm.parseJsonAddress(marketJson, ".market.RecordDelegate");
        i.textRecords = vm.parseJsonAddress(marketJson, ".market.TextRecords");
        i.attestations = vm.parseJsonAddress(marketJson, ".market.AttestationRegistry");
        i.integrators = vm.parseJsonAddress(marketJson, ".market.IntegratorRegistry");
        i.vouchers = vm.parseJsonAddress(marketJson, ".market.Vouchers");

        bool passed = verify(i);
        console2.log(passed ? "ROLES_VERIFIED" : "ROLES_FAILED");
        require(passed, "ROLES_FAILED");
    }

    /// @dev The whole check as one call over explicit addresses (no file I/O) so `test/market/MarketGrant.t.sol`
    ///      runs it before and after the timelock op. Returns `true` iff every check passed; `failures()`
    ///      lists each failed line.
    function verify(Inputs memory i) public returns (bool) {
        ok = true;
        delete failures;

        bool marketCode = _code(i.market, "ArcNSMarket");
        bool locksCode = _code(i.nameLocks, "NameLocks");
        _code(i.recordDelegate, "RecordDelegate");
        _code(i.textRecords, "TextRecords");
        bool attCode = _code(i.attestations, "AttestationRegistry");
        bool intCode = _code(i.integrators, "IntegratorRegistry");
        _code(i.vouchers, "Vouchers");

        if (marketCode) {
            _admin(i.market, "ArcNSMarket", i);
            _check(
                IAccessControl(i.market).hasRole(ArcNSConstants.PAUSER_ROLE, i.adminSafe),
                "ArcNSMarket: PAUSER_ROLE = AdminSafe"
            );
            _check(IMarketView(i.market).treasury() == i.treasury, "ArcNSMarket: treasury = book treasury");
            _check(IMarketView(i.market).nameLocks() == i.nameLocks, "ArcNSMarket: nameLocks = book NameLocks");
            for (uint256 k = 0; k < i.collections.length; k++) {
                _check(
                    IMarketView(i.market).isCollectionAllowed(i.collections[k]),
                    string.concat(
                        "ArcNSMarket: collection allow-listed ", Strings.toChecksumHexString(i.collections[k])
                    )
                );
            }
            if (IMarketView(i.market).paused()) {
                console2.log("NOTE ArcNSMarket is paused (guardian action, not a role fault)");
            }
        }
        if (locksCode) {
            _admin(i.nameLocks, "NameLocks", i);
            _check(
                INameLocksView(i.nameLocks).unlockTimelock() >= 7 days, "NameLocks: unlockTimelock >= 7 days (SR-14)"
            );
        }
        if (attCode) _admin(i.attestations, "AttestationRegistry", i);
        if (intCode) _admin(i.integrators, "IntegratorRegistry", i);

        // The phase-2 governance grant. HandleRegistry is live from M1, so this line is meaningful even
        // when the market itself is only predicted (rehearsal): it reports exactly what is still missing.
        _check(
            IAccessControl(i.handleRegistry).hasRole(ArcNSConstants.MARKET_ROLE, i.market),
            string.concat(
                "HandleRegistry ",
                Strings.toChecksumHexString(i.handleRegistry),
                ": MARKET_ROLE granted to ArcNSMarket ",
                Strings.toChecksumHexString(i.market)
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

    function _admin(address a, string memory name, Inputs memory i) internal {
        _check(!IAccessControl(a).hasRole(ADMIN, i.deployer), string.concat(name, ": deployer has no admin"));
        _check(IAccessControl(a).hasRole(ADMIN, i.timelock), string.concat(name, ": timelock is admin"));
    }

    function _check(bool cond, string memory what) internal {
        console2.log(cond ? "  ok   " : "  FAIL ", what);
        if (!cond) failures.push(what);
        ok = ok && cond;
    }
}
