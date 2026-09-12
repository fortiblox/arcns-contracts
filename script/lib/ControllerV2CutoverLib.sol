// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {ITldDirectory} from "../../src/interfaces/ITldDirectory.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";

/// @dev `TldRegistrar`/`BaseRegistrarImplementation` governance surface used here. Declared locally
///      (no published narrow interface exists for it) — same convention `VerifyControllerV2.s.sol`
///      already uses for its own read-only view interfaces.
interface IBaseRegistrarGov {
    function addController(address controller) external;
    function removeController(address controller) external;
}

/// @dev `ReverseRegistrar` (`Controllable`) governance surface — `setController` is `onlyOwner`, the
///      owner being the `TimelockController` (verified live, onchain-plan.md §4.1).
interface IReverseRegistrarGov {
    function setController(address controller, bool enabled) external;
}

/// @title ControllerV2CutoverLib — WP #7772 corrected cutover: one atomic scheduleBatch per namespace
/// @notice `ArcNSPriceOracle.recordSale` is single-controller PER NAMESPACE — `NamespaceInfo.controller`
///         is a single address that `setController` REPLACES, not a set (`src/pricing/ArcNSPriceOracle.sol`
///         lines ~119-190). V1 and V2 can therefore never be simultaneously authorized writers of the
///         same namespace's sale counter. `deploy/runbooks/integrator-v2-cutover.md` (the version this
///         branch replaces) assumed the opposite ("both controllers simultaneously authorized writers ...
///         is safe") and was proven wrong live: `recordSale` reverts `NotNamespaceController` for
///         whichever controller the oracle does NOT currently point at (onchain-plan.md §4.2-1, CEO
///         decision Q2 2026-09-12: keep the oracle single-controller, do the atomic switch instead of
///         redesigning it).
///
///         Consequence: the cutover per namespace cannot be "grant V2, wait, revoke V1" — it must be
///         ONE atomic operation that gives V2 everything it needs to complete a sale in the same
///         transaction the oracle stops accepting `recordSale` from V1. This library builds that
///         operation as a `TimelockController.scheduleBatch`/`executeBatch` pair, one per namespace:
///
///           Batch H ("handles", the handle namespace):
///             1. `HandleRegistry.grantRole(REGISTRAR_ROLE, HandleControllerV2)`
///             2. `ArcNSPriceOracle.setController(HANDLE_ROOT, HandleControllerV2, tokenizerUnchanged)`
///
///           Batch <tld> (".arc" / ".circle"):
///             1. `BaseRegistrar.addController(TldRegistrarControllerV2)`
///             2. `ReverseRegistrar.setController(TldRegistrarControllerV2, true)`
///                (`TldRegistrarControllerV2._registerWithResolver` calls `reverseRegistrar.setNameForAddr`
///                whenever `reverseRecord == true` — omitted by the runbook this replaces, proven live
///                missing in onchain-plan.md §4.2-2)
///             3. `TldDirectory.setController(tldNode, TldRegistrarControllerV2)`
///                (this ALSO strips V1 of `ArcNSResolver` write authority the same block — `TldDirectory
///                .setController` deletes the previous controller's binding, onchain-plan.md §4.2-3 — so
///                there is no separate "resolver still trusts V1" window to reason about either)
///             4. `ArcNSPriceOracle.setController(tldNode, TldRegistrarControllerV2, address(0))`
///
///         Deliberately NOT bundled into H/A/C (a separate, later, non-blocking "hygiene" batch — see
///         `GrantControllerV2.s.sol` and `buildHygieneBatch` below): revoking V1's `REGISTRAR_ROLE` /
///         `BaseRegistrar.controllers(V1)` / `ReverseRegistrar.controllers(V1)`. V1 is already fully
///         inert for a namespace the instant that namespace's oracle controller moves — every V1
///         `register`/`registerWithProof` path ends in `oracle.recordSale` from V1's own address, which
///         reverts `NotNamespaceController` once the oracle points elsewhere (the whole registration
///         call reverts atomically, undoing any earlier mint inside the same call — proven by this
///         branch's `test/controller-v2/ControllerV2Cutover.t.sol` and the anvil fork rehearsal). Leaving
///         V1's other role flags set costs nothing, is NOT a live security gap (nothing an inert
///         controller's residual role can do without also clearing the oracle gate), and keeps a
///         same-day rollback to a single-purpose op instead of re-deriving which flags to restore.
///
///         Salts: `keccak256("arcns:wp-7772:cutover:" ‖ label ‖ ":" ‖ v2Address)` — same recipe family as
///         `MarketGrantLib.opSalt` (deterministic: re-running the script reproduces the same operation
///         id; unique per V2 address: a V2 redeploy is a fresh op, not a `TimelockUnexpectedOperationState`
///         collision with one already scheduled/executed for a stale address).
library ControllerV2CutoverLib {
    struct BatchPayload {
        string label; // "handles" | "arc" | "circle" | "hygiene-handles" | "hygiene-arc" | "hygiene-circle"
        address[] targets;
        uint256[] values; // always 0 — every call in every batch is a plain governance call, no value
        bytes[] data;
        bytes32 predecessor; // 0: no ordering dependency between batches (each is independent)
        bytes32 salt;
        uint256 delay;
        bytes32 operationId; // TimelockController.hashOperationBatch(targets, values, data, predecessor, salt)
        bytes scheduleCalldata; // what the Admin Safe sends to the timelock to propose
        bytes executeCalldata; // what the Admin Safe sends to the timelock to execute, after `delay`
    }

    function opSalt(string memory label, address v2) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("arcns:wp-7772:cutover:", label, ":", v2));
    }

    /// @notice Batch H: the handle namespace (handle names).
    /// @param tokenizerUnchanged the oracle's CURRENT `namespaceInfo(HANDLE_ROOT).tokenizer` (the shared
    ///        `HandleRegistry`, live-verified onchain-plan.md §5) — `setController`'s third argument
    ///        REPLACES the tokenizer too, so the caller MUST pass the unchanged live value through, never
    ///        a zero address, or `recordTokenize` (NFT-tokenize path) breaks alongside the sale path.
    function buildHandleBatch(
        address handleRegistry,
        address oracle,
        address handleControllerV2,
        address tokenizerUnchanged,
        uint256 delay
    ) internal pure returns (BatchPayload memory p) {
        require(
            handleRegistry != address(0) && oracle != address(0) && handleControllerV2 != address(0)
                && tokenizerUnchanged != address(0),
            "ControllerV2CutoverLib: zero addr"
        );
        require(delay != 0, "ControllerV2CutoverLib: zero delay");

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory data = new bytes[](2);

        targets[0] = handleRegistry;
        data[0] = abi.encodeCall(IAccessControl.grantRole, (ArcNSConstants.REGISTRAR_ROLE, handleControllerV2));

        targets[1] = oracle;
        data[1] = abi.encodeCall(
            IArcNSPriceOracle.setController, (ArcNSConstants.HANDLE_ROOT, handleControllerV2, tokenizerUnchanged)
        );

        p = _finish("handles", targets, values, data, handleControllerV2, delay);
    }

    /// @notice Batch <tld>: one TLD namespace (`.arc` or `.circle`). `tokenizer` is always `address(0)`
    ///         for TLD namespaces — verbatim what `ArcNSDeployLib.addTld` itself passes at genesis
    ///         (`noTokenize`/no tokenizer for TLDs; only the handle namespace tokenizes).
    function buildTldBatch(
        string memory label,
        address baseRegistrar,
        address reverseRegistrar,
        address directory,
        address oracle,
        bytes32 tldNode,
        address tldControllerV2,
        uint256 delay
    ) internal pure returns (BatchPayload memory p) {
        require(
            baseRegistrar != address(0) && reverseRegistrar != address(0) && directory != address(0)
                && oracle != address(0) && tldControllerV2 != address(0),
            "ControllerV2CutoverLib: zero addr"
        );
        require(tldNode != bytes32(0), "ControllerV2CutoverLib: zero node");
        require(delay != 0, "ControllerV2CutoverLib: zero delay");

        address[] memory targets = new address[](4);
        uint256[] memory values = new uint256[](4);
        bytes[] memory data = new bytes[](4);

        targets[0] = baseRegistrar;
        data[0] = abi.encodeCall(IBaseRegistrarGov.addController, (tldControllerV2));

        targets[1] = reverseRegistrar;
        data[1] = abi.encodeCall(IReverseRegistrarGov.setController, (tldControllerV2, true));

        targets[2] = directory;
        data[2] = abi.encodeCall(ITldDirectory.setController, (tldNode, tldControllerV2));

        targets[3] = oracle;
        data[3] = abi.encodeCall(IArcNSPriceOracle.setController, (tldNode, tldControllerV2, address(0)));

        p = _finish(label, targets, values, data, tldControllerV2, delay);
    }

    /// @notice Batch R (hygiene): strips V1's now-unnecessary role/controller flags. Caller assembles
    ///         `targets`/`data` (see `GrantControllerV2.s.sol` for the exact per-namespace calls) — this
    ///         function only wraps them into the same scheduleBatch/executeBatch/salt shape as H/A/C so
    ///         every batch in this cutover, hygiene included, is generated and verified identically.
    ///         NOT part of the atomic cutover and NOT a precondition for V2 to work (see the library
    ///         NatSpec) — schedule this only after `VerifyControllerV2Full` shows real V2 sale volume
    ///         (runbook §6, "no earlier than +48h").
    function buildHygieneBatch(
        string memory label,
        address[] memory targets,
        bytes[] memory data,
        address v1Marker,
        uint256 delay
    ) internal pure returns (BatchPayload memory p) {
        require(targets.length == data.length && targets.length > 0, "ControllerV2CutoverLib: bad hygiene batch");
        require(v1Marker != address(0), "ControllerV2CutoverLib: zero addr");
        require(delay != 0, "ControllerV2CutoverLib: zero delay");
        uint256[] memory values = new uint256[](targets.length);
        p = _finish(string.concat("hygiene-", label), targets, values, data, v1Marker, delay);
    }

    function _finish(
        string memory label,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory data,
        address saltAddr,
        uint256 delay
    ) private pure returns (BatchPayload memory p) {
        p.label = label;
        p.targets = targets;
        p.values = values;
        p.data = data;
        p.predecessor = bytes32(0);
        p.salt = opSalt(label, saltAddr);
        p.delay = delay;
        p.operationId = keccak256(abi.encode(targets, values, data, p.predecessor, p.salt));
        p.scheduleCalldata =
            abi.encodeCall(TimelockController.scheduleBatch, (targets, values, data, p.predecessor, p.salt, delay));
        p.executeCalldata =
            abi.encodeCall(TimelockController.executeBatch, (targets, values, data, p.predecessor, p.salt));
    }
}
