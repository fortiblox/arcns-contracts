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

interface IBaseRegistrarView {
    function addController(address controller) external;
    function controllers(address) external view returns (bool);
}

/// @title GrantControllerV3RegistrarRole — additive registrar grant for the V3 (`registerDirect`,
///        no-commit-reveal) controllers
/// @notice Read-only. Never signs, never broadcasts, never needs a key — same discipline as
///         `GrantNameGiftsMarketRole.s.sol`. UNLIKE `GrantControllerV2.s.sol` (a full V1 -> V2
///         CUTOVER that revokes V1's role/controller flags and gates on live-pending-V1-commitments
///         per namespace), this script is purely ADDITIVE: it batches exactly three grants —
///         `HandleRegistry.grantRole(REGISTRAR_ROLE, HandleControllerV3)`,
///         `TldRegistrarArc.addController(TldRegistrarControllerV3Arc)`,
///         `TldRegistrarCircle.addController(TldRegistrarControllerV3Circle)` — and touches nothing
///         else. V1 keeps its existing role/controller grants untouched and keeps working exactly as
///         it does today; V3 becomes a second, independent registration path running side by side
///         with it. CEO decision (2026-09-14): offer `registerDirect` as an additional fast option,
///         not a replacement for the commit-reveal flow.
///
///         Batched as ONE `TimelockController.scheduleBatch`/`executeBatch` operation (three targets,
///         three calls) rather than `GrantControllerV2`'s three independent per-namespace operations —
///         there is no per-namespace pending-commitment gate to respect here (nothing is being revoked
///         or migrated), so there is no reason to let the namespaces execute on separate schedules.
///
///           AdminSafe.execTransaction(timelock, 0, scheduleBatch(...), Call, …, preValidatedSig)  <- t0
///           wait minDelay (3600s on Arc testnet)
///           AdminSafe.execTransaction(timelock, 0, executeBatch(...),  Call, …, preValidatedSig)  <- t0+delay
///
///           ARCNS_ADDRESS_BOOK=deployments/5042002.json forge script script/GrantControllerV3RegistrarRole.s.sol --rpc-url $ARC_RPC_URL
contract GrantControllerV3RegistrarRole is MarketScriptBase {
    struct Ctx {
        string bookPath;
        address handleRegistry;
        address tldArc;
        address tldCircle;
        address timelock;
        address safe;
        address safeOwner;
        address handleV3;
        address tldV3Arc;
        address tldV3Circle;
        uint256 delay;
        bool live;
    }

    struct Batch {
        address[] targets;
        uint256[] values;
        bytes[] payloads;
        bytes32 predecessor;
        bytes32 salt;
        uint256 delay;
        bytes32 operationId;
        bytes scheduleCalldata;
        bytes executeCalldata;
    }

    function run() external {
        Ctx memory c = _load();
        Batch memory b = _build(c);

        if (c.live) {
            bytes32 onchainId = TimelockController(payable(c.timelock))
                .hashOperationBatch(b.targets, b.values, b.payloads, b.predecessor, b.salt);
            require(onchainId == b.operationId, "hashOperationBatch mismatch");
        }

        console2.log("GRANT_HANDLE_REGISTRY", c.handleRegistry);
        console2.log("GRANT_HANDLE_V3", c.handleV3);
        console2.log("GRANT_TLD_ARC", c.tldArc, "controller", c.tldV3Arc);
        console2.log("GRANT_TLD_CIRCLE", c.tldCircle, "controller", c.tldV3Circle);
        console2.log("GRANT_TIMELOCK", c.timelock, "delay", c.delay);
        console2.log("GRANT_SAFE", c.safe, "owner", c.safeOwner);
        console2.log("GRANT_OPERATION_ID", vm.toString(b.operationId));
        console2.log("GRANT_SCHEDULE_CALLDATA", vm.toString(b.scheduleCalldata));
        console2.log("GRANT_EXECUTE_CALLDATA", vm.toString(b.executeCalldata));

        vm.writeJson(_serialize(b, c), _v3RegistrarGrantPath());
        console2.log("CONTROLLER_V3_REGISTRAR_GRANT_WRITTEN", _v3RegistrarGrantPath());
    }

    function _load() internal returns (Ctx memory c) {
        c.bookPath = _bookPath();
        string memory book = vm.readFile(c.bookPath);
        _logBook("ADDRESS_BOOK", c.bookPath);

        c.handleRegistry = vm.parseJsonAddress(book, ".HandleRegistry");
        c.tldArc = vm.parseJsonAddress(book, ".tlds.arc.BaseRegistrar");
        c.tldCircle = vm.parseJsonAddress(book, ".tlds.circle.BaseRegistrar");
        c.timelock = vm.parseJsonAddress(book, ".TimelockController");
        c.safe = vm.parseJsonAddress(book, ".AdminSafe");
        c.safeOwner = vm.parseJsonAddress(book, ".admin");
        c.handleV3 = vm.parseJsonAddress(book, ".controllerV3.HandleControllerV3");
        c.tldV3Arc = vm.parseJsonAddress(book, ".controllerV3.TldRegistrarControllerV3Arc");
        c.tldV3Circle = vm.parseJsonAddress(book, ".controllerV3.TldRegistrarControllerV3Circle");
        _requireAddr(c.handleRegistry, "HandleRegistry");
        _requireAddr(c.tldArc, "tlds.arc.BaseRegistrar");
        _requireAddr(c.tldCircle, "tlds.circle.BaseRegistrar");
        _requireAddr(c.timelock, "TimelockController");
        _requireAddr(c.safe, "AdminSafe");
        _requireAddr(c.safeOwner, "admin");
        _requireAddr(c.handleV3, "controllerV3.HandleControllerV3");
        _requireAddr(c.tldV3Arc, "controllerV3.TldRegistrarControllerV3Arc");
        _requireAddr(c.tldV3Circle, "controllerV3.TldRegistrarControllerV3Circle");

        c.delay = vm.parseJsonUint(book, ".timelockDelay");
        c.live = c.timelock.code.length != 0;
        if (c.live) {
            uint256 onchain = TimelockController(payable(c.timelock)).getMinDelay();
            require(onchain == c.delay, "timelock minDelay differs from the book's .timelockDelay");
        }
    }

    /// @dev Deterministic salt (re-running the script reproduces the same op id) — unique per
    ///      (handleV3, tldV3Arc, tldV3Circle) triple, mirroring `MarketGrantLib.opSalt`'s convention.
    function _salt(Ctx memory c) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("arcns:controllerV3:registrar-grant:", c.handleV3, c.tldV3Arc, c.tldV3Circle));
    }

    function _build(Ctx memory c) internal pure returns (Batch memory b) {
        b.targets = new address[](3);
        b.values = new uint256[](3);
        b.payloads = new bytes[](3);

        b.targets[0] = c.handleRegistry;
        b.values[0] = 0;
        b.payloads[0] = abi.encodeCall(IAccessControl.grantRole, (ArcNSConstants.REGISTRAR_ROLE, c.handleV3));

        b.targets[1] = c.tldArc;
        b.values[1] = 0;
        b.payloads[1] = abi.encodeCall(IBaseRegistrarView.addController, (c.tldV3Arc));

        b.targets[2] = c.tldCircle;
        b.values[2] = 0;
        b.payloads[2] = abi.encodeCall(IBaseRegistrarView.addController, (c.tldV3Circle));

        b.predecessor = bytes32(0);
        b.salt = _salt(c);
        b.delay = c.delay;
        b.operationId = keccak256(abi.encode(b.targets, b.values, b.payloads, b.predecessor, b.salt));
        b.scheduleCalldata = abi.encodeCall(
            TimelockController.scheduleBatch, (b.targets, b.values, b.payloads, b.predecessor, b.salt, b.delay)
        );
        b.executeCalldata =
            abi.encodeCall(TimelockController.executeBatch, (b.targets, b.values, b.payloads, b.predecessor, b.salt));
    }

    function _serialize(Batch memory b, Ctx memory c) internal returns (string memory) {
        bytes memory sig = MarketGrantLib.safePreValidatedSignature(c.safeOwner);
        string memory sched = _serializeSafeTx("v3RegistrarSafeSchedule", c.timelock, b.scheduleCalldata, sig);
        string memory exec = _serializeSafeTx("v3RegistrarSafeExecute", c.timelock, b.executeCalldata, sig);
        string memory state = _state(b, c);

        string memory root = "grant";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "sourceBook", c.bookPath);
        vm.serializeAddress(root, "HandleRegistry", c.handleRegistry);
        vm.serializeAddress(root, "TldRegistrarArc", c.tldArc);
        vm.serializeAddress(root, "TldRegistrarCircle", c.tldCircle);
        vm.serializeAddress(root, "HandleControllerV3", c.handleV3);
        vm.serializeAddress(root, "TldRegistrarControllerV3Arc", c.tldV3Arc);
        vm.serializeAddress(root, "TldRegistrarControllerV3Circle", c.tldV3Circle);
        vm.serializeAddress(root, "TimelockController", c.timelock);
        vm.serializeAddress(root, "AdminSafe", c.safe);
        vm.serializeAddress(root, "safeOwner", c.safeOwner);
        vm.serializeBytes32(root, "predecessor", b.predecessor);
        vm.serializeBytes32(root, "salt", b.salt);
        vm.serializeUint(root, "delay", b.delay);
        vm.serializeBytes32(root, "operationId", b.operationId);
        vm.serializeBytes(root, "scheduleCalldata", b.scheduleCalldata);
        vm.serializeBytes(root, "executeCalldata", b.executeCalldata);
        vm.serializeString(root, "safeSchedule", sched);
        vm.serializeString(root, "safeExecute", exec);
        return vm.serializeString(root, "state", state);
    }

    function _state(Batch memory b, Ctx memory c) internal returns (string memory) {
        string memory key = "state";
        vm.serializeBool(key, "rpc", c.live);
        if (!c.live) {
            vm.serializeString(key, "operation", "no-rpc");
            return vm.serializeBool(key, "granted", false);
        }
        TimelockController tl = TimelockController(payable(c.timelock));
        string memory name = _stateName(tl.getOperationState(b.operationId));
        vm.serializeString(key, "operation", name);
        vm.serializeUint(key, "operationReadyAt", tl.getTimestamp(b.operationId));
        vm.serializeUint(key, "minDelay", tl.getMinDelay());
        vm.serializeBool(key, "safeIsProposer", tl.hasRole(tl.PROPOSER_ROLE(), c.safe));
        vm.serializeBool(key, "safeIsExecutor", tl.hasRole(tl.EXECUTOR_ROLE(), c.safe));
        if (c.safe.code.length != 0) {
            vm.serializeAddress(key, "safeOwners", ISafeView(c.safe).getOwners());
            vm.serializeUint(key, "safeThreshold", ISafeView(c.safe).getThreshold());
            vm.serializeUint(key, "safeNonce", ISafeView(c.safe).nonce());
        }
        bool handleGranted = IAccessControl(c.handleRegistry).hasRole(ArcNSConstants.REGISTRAR_ROLE, c.handleV3);
        bool arcGranted = IBaseRegistrarView(c.tldArc).controllers(c.tldV3Arc);
        bool circleGranted = IBaseRegistrarView(c.tldCircle).controllers(c.tldV3Circle);
        bool granted = handleGranted && arcGranted && circleGranted;
        console2.log("GRANT_STATE operation", name);
        console2.log("GRANT_STATE handle", handleGranted, "arc", arcGranted);
        console2.log("GRANT_STATE circle", circleGranted);
        vm.serializeBool(key, "handleRegistrarGranted", handleGranted);
        vm.serializeBool(key, "tldArcControllerGranted", arcGranted);
        vm.serializeBool(key, "tldCircleControllerGranted", circleGranted);
        return vm.serializeBool(key, "granted", granted);
    }

    function _v3RegistrarGrantPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".controllerV3-registrar-grant.json");
    }
}
