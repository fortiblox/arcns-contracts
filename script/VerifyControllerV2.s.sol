// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IArcNSPriceOracle} from "../src/interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../src/lib/ArcNSConstants.sol";
import {MarketScriptBase} from "./lib/MarketScriptBase.sol";

interface IBaseRegistrarView {
    function controllers(address) external view returns (bool);
}

interface ITldDirectoryView {
    function controllerOf(bytes32 tldNode) external view returns (address);
}

/// @dev `ReverseRegistrar` (`Controllable`) — `controllers` is a public mapping getter.
interface IReverseRegistrarView {
    function controllers(address) external view returns (bool);
}

/// @dev Any V1/V2 controller's public `commitments` mapping getter (`HandleController`,
///      `HandleControllerV2`, `TldRegistrarController`, `TldRegistrarControllerV2` all share this
///      exact getter shape — `mapping(bytes32 commitment => uint256 timestamp) public commitments`).
interface ICommitmentsView {
    function commitments(bytes32 commitment) external view returns (uint256);
}

/// @title VerifyControllerV2 — WP #7772: read-only role/wiring check for the integrator-v2 cutover
/// @notice Mirrors `VerifyMarketRoles.s.sol`'s pattern exactly: read-only, no key, one `ROLES_VERIFIED`
///         or `ROLES_FAILED` marker at the end, one `FAIL` line per broken invariant naming the precise
///         diff. The invariants checked are the POST-CUTOVER target state:
///           - `HandleRegistry.hasRole(REGISTRAR_ROLE, HandleControllerV2) == true`
///           - `HandleRegistry.hasRole(REGISTRAR_ROLE, HandleController[V1]) == false` (revoked — the
///             OPTIONAL, later "hygiene" batch; V2 does not need this to already work, see below)
///           - `ArcNSPriceOracle.namespaceInfo(HANDLE_ROOT/tldNode).controller == V2` for every namespace
///             (the ACTUAL authority gate — added in this branch, WP #7772 corrected cutover; its
///             absence from the original version of this script is exactly the defect onchain-plan.md
///             §4.2-1/§4.2-5 found: a script that never checked the one gate that actually decides
///             whether a registration can complete)
///           - each `TldRegistrar.controllers(TldRegistrarControllerV2[tld]) == true`
///           - each `TldRegistrar.controllers(TldRegistrarController[tld][V1]) == false` (removed —
///             hygiene, same caveat as the `REGISTRAR_ROLE` revoke above)
///           - each `ReverseRegistrar.controllers(TldRegistrarControllerV2[tld]) == true` (added in this
///             branch — omitted entirely before, onchain-plan.md §4.2-2; without it every V2 registration
///             with `reverseRecord == true` reverts)
///           - each `TldDirectory.controllerOf(tldNode) == TldRegistrarControllerV2[tld]`
///
/// @dev **As of this branch, NO cutover has run.** `DeployControllerV2.s.sol` only deploys; it grants
///      nothing. Running this script against the current live/rehearsed state is therefore EXPECTED to
///      print `ROLES_FAILED` with a `FAIL` line for every grant above — that is the honest, correct
///      report of "not cut over yet", not a bug in this script. This script exists so that, AFTER a
///      human/Safe has actually run the governance sequence in
///      `deploy/runbooks/integrator-v2-cutover.md` (now `ControllerV2CutoverLib`'s atomic per-namespace
///      `scheduleBatch`/`executeBatch`, not the old "grant V2 / later revoke V1" sequence), the SAME
///      command flips every "V2 wired" line to `ok` — exactly how `VerifyMarketRoles.s.sol` behaves
///      across its own phase 2. The "V1 revoked" lines stay `FAIL` (and the overall marker stays
///      `ROLES_FAILED`) until the separate, later, non-blocking hygiene batch runs — that is CORRECT,
///      not a bug: V1 is already functionally inert once its namespace's oracle `controller` moves (see
///      `ControllerV2CutoverLib`'s top NatSpec), so "hygiene not yet run" must never be confused with
///      "cutover not safe yet".
///
///        ARCNS_ADDRESS_BOOK=deployments/5042002.json forge script script/VerifyControllerV2.s.sol --rpc-url $ARC_RPC_URL
contract VerifyControllerV2 is MarketScriptBase {
    bytes32 internal constant REGISTRAR_ROLE = ArcNSConstants.REGISTRAR_ROLE;
    bytes32 internal constant HANDLE_ROOT = ArcNSConstants.HANDLE_ROOT;

    struct Inputs {
        address handleRegistry;
        address handleControllerV1;
        address handleControllerV2;
        address oracle;
        address reverseRegistrar;
        string[] tldLabels;
        address[] registrars; // BaseRegistrar per label
        address[] controllersV1; // TldRegistrarController (V1) per label
        address[] controllersV2; // TldRegistrarControllerV2 per label
        address directory;
        bytes32[] tldNodes;
    }

    bool internal ok = true;
    string[] internal failures;

    function run() external {
        string memory bookPath = _bookPath();
        string memory book = vm.readFile(bookPath);
        (string memory cv2Json, string memory cv2Path) = _readControllerV2Book(book, bookPath);
        _logBook("ADDRESS_BOOK", bookPath);
        _logBook("CONTROLLER_V2_BOOK", cv2Path);

        Inputs memory i = _inputs(book, cv2Json);
        bool passed = verify(i);
        console2.log(passed ? "ROLES_VERIFIED" : "ROLES_FAILED");
        require(passed, "ROLES_FAILED");
    }

    function _inputs(string memory book, string memory cv2Json) internal pure returns (Inputs memory i) {
        i.handleRegistry = vm.parseJsonAddress(book, ".HandleRegistry");
        i.handleControllerV1 = vm.parseJsonAddress(book, ".HandleController");
        i.handleControllerV2 = vm.parseJsonAddress(cv2Json, ".controllerV2.HandleControllerV2");
        i.directory = vm.parseJsonAddress(book, ".TldDirectory");
        i.oracle = vm.parseJsonAddress(book, ".ArcNSPriceOracle");
        i.reverseRegistrar = vm.parseJsonAddress(book, ".ReverseRegistrar");

        string[] memory labels = new string[](2);
        labels[0] = "arc";
        labels[1] = "circle";
        i.tldLabels = labels;

        i.registrars = new address[](2);
        i.controllersV1 = new address[](2);
        i.controllersV2 = new address[](2);
        i.tldNodes = new bytes32[](2);

        i.registrars[0] = vm.parseJsonAddress(book, ".tlds.arc.BaseRegistrar");
        i.controllersV1[0] = vm.parseJsonAddress(book, ".tlds.arc.Controller");
        i.controllersV2[0] = vm.parseJsonAddress(cv2Json, ".controllerV2.TldRegistrarControllerV2Arc");
        i.tldNodes[0] = vm.parseJsonBytes32(book, ".tlds.arc.node");

        i.registrars[1] = vm.parseJsonAddress(book, ".tlds.circle.BaseRegistrar");
        i.controllersV1[1] = vm.parseJsonAddress(book, ".tlds.circle.Controller");
        i.controllersV2[1] = vm.parseJsonAddress(cv2Json, ".controllerV2.TldRegistrarControllerV2Circle");
        i.tldNodes[1] = vm.parseJsonBytes32(book, ".tlds.circle.node");
    }

    /// @dev The whole check as one call over explicit inputs (no file I/O), so a test can run it before
    ///      and after a simulated cutover, mirroring `VerifyMarketRoles.verify`.
    function verify(Inputs memory i) public returns (bool) {
        ok = true;
        delete failures;

        bool handleV2Code = _code(i.handleControllerV2, "HandleControllerV2");
        if (handleV2Code) {
            _check(
                IAccessControl(i.handleRegistry).hasRole(REGISTRAR_ROLE, i.handleControllerV2),
                string.concat(
                    "HandleRegistry: REGISTRAR_ROLE granted to HandleControllerV2 ",
                    Strings.toChecksumHexString(i.handleControllerV2)
                )
            );
            _check(
                IArcNSPriceOracle(i.oracle).namespaceInfo(HANDLE_ROOT).controller == i.handleControllerV2,
                string.concat(
                    "ArcNSPriceOracle: namespaceInfo(HANDLE_ROOT).controller == HandleControllerV2 ",
                    Strings.toChecksumHexString(i.handleControllerV2)
                )
            );
        }
        _check(
            !IAccessControl(i.handleRegistry).hasRole(REGISTRAR_ROLE, i.handleControllerV1),
            string.concat(
                "HandleRegistry: REGISTRAR_ROLE revoked from HandleController[V1] ",
                Strings.toChecksumHexString(i.handleControllerV1)
            )
        );

        for (uint256 k = 0; k < i.tldLabels.length; k++) {
            string memory label = i.tldLabels[k];
            bool v2Code = _code(i.controllersV2[k], string.concat("TldRegistrarControllerV2[", label, "]"));
            if (v2Code) {
                _check(
                    IBaseRegistrarView(i.registrars[k]).controllers(i.controllersV2[k]),
                    string.concat(
                        "TldRegistrar[",
                        label,
                        "]: controller added for TldRegistrarControllerV2 ",
                        Strings.toChecksumHexString(i.controllersV2[k])
                    )
                );
                _check(
                    IReverseRegistrarView(i.reverseRegistrar).controllers(i.controllersV2[k]),
                    string.concat(
                        "ReverseRegistrar: controller added for TldRegistrarControllerV2[",
                        label,
                        "] ",
                        Strings.toChecksumHexString(i.controllersV2[k])
                    )
                );
                _check(
                    ITldDirectoryView(i.directory).controllerOf(i.tldNodes[k]) == i.controllersV2[k],
                    string.concat("TldDirectory[", label, "]: controllerOf == TldRegistrarControllerV2")
                );
                _check(
                    IArcNSPriceOracle(i.oracle).namespaceInfo(i.tldNodes[k]).controller == i.controllersV2[k],
                    string.concat(
                        "ArcNSPriceOracle: namespaceInfo(",
                        label,
                        "Node).controller == TldRegistrarControllerV2 ",
                        Strings.toChecksumHexString(i.controllersV2[k])
                    )
                );
            }
            _check(
                !IBaseRegistrarView(i.registrars[k]).controllers(i.controllersV1[k]),
                string.concat(
                    "TldRegistrar[",
                    label,
                    "]: controller removed for TldRegistrarController[V1] ",
                    Strings.toChecksumHexString(i.controllersV1[k])
                )
            );
        }
        return ok;
    }

    // ---------------------------------------------------------------------------------------------
    // Pre-execute gate: live-pending-commitments check (CEO decision Q1, 2026-09-12)
    // ---------------------------------------------------------------------------------------------

    /// @notice A commitment is "currently pending" on a V1 controller iff it was made (non-zero
    ///         timestamp) and has not yet aged past `maxCommitmentAge` — i.e. it is still in the exact
    ///         window in which `_consumeCommitment`/`_register` would accept a reveal for it right now
    ///         or in the future (the SAME two-sided check `HandleController`/`TldRegistrarController`
    ///         themselves run in `_consumeCommitment`, mirrored here on purpose so this gate can never
    ///         drift from the contracts' own revert conditions — see
    ///         `test/controller-v2/ControllerV2Cutover.t.sol:test_commitmentIsPending_matchesRevealAgeWindow`).
    ///         A commitment older than `maxCommitmentAge` is already permanently unrevealable on V1
    ///         regardless of this cutover (`CommitmentTooOld`) — it is correctly reported as NOT
    ///         pending (nothing this cutover does changes its fate).
    function commitmentIsPending(uint256 commitmentTimestamp, uint256 maxCommitmentAge) public view returns (bool) {
        if (commitmentTimestamp == 0) return false;
        return commitmentTimestamp + maxCommitmentAge > block.timestamp;
    }

    /// @notice Live gate for the pre-execute check in `deploy/runbooks/integrator-v2-cutover.md` §2: given
    ///         a set of candidate commitment hashes (discovered off-chain from `CommitmentMade` events —
    ///         see `script/pending-commitments.sh`, since both Arc testnet RPCs page `eth_getLogs` in
    ///         ≤10,000-block windows and a forge script has no cheaper way to enumerate them), reads each
    ///         hash's LIVE `commitments(hash)` timestamp off the given V1 controller and reports which are
    ///         still pending. Read-only — no key needed, safe to run any number of times before execute.
    ///
    ///           forge script script/VerifyControllerV2.s.sol \
    ///             --sig 'checkPendingCommitments(address,bytes32[],uint256)' $V1_CONTROLLER '[0x..,0x..]' 86400 \
    ///             --rpc-url $ARC_RPC_URL
    function checkPendingCommitments(address controller, bytes32[] calldata candidateHashes, uint256 maxCommitmentAge)
        external
        view
        returns (uint256 pendingCount)
    {
        require(controller.code.length != 0, "VerifyControllerV2: controller has no code");
        for (uint256 k = 0; k < candidateHashes.length; k++) {
            uint256 ts = ICommitmentsView(controller).commitments(candidateHashes[k]);
            bool pending = commitmentIsPending(ts, maxCommitmentAge);
            if (pending) pendingCount++;
            console2.log(pending ? "  PENDING " : "  clear   ", vm.toString(candidateHashes[k]), ts);
        }
        console2.log(pendingCount == 0 ? "PENDING_COMMITMENTS_CLEAR" : "PENDING_COMMITMENTS_BLOCKING", pendingCount);
        return pendingCount;
    }

    function failureCount() external view returns (uint256) {
        return failures.length;
    }

    function failure(uint256 k) external view returns (string memory) {
        return failures[k];
    }

    function _code(address a, string memory name) internal returns (bool present) {
        present = a != address(0) && a.code.length != 0;
        _check(present, string.concat(name, " ", Strings.toChecksumHexString(a), ": code present (deploy step ran)"));
    }

    function _check(bool cond, string memory what) internal {
        console2.log(cond ? "  ok   " : "  FAIL ", what);
        if (!cond) failures.push(what);
        ok = ok && cond;
    }
}
