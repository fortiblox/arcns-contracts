// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {IArcNSPriceOracle} from "../src/interfaces/IArcNSPriceOracle.sol";
import {ITldDirectory} from "../src/interfaces/ITldDirectory.sol";
import {ArcNSConstants} from "../src/lib/ArcNSConstants.sol";
import {ControllerV2CutoverLib} from "./lib/ControllerV2CutoverLib.sol";
import {MarketGrantLib} from "./lib/MarketGrantLib.sol";
import {MarketScriptBase} from "./lib/MarketScriptBase.sol";

interface ISafeView {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
}

interface IBaseRegistrarView {
    function controllers(address) external view returns (bool);
}

interface IReverseRegistrarView {
    function controllers(address) external view returns (bool);
}

/// @title GrantControllerV2 — WP #7772: the corrected, atomic-per-namespace governance payload for the
///        Integrator-v2 cutover
/// @notice Read-only. Never signs, never broadcasts, never needs a key (same discipline as
///         `GrantMarketRole.s.sol`, which this script mirrors byte-for-byte in shape). Given the live
///         address book (`deployments/<chainId>.json`) and the `.controllerV2` book
///         `DeployControllerV2.s.sol` wrote, builds THREE independent `TimelockController.scheduleBatch`
///         operations — one per namespace (`handles`, `arc`, `circle`) — using
///         `ControllerV2CutoverLib`, plus one OPTIONAL later "hygiene" batch per namespace that revokes
///         V1's now-unnecessary role/controller flags. Prints every batch's calldata, operation id, and
///         the Admin Safe `execTransaction` wrapper for both `schedule` and `execute`, and writes all of
///         it to `deployments/<chainId>.controllerV2-cutover.json` for the CEO's Safe shell to run:
///
///           AdminSafe.execTransaction(timelock, 0, scheduleBatch(...), Call, …, preValidatedSig)  ← t0
///           wait minDelay (3600 s on Arc testnet)
///           AdminSafe.execTransaction(timelock, 0, executeBatch(...),  Call, …, preValidatedSig)  ← t0+1h
///
///         **Why one script builds three (or six) independent operations instead of one giant batch**:
///         each namespace's cutover is independently gated on that namespace's own live-pending-V1-
///         commitments check (`VerifyControllerV2.checkPendingCommitments`, CEO decision Q1
///         2026-09-12) — `.arc` may be clear to execute while `.circle` still has a commitment mid-flight.
///         Bundling all three into one timelock op would force them to execute atomically together and
///         block the whole cutover on the slowest namespace; three independent ids let the runbook
///         execute each the moment ITS gate clears.
///
///           ARCNS_ADDRESS_BOOK=deployments/5042002.json forge script script/GrantControllerV2.s.sol --rpc-url $ARC_RPC_URL
///         The `.controllerV2` object comes from the book when `DeployControllerV2` broadcast, else from
///         `deployments/<chainId>.controllerV2-dry-run.json` (rehearsal). No `--broadcast`, no `--sender`.
contract GrantControllerV2 is MarketScriptBase {
    struct Ctx {
        string bookPath;
        string cv2Path;
        address handleRegistry;
        address oracle;
        address reverseRegistrar;
        address directory;
        address timelock;
        address safe;
        address safeOwner;
        uint256 delay;
        bool live;
        // V1 (for hygiene batches + salts)
        address handleControllerV1;
        // V2
        address handleControllerV2;
        // per TLD: [0]=arc [1]=circle
        string[2] tldLabels;
        address[2] baseRegistrars;
        address[2] controllersV1;
        address[2] controllersV2;
        bytes32[2] tldNodes;
    }

    function run() external {
        Ctx memory c = _load();

        ControllerV2CutoverLib.BatchPayload memory h = _buildHandleBatch(c);
        ControllerV2CutoverLib.BatchPayload memory a = _buildTldBatch(c, 0);
        ControllerV2CutoverLib.BatchPayload memory ci = _buildTldBatch(c, 1);
        ControllerV2CutoverLib.BatchPayload memory hygH = _buildHandleHygiene(c);
        ControllerV2CutoverLib.BatchPayload memory hygA = _buildTldHygiene(c, 0);
        ControllerV2CutoverLib.BatchPayload memory hygC = _buildTldHygiene(c, 1);

        if (c.live) {
            _crossCheck(c.timelock, h);
            _crossCheck(c.timelock, a);
            _crossCheck(c.timelock, ci);
        }

        _logBatch("H", h);
        _logBatch("ARC", a);
        _logBatch("CIRCLE", ci);
        _logBatch("HYGIENE_H", hygH);
        _logBatch("HYGIENE_ARC", hygA);
        _logBatch("HYGIENE_CIRCLE", hygC);

        vm.writeJson(_serialize(c, h, a, ci, hygH, hygA, hygC), _cutoverPath());
        console2.log("CONTROLLER_V2_CUTOVER_WRITTEN", _cutoverPath());
    }

    // ---------------------------------------------------------------------------------------------
    // Loading
    // ---------------------------------------------------------------------------------------------

    function _load() internal returns (Ctx memory c) {
        c.bookPath = _bookPath();
        string memory book = vm.readFile(c.bookPath);
        string memory cv2Json;
        (cv2Json, c.cv2Path) = _readControllerV2Book(book, c.bookPath);
        _logBook("ADDRESS_BOOK", c.bookPath);
        _logBook("CONTROLLER_V2_BOOK", c.cv2Path);

        c.handleRegistry = vm.parseJsonAddress(book, ".HandleRegistry");
        c.oracle = vm.parseJsonAddress(book, ".ArcNSPriceOracle");
        c.reverseRegistrar = vm.parseJsonAddress(book, ".ReverseRegistrar");
        c.directory = vm.parseJsonAddress(book, ".TldDirectory");
        c.timelock = vm.parseJsonAddress(book, ".TimelockController");
        c.safe = vm.parseJsonAddress(book, ".AdminSafe");
        c.safeOwner = vm.parseJsonAddress(book, ".admin");
        c.handleControllerV1 = vm.parseJsonAddress(book, ".HandleController");
        c.handleControllerV2 = vm.parseJsonAddress(cv2Json, ".controllerV2.HandleControllerV2");

        c.tldLabels[0] = "arc";
        c.tldLabels[1] = "circle";
        c.baseRegistrars[0] = vm.parseJsonAddress(book, ".tlds.arc.BaseRegistrar");
        c.baseRegistrars[1] = vm.parseJsonAddress(book, ".tlds.circle.BaseRegistrar");
        c.controllersV1[0] = vm.parseJsonAddress(book, ".tlds.arc.Controller");
        c.controllersV1[1] = vm.parseJsonAddress(book, ".tlds.circle.Controller");
        c.controllersV2[0] = vm.parseJsonAddress(cv2Json, ".controllerV2.TldRegistrarControllerV2Arc");
        c.controllersV2[1] = vm.parseJsonAddress(cv2Json, ".controllerV2.TldRegistrarControllerV2Circle");
        c.tldNodes[0] = vm.parseJsonBytes32(book, ".tlds.arc.node");
        c.tldNodes[1] = vm.parseJsonBytes32(book, ".tlds.circle.node");

        _requireAddr(c.handleRegistry, "HandleRegistry");
        _requireAddr(c.oracle, "ArcNSPriceOracle");
        _requireAddr(c.reverseRegistrar, "ReverseRegistrar");
        _requireAddr(c.directory, "TldDirectory");
        _requireAddr(c.timelock, "TimelockController");
        _requireAddr(c.safe, "AdminSafe");
        _requireAddr(c.safeOwner, "admin");
        _requireAddr(c.handleControllerV1, "HandleController");
        _requireAddr(c.handleControllerV2, "controllerV2.HandleControllerV2");
        for (uint256 k = 0; k < 2; k++) {
            _requireAddr(c.baseRegistrars[k], "tlds.<label>.BaseRegistrar");
            _requireAddr(c.controllersV1[k], "tlds.<label>.Controller");
            _requireAddr(c.controllersV2[k], "controllerV2.TldRegistrarControllerV2<label>");
            require(c.tldNodes[k] != bytes32(0), "GrantControllerV2: zero tld node");
        }

        c.delay = vm.parseJsonUint(book, ".timelockDelay");
        c.live = c.timelock.code.length != 0;
        if (c.live) {
            uint256 onchain = TimelockController(payable(c.timelock)).getMinDelay();
            require(onchain == c.delay, "timelock minDelay differs from the book's .timelockDelay");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Batch construction
    // ---------------------------------------------------------------------------------------------

    /// @dev `tokenizer` for HANDLE_ROOT must stay the live `HandleRegistry` (onchain-plan.md §5) — when
    ///      the RPC is live this is asserted against the oracle's OWN current value rather than assumed
    ///      from the book, so a governance drift (someone else already moved it) fails loudly here
    ///      instead of silently building a batch that clobbers it.
    function _buildHandleBatch(Ctx memory c) internal returns (ControllerV2CutoverLib.BatchPayload memory) {
        address tokenizer = c.handleRegistry;
        if (c.live) {
            address liveTokenizer = IArcNSPriceOracle(c.oracle).namespaceInfo(ArcNSConstants.HANDLE_ROOT).tokenizer;
            require(
                liveTokenizer == c.handleRegistry, "GrantControllerV2: HANDLE_ROOT tokenizer != HandleRegistry live"
            );
            tokenizer = liveTokenizer;
        }
        return
            ControllerV2CutoverLib.buildHandleBatch(
                c.handleRegistry, c.oracle, c.handleControllerV2, tokenizer, c.delay
            );
    }

    function _buildTldBatch(Ctx memory c, uint256 k)
        internal
        pure
        returns (ControllerV2CutoverLib.BatchPayload memory)
    {
        return ControllerV2CutoverLib.buildTldBatch(
            c.tldLabels[k],
            c.baseRegistrars[k],
            c.reverseRegistrar,
            c.directory,
            c.oracle,
            c.tldNodes[k],
            c.controllersV2[k],
            c.delay
        );
    }

    function _buildHandleHygiene(Ctx memory c) internal pure returns (ControllerV2CutoverLib.BatchPayload memory) {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = c.handleRegistry;
        data[0] = abi.encodeCall(IAccessControl.revokeRole, (ArcNSConstants.REGISTRAR_ROLE, c.handleControllerV1));
        return ControllerV2CutoverLib.buildHygieneBatch("handles", targets, data, c.handleControllerV1, c.delay);
    }

    /// @dev Hygiene for one TLD: `removeController(V1)` on the `BaseRegistrar` and
    ///      `setController(V1, false)` on the shared `ReverseRegistrar`. `TldDirectory` needs no hygiene
    ///      call — its `setController` already DELETED V1's binding the moment the cutover batch ran
    ///      (onchain-plan.md §4.2-3); there is nothing left to revoke there.
    function _buildTldHygiene(Ctx memory c, uint256 k)
        internal
        pure
        returns (ControllerV2CutoverLib.BatchPayload memory)
    {
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        targets[0] = c.baseRegistrars[k];
        data[0] = abi.encodeWithSignature("removeController(address)", c.controllersV1[k]);
        targets[1] = c.reverseRegistrar;
        data[1] = abi.encodeWithSignature("setController(address,bool)", c.controllersV1[k], false);
        return ControllerV2CutoverLib.buildHygieneBatch(c.tldLabels[k], targets, data, c.controllersV1[k], c.delay);
    }

    function _crossCheck(address timelock, ControllerV2CutoverLib.BatchPayload memory p) internal view {
        bytes32 onchainId = TimelockController(payable(timelock))
            .hashOperationBatch(p.targets, p.values, p.data, p.predecessor, p.salt);
        require(onchainId == p.operationId, string.concat("hashOperationBatch mismatch: ", p.label));
    }

    // ---------------------------------------------------------------------------------------------
    // Logging + serialization
    // ---------------------------------------------------------------------------------------------

    function _logBatch(string memory tag, ControllerV2CutoverLib.BatchPayload memory p) internal pure {
        console2.log(string.concat("CUTOVER_BATCH_", tag, "_LABEL"), p.label);
        console2.log(string.concat("CUTOVER_BATCH_", tag, "_OPERATION_ID"), vm.toString(p.operationId));
        console2.log(string.concat("CUTOVER_BATCH_", tag, "_CALL_COUNT"), p.targets.length);
        console2.log(string.concat("CUTOVER_BATCH_", tag, "_SCHEDULE_CALLDATA"), vm.toString(p.scheduleCalldata));
        console2.log(string.concat("CUTOVER_BATCH_", tag, "_EXECUTE_CALLDATA"), vm.toString(p.executeCalldata));
    }

    function _serialize(
        Ctx memory c,
        ControllerV2CutoverLib.BatchPayload memory h,
        ControllerV2CutoverLib.BatchPayload memory a,
        ControllerV2CutoverLib.BatchPayload memory ci,
        ControllerV2CutoverLib.BatchPayload memory hygH,
        ControllerV2CutoverLib.BatchPayload memory hygA,
        ControllerV2CutoverLib.BatchPayload memory hygC
    ) internal returns (string memory) {
        string memory root = "cutover";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "sourceBook", c.bookPath);
        vm.serializeString(root, "controllerV2Book", c.cv2Path);
        vm.serializeString(root, "workPackage", "WP-7772");
        vm.serializeAddress(root, "TimelockController", c.timelock);
        vm.serializeAddress(root, "AdminSafe", c.safe);
        vm.serializeAddress(root, "safeOwner", c.safeOwner);
        vm.serializeUint(root, "delay", c.delay);
        vm.serializeString(root, "batchHandles", _batchJson(c, "handles", h));
        vm.serializeString(root, "batchArc", _batchJson(c, "arc", a));
        vm.serializeString(root, "batchCircle", _batchJson(c, "circle", ci));
        vm.serializeString(root, "hygieneHandles", _batchJson(c, "hygiene-handles", hygH));
        vm.serializeString(root, "hygieneArc", _batchJson(c, "hygiene-arc", hygA));
        return vm.serializeString(root, "hygieneCircle", _batchJson(c, "hygiene-circle", hygC));
    }

    function _batchJson(Ctx memory c, string memory key, ControllerV2CutoverLib.BatchPayload memory p)
        internal
        returns (string memory)
    {
        bytes memory sig = MarketGrantLib.safePreValidatedSignature(c.safeOwner);
        vm.serializeString(key, "label", p.label);
        vm.serializeAddress(key, "targets", p.targets);
        vm.serializeUint(key, "values", p.values);
        vm.serializeBytes(key, "data", p.data);
        vm.serializeBytes32(key, "predecessor", p.predecessor);
        vm.serializeBytes32(key, "salt", p.salt);
        vm.serializeUint(key, "delay", p.delay);
        vm.serializeBytes32(key, "operationId", p.operationId);
        vm.serializeBytes(key, "scheduleCalldata", p.scheduleCalldata);
        vm.serializeBytes(key, "executeCalldata", p.executeCalldata);
        vm.serializeString(
            key, "safeSchedule", _serializeSafeTx(string.concat(key, "-sched"), c.timelock, p.scheduleCalldata, sig)
        );
        vm.serializeString(
            key, "safeExecute", _serializeSafeTx(string.concat(key, "-exec"), c.timelock, p.executeCalldata, sig)
        );
        return vm.serializeString(key, "state", _state(c, p));
    }

    /// @dev Live read-backs so the runbook can tell "not scheduled" from "waiting" from "done", and see
    ///      the ACTUAL post-cutover authority state (oracle controller, not just role flags) per batch.
    function _state(Ctx memory c, ControllerV2CutoverLib.BatchPayload memory p) internal returns (string memory) {
        string memory key = string.concat(p.label, "-state");
        vm.serializeBool(key, "rpc", c.live);
        if (!c.live) {
            return vm.serializeString(key, "operation", "no-rpc");
        }
        TimelockController tl = TimelockController(payable(c.timelock));
        string memory name = _stateName(tl.getOperationState(p.operationId));
        vm.serializeString(key, "operation", name);
        vm.serializeUint(key, "operationReadyAt", tl.getTimestamp(p.operationId));
        vm.serializeBool(key, "safeIsProposer", tl.hasRole(tl.PROPOSER_ROLE(), c.safe));
        vm.serializeBool(key, "safeIsExecutor", tl.hasRole(tl.EXECUTOR_ROLE(), c.safe));
        if (c.safe.code.length != 0) {
            vm.serializeAddress(key, "safeOwners", ISafeView(c.safe).getOwners());
            vm.serializeUint(key, "safeThreshold", ISafeView(c.safe).getThreshold());
            vm.serializeUint(key, "safeNonce", ISafeView(c.safe).nonce());
        }
        console2.log("CUTOVER_STATE", p.label, name);
        return vm.serializeUint(key, "checkedAtBlock", block.number);
    }
}
