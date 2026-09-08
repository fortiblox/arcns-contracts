// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ArcNSConstants} from "../src/lib/ArcNSConstants.sol";
import {MarketGrantLib} from "./lib/MarketGrantLib.sol";
import {MarketScriptBase} from "./lib/MarketScriptBase.sol";

interface ISafeView {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
}

/// @title GrantMarketRole — WP-7632 phase 2: the governance payload for `HandleRegistry.grantRole(MARKET_ROLE, market)`
/// @notice Read-only. Never signs, never broadcasts, never needs a key. Given the address book (M1/M2
///         governance + the `.market` object phase 1 wrote), prints and writes to
///         `deployments/<chainId>.market-grant.json` everything the CEO's Safe shell script needs to run
///         the timelocked grant from the Admin Safe — the same path the .arc TLD activation recovery used:
///
///           AdminSafe.execTransaction(timelock, 0, schedule(...), Call, …, preValidatedSig)   ← t0
///           wait minDelay (3600 s on Arc testnet; `TimelockController.getMinDelay()` is read live)
///           AdminSafe.execTransaction(timelock, 0, execute(...),  Call, …, preValidatedSig)   ← t0 + 1 h
///
///         Output fields (all hex-encoded where bytes): the inner call (`target`,`value`,`data`,
///         `predecessor`,`salt`,`delay`), the operation id (`hashOperation`, cross-checked against the
///         live timelock when the RPC has it), `scheduleCalldata` / `executeCalldata` (what the Safe sends
///         to the timelock), the Safe `execTransaction` inputs for both steps and the fully encoded
///         `execTransactionCalldata`, plus a `state` object with the live read-backs (operation state,
///         whether MARKET_ROLE is already granted, whether the Safe holds PROPOSER/EXECUTOR, Safe owners
///         and threshold) so the runbook can tell "not scheduled yet" from "waiting" from "done".
///
///         Pre-validated signature: valid only when the Safe has threshold 1 and `execTransaction` is
///         sent BY the owner encoded in it (the book's `.admin`, DeployAll's ARCNS_ADMIN). Anything else
///         (mainnet 2-of-3, WP-133) signs the Safe tx hash instead; the calldata fields stay valid.
///
///           ARCNS_ADDRESS_BOOK=deployments/5042002.json forge script script/GrantMarketRole.s.sol --rpc-url $ARC_RPC_URL
///         The `.market` object comes from the book when phase 1 broadcast, else from
///         `deployments/<chainId>.market-dry-run.json` (rehearsal). No `--broadcast`, no `--sender` needed.
contract GrantMarketRole is MarketScriptBase {
    struct Ctx {
        string bookPath;
        string marketPath;
        address handleRegistry;
        address timelock;
        address safe;
        address safeOwner;
        address market;
        uint256 delay;
        bool live; // the RPC (fork or live chain) has code at the timelock: read-backs are meaningful
    }

    function run() external {
        Ctx memory c = _load();
        MarketGrantLib.Payload memory p = MarketGrantLib.build(c.handleRegistry, c.market, c.delay);
        if (c.live) {
            bytes32 onchainId =
                TimelockController(payable(c.timelock)).hashOperation(p.target, p.value, p.data, p.predecessor, p.salt);
            require(onchainId == p.operationId, "hashOperation mismatch");
        }

        console2.log("GRANT_TARGET HandleRegistry", c.handleRegistry);
        console2.log("GRANT_MARKET ArcNSMarket", c.market);
        console2.log("GRANT_TIMELOCK", c.timelock, "delay", c.delay);
        console2.log("GRANT_SAFE", c.safe, "owner", c.safeOwner);
        console2.log("GRANT_OPERATION_ID", vm.toString(p.operationId));
        console2.log("GRANT_INNER_CALLDATA", vm.toString(p.data));
        console2.log("GRANT_SALT", vm.toString(p.salt));
        console2.log("GRANT_SCHEDULE_CALLDATA", vm.toString(p.scheduleCalldata));
        console2.log("GRANT_EXECUTE_CALLDATA", vm.toString(p.executeCalldata));

        vm.writeJson(_serialize(p, c), _grantPath());
        console2.log("MARKET_GRANT_WRITTEN", _grantPath());
    }

    function _load() internal returns (Ctx memory c) {
        c.bookPath = _bookPath();
        string memory book = vm.readFile(c.bookPath);
        string memory marketJson;
        (marketJson, c.marketPath) = _readMarketBook(book, c.bookPath);
        _logBook("ADDRESS_BOOK", c.bookPath);
        _logBook("MARKET_BOOK", c.marketPath);

        c.handleRegistry = vm.parseJsonAddress(book, ".HandleRegistry");
        c.timelock = vm.parseJsonAddress(book, ".TimelockController");
        c.safe = vm.parseJsonAddress(book, ".AdminSafe");
        c.safeOwner = vm.parseJsonAddress(book, ".admin");
        c.market = vm.parseJsonAddress(marketJson, ".market.ArcNSMarket");
        _requireAddr(c.handleRegistry, "HandleRegistry");
        _requireAddr(c.timelock, "TimelockController");
        _requireAddr(c.safe, "AdminSafe");
        _requireAddr(c.safeOwner, "admin");
        _requireAddr(c.market, "market.ArcNSMarket");

        // Delay: the live timelock when the RPC has it (fork or live), cross-checked against the book.
        c.delay = vm.parseJsonUint(book, ".timelockDelay");
        c.live = c.timelock.code.length != 0;
        if (c.live) {
            uint256 onchain = TimelockController(payable(c.timelock)).getMinDelay();
            require(onchain == c.delay, "timelock minDelay differs from the book's .timelockDelay");
        }
    }

    function _serialize(MarketGrantLib.Payload memory p, Ctx memory c) internal returns (string memory) {
        bytes memory sig = MarketGrantLib.safePreValidatedSignature(c.safeOwner);
        string memory sched = _safeTx("safeSchedule", c.timelock, p.scheduleCalldata, sig);
        string memory exec = _safeTx("safeExecute", c.timelock, p.executeCalldata, sig);
        string memory state = _state(p, c);

        string memory root = "grant";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "sourceBook", c.bookPath);
        vm.serializeString(root, "marketBook", c.marketPath);
        vm.serializeString(root, "workPackage", "WP-7632");
        vm.serializeAddress(root, "HandleRegistry", c.handleRegistry);
        vm.serializeAddress(root, "ArcNSMarket", c.market);
        vm.serializeAddress(root, "TimelockController", c.timelock);
        vm.serializeAddress(root, "AdminSafe", c.safe);
        vm.serializeAddress(root, "safeOwner", c.safeOwner);
        vm.serializeBytes32(root, "role", ArcNSConstants.MARKET_ROLE);
        vm.serializeAddress(root, "target", p.target);
        vm.serializeUint(root, "value", p.value);
        vm.serializeBytes(root, "data", p.data);
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

    function _safeTx(string memory key, address to, bytes memory data, bytes memory sig)
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

    /// @dev Live read-backs; `operation` is "no-rpc" and every flag `false` when the RPC has no code there.
    function _state(MarketGrantLib.Payload memory p, Ctx memory c) internal returns (string memory) {
        string memory key = "state";
        vm.serializeBool(key, "rpc", c.live);
        if (!c.live) {
            vm.serializeString(key, "operation", "no-rpc");
            return vm.serializeBool(key, "marketRoleGranted", false);
        }
        TimelockController tl = TimelockController(payable(c.timelock));
        string memory name = _stateName(tl.getOperationState(p.operationId));
        vm.serializeString(key, "operation", name);
        vm.serializeUint(key, "operationReadyAt", tl.getTimestamp(p.operationId));
        vm.serializeUint(key, "minDelay", tl.getMinDelay());
        vm.serializeBool(key, "safeIsProposer", tl.hasRole(tl.PROPOSER_ROLE(), c.safe));
        vm.serializeBool(key, "safeIsExecutor", tl.hasRole(tl.EXECUTOR_ROLE(), c.safe));
        vm.serializeBool(key, "timelockIsRegistryAdmin", IAccessControl(c.handleRegistry).hasRole(0x00, c.timelock));
        vm.serializeBool(key, "marketHasCode", c.market.code.length != 0);
        if (c.safe.code.length != 0) {
            vm.serializeAddress(key, "safeOwners", ISafeView(c.safe).getOwners());
            vm.serializeUint(key, "safeThreshold", ISafeView(c.safe).getThreshold());
            vm.serializeUint(key, "safeNonce", ISafeView(c.safe).nonce());
        }
        bool granted = IAccessControl(c.handleRegistry).hasRole(ArcNSConstants.MARKET_ROLE, c.market);
        console2.log("GRANT_STATE operation", name, "marketRoleGranted", granted);
        return vm.serializeBool(key, "marketRoleGranted", granted);
    }

    function _stateName(TimelockController.OperationState st) internal pure returns (string memory) {
        if (st == TimelockController.OperationState.Unset) return "Unset";
        if (st == TimelockController.OperationState.Waiting) return "Waiting";
        if (st == TimelockController.OperationState.Ready) return "Ready";
        return "Done";
    }
}
