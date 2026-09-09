// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {AttestationRegistry} from "../src/parity/AttestationRegistry.sol";
import {IntegratorRegistry} from "../src/parity/IntegratorRegistry.sol";
import {MarketGrantLib} from "./lib/MarketGrantLib.sol";
import {MarketInitLib} from "./lib/MarketInitLib.sol";
import {MarketScriptBase} from "./lib/MarketScriptBase.sol";

/// @title MarketInit — WP-124 phase 4: the governance batch that configures attestors + integrators
/// @notice Read-only. Never signs, never broadcasts, never needs a key — the same shape as phase 2
///         (`GrantMarketRole.s.sol`), for the same reason: `AttestationRegistry.setAttestor` and
///         `IntegratorRegistry.setIntegrator` / `setIntegratorRate` are `DEFAULT_ADMIN_ROLE`-only and
///         phase 1 handed that role to the `TimelockController`. The previous version of this script
///         broadcast those calls from the deployer EOA and reverted on the 2026-09-09 fork rehearsal
///         with `AccessControlUnauthorizedAccount(deployer, 0x00)` — the WP-7632 bug class.
///
///         Reads the address book (`.market.AttestationRegistry`, `.market.IntegratorRegistry`, the
///         timelock and the Admin Safe) and the CEO's config, diffs the config against the LIVE module
///         state (`MarketInitLib.plan`: entries already in the desired state produce no call, so the
///         batch is idempotent and a rerun after execution is empty) and writes
///         `deployments/<chainId>.market-init.json`: the batch (`targets`, `payloads`, one `what` line
///         per call), the op id (cross-checked against the live timelock's `hashOperationBatch`),
///         `scheduleCalldata` / `executeCalldata`, the Safe `execTransaction` inputs for both steps and a
///         `state` object (operation state, whether the Safe is proposer/executor, whether the timelock
///         is admin on both modules, how many calls are still pending).
///
///         Config (`script/config/market-init.json`, or `ARCNS_MARKET_INIT_CONFIG` — must stay under
///         `script/config/`, the only config path `foundry.toml` lets a script read):
///         ```json
///         {
///           "attestors":         ["0x…"],                                   // allow-list (required key, may be empty)
///           "integrators":       [{"address": "0x…", "rateBps": 2500},      // allow-list; rateBps optional,
///                                 {"address": "0x…"}],                       //   <= IntegratorRegistry.CAP_BPS (4000)
///           "revokeAttestors":   ["0x…"],                                   // optional
///           "revokeIntegrators": ["0x…"]                                    // optional
///         }
///         ```
///         Every config error the modules would reject an hour later (rate above cap, zero address,
///         duplicate, allow+revoke of one address) is a revert here, before anything is scheduled.
///
///           ARCNS_ADDRESS_BOOK=deployments/5042002.json forge script script/MarketInit.s.sol --rpc-url $ARC_RPC_URL
///         Markers: `MARKET_INIT_PLAN n calls` … `MARKET_INIT_OPERATION_ID 0x…` … `MARKET_INIT_STATE operation
///         Unset|Waiting|Ready|Done pending n` … `MARKET_INIT_WRITTEN <path>`, or `MARKET_INIT_NOTHING_TO_DO`
///         when the live state already equals the config (no operation is built; the JSON records that).
contract MarketInit is MarketScriptBase {
    struct Ctx {
        string bookPath;
        string marketPath;
        string configPath;
        address timelock;
        address safe;
        address safeOwner;
        AttestationRegistry attestations;
        IntegratorRegistry integrators;
        uint256 delay;
        bool live; // the RPC has code at the timelock: read-backs and the hashOperationBatch cross-check run
    }

    function run() external {
        Ctx memory c = _load();
        MarketInitLib.Desired memory d = _config(c.configPath);
        MarketInitLib.Plan memory plan = MarketInitLib.plan(c.attestations, c.integrators, d);
        console2.log("MARKET_INIT_PLAN", plan.targets.length, "calls");
        for (uint256 i = 0; i < plan.what.length; i++) {
            console2.log("  ", plan.what[i]);
        }

        if (plan.targets.length == 0) {
            console2.log("MARKET_INIT_NOTHING_TO_DO (live state already matches", c.configPath, ")");
            vm.writeJson(_serializeEmpty(c), _initPath());
            console2.log("MARKET_INIT_WRITTEN", _initPath());
            return;
        }

        MarketInitLib.Payload memory p = MarketInitLib.build(plan.targets, plan.payloads, c.delay);
        if (c.live) {
            bytes32 onchainId = TimelockController(payable(c.timelock))
                .hashOperationBatch(p.targets, p.values, p.payloads, p.predecessor, p.salt);
            require(onchainId == p.operationId, "hashOperationBatch mismatch");
        }
        console2.log("MARKET_INIT_TIMELOCK", c.timelock, "delay", c.delay);
        console2.log("MARKET_INIT_SAFE", c.safe, "owner", c.safeOwner);
        console2.log("MARKET_INIT_OPERATION_ID", vm.toString(p.operationId));
        console2.log("MARKET_INIT_SALT", vm.toString(p.salt));
        console2.log("MARKET_INIT_SCHEDULE_CALLDATA", vm.toString(p.scheduleCalldata));
        console2.log("MARKET_INIT_EXECUTE_CALLDATA", vm.toString(p.executeCalldata));

        vm.writeJson(_serialize(p, plan, c), _initPath());
        console2.log("MARKET_INIT_WRITTEN", _initPath());
    }

    function _load() internal returns (Ctx memory c) {
        c.bookPath = _bookPath();
        string memory book = vm.readFile(c.bookPath);
        string memory marketJson;
        (marketJson, c.marketPath) = _readMarketBook(book, c.bookPath);
        c.configPath = vm.envOr("ARCNS_MARKET_INIT_CONFIG", string("script/config/market-init.json"));
        _logBook("ADDRESS_BOOK", c.bookPath);
        _logBook("MARKET_BOOK", c.marketPath);
        _logBook("INIT_CONFIG", c.configPath);

        c.timelock = vm.parseJsonAddress(book, ".TimelockController");
        c.safe = vm.parseJsonAddress(book, ".AdminSafe");
        c.safeOwner = vm.parseJsonAddress(book, ".admin");
        c.attestations = AttestationRegistry(vm.parseJsonAddress(marketJson, ".market.AttestationRegistry"));
        c.integrators = IntegratorRegistry(vm.parseJsonAddress(marketJson, ".market.IntegratorRegistry"));
        _requireAddr(c.timelock, "TimelockController");
        _requireAddr(c.safe, "AdminSafe");
        _requireAddr(c.safeOwner, "admin");
        _requireAddr(address(c.attestations), "market.AttestationRegistry");
        _requireAddr(address(c.integrators), "market.IntegratorRegistry");
        require(
            address(c.attestations).code.length != 0 && address(c.integrators).code.length != 0,
            "MarketInit: no code at the market modules on this RPC (broadcast phase 1 first)"
        );

        c.delay = vm.parseJsonUint(book, ".timelockDelay");
        c.live = c.timelock.code.length != 0;
        if (c.live) {
            uint256 onchain = TimelockController(payable(c.timelock)).getMinDelay();
            require(onchain == c.delay, "timelock minDelay differs from the book's .timelockDelay");
        }
    }

    /// @dev `attestors` and `integrators` are required keys (an empty array is fine); the two `revoke*`
    ///      arrays and each integrator's `rateBps` are optional.
    function _config(string memory path) internal view returns (MarketInitLib.Desired memory d) {
        string memory cfg = vm.readFile(path);
        d.attestors = vm.parseJsonAddressArray(cfg, ".attestors");
        d.revokeAttestors = _optionalAddresses(cfg, ".revokeAttestors");
        d.revokeIntegrators = _optionalAddresses(cfg, ".revokeIntegrators");

        uint256 n;
        while (vm.keyExistsJson(cfg, string.concat(".integrators[", vm.toString(n), "]"))) {
            n++;
        }
        d.integrators = new address[](n);
        d.hasRate = new bool[](n);
        d.rateBps = new uint16[](n);
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".integrators[", vm.toString(i), "]");
            d.integrators[i] = vm.parseJsonAddress(cfg, string.concat(base, ".address"));
            string memory rateKey = string.concat(base, ".rateBps");
            if (vm.keyExistsJson(cfg, rateKey)) {
                uint256 rate = vm.parseJsonUint(cfg, rateKey);
                require(rate <= type(uint16).max, "MarketInit: rateBps does not fit uint16");
                d.hasRate[i] = true;
                d.rateBps[i] = uint16(rate);
            }
        }
    }

    function _optionalAddresses(string memory cfg, string memory key) internal view returns (address[] memory a) {
        if (vm.keyExistsJson(cfg, key)) return vm.parseJsonAddressArray(cfg, key);
        return new address[](0);
    }

    function _serialize(MarketInitLib.Payload memory p, MarketInitLib.Plan memory plan, Ctx memory c)
        internal
        returns (string memory)
    {
        bytes memory sig = MarketGrantLib.safePreValidatedSignature(c.safeOwner);
        string memory sched = _serializeSafeTx("safeSchedule", c.timelock, p.scheduleCalldata, sig);
        string memory exec = _serializeSafeTx("safeExecute", c.timelock, p.executeCalldata, sig);
        string memory state = _state(p.operationId, plan.targets.length, c);

        string memory root = "init";
        _serializeCommon(root, c);
        vm.serializeAddress(root, "targets", p.targets);
        vm.serializeUint(root, "values", p.values);
        vm.serializeBytes(root, "payloads", p.payloads);
        vm.serializeString(root, "what", plan.what);
        vm.serializeBytes32(root, "predecessor", p.predecessor);
        vm.serializeBytes32(root, "salt", p.salt);
        vm.serializeUint(root, "delay", p.delay);
        vm.serializeBytes32(root, "operationId", p.operationId);
        vm.serializeBytes(root, "scheduleCalldata", p.scheduleCalldata);
        vm.serializeBytes(root, "executeCalldata", p.executeCalldata);
        vm.serializeString(root, "safeSchedule", sched);
        vm.serializeString(root, "safeExecute", exec);
        return vm.serializeString(root, "state", state);
    }

    function _serializeEmpty(Ctx memory c) internal returns (string memory) {
        string memory root = "init";
        _serializeCommon(root, c);
        vm.serializeString(root, "what", new string[](0));
        return vm.serializeString(root, "state", _state(bytes32(0), 0, c));
    }

    function _serializeCommon(string memory root, Ctx memory c) internal {
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "sourceBook", c.bookPath);
        vm.serializeString(root, "marketBook", c.marketPath);
        vm.serializeString(root, "config", c.configPath);
        vm.serializeString(root, "workPackage", "WP-124");
        vm.serializeAddress(root, "AttestationRegistry", address(c.attestations));
        vm.serializeAddress(root, "IntegratorRegistry", address(c.integrators));
        vm.serializeAddress(root, "TimelockController", c.timelock);
        vm.serializeAddress(root, "AdminSafe", c.safe);
        vm.serializeAddress(root, "safeOwner", c.safeOwner);
    }

    /// @dev Live read-backs; `operation` is "none" for an empty plan and "no-rpc" without timelock code.
    function _state(bytes32 operationId, uint256 pending, Ctx memory c) internal returns (string memory) {
        string memory key = "state";
        vm.serializeBool(key, "rpc", c.live);
        vm.serializeUint(key, "pendingCalls", pending);
        if (!c.live) return vm.serializeString(key, "operation", "no-rpc");
        TimelockController tl = TimelockController(payable(c.timelock));
        string memory name = pending == 0 ? "none" : _stateName(tl.getOperationState(operationId));
        vm.serializeString(key, "operation", name);
        vm.serializeUint(key, "operationReadyAt", pending == 0 ? 0 : tl.getTimestamp(operationId));
        vm.serializeUint(key, "minDelay", tl.getMinDelay());
        vm.serializeBool(key, "safeIsProposer", tl.hasRole(tl.PROPOSER_ROLE(), c.safe));
        vm.serializeBool(key, "safeIsExecutor", tl.hasRole(tl.EXECUTOR_ROLE(), c.safe));
        vm.serializeBool(
            key, "timelockIsAttestationAdmin", IAccessControl(address(c.attestations)).hasRole(0x00, c.timelock)
        );
        bool intAdmin = IAccessControl(address(c.integrators)).hasRole(0x00, c.timelock);
        console2.log("MARKET_INIT_STATE operation", name, "pending", pending);
        return vm.serializeBool(key, "timelockIsIntegratorAdmin", intAdmin);
    }

    function _initPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".market-init.json");
    }
}
