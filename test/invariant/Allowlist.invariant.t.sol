// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {HandleController} from "../../src/handle/HandleController.sol";
import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {MockOracle} from "../handle/mocks/MockOracle.sol";

/// @notice WP-144 launch-allowlist safety properties on `HandleController`, exercised on top of
///         `ControllerHandler`'s style (bounded actors, `try/catch`, ghosts read by the invariants —
///         `test/invariant/README.md` conventions). Two properties, deliberately independent of the
///         commit-reveal timing precision `ControllerHandler`/INV-9 already own:
///         - INV-ALLOWLIST-1: no `register()` (no-proof path) call ever *succeeds* at a moment where
///           `allowlistActive()` was true when the call was made.
///         - INV-ALLOWLIST-2: no `registerWithProof` call with a proof that does not place the
///           supplied `owner` on the CURRENT root ever succeeds, active or not.
///         A two-leaf tree over `actors[0]`/`actors[1]` is installed once; `actors[2]` is never on it.
contract AllowlistHandler is Test {
    HandleController public controller;
    HandleRegistry public registry;
    address public admin;

    address[3] public actors;
    string[6] public names = ["apple", "bank", "coin", "dao", "eth", "fort"];
    uint256 public nameCursor;

    bytes32 public root;
    bytes32[] public proof0; // proves actors[0]
    bytes32[] public proof1; // proves actors[1]

    uint256 public calls;
    uint256 public successes;
    bool public plainRegisterSucceededWhileActive;
    bool public wrongProofRegisterSucceeded;
    uint256 public correctProofRegisterOk;
    uint256 public setAllowlistOk;
    uint256 public correctProofAttempts;
    uint256 public correctProofAttemptReverted;
    bytes4 public lastCorrectProofRevertSelector;

    constructor(HandleController controller_, HandleRegistry registry_, address admin_, address[3] memory actors_) {
        controller = controller_;
        registry = registry_;
        admin = admin_;
        actors = actors_;

        bytes32 leaf0 = keccak256(bytes.concat(keccak256(abi.encode(actors[0]))));
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(actors[1]))));
        root = leaf0 < leaf1 ? keccak256(abi.encodePacked(leaf0, leaf1)) : keccak256(abi.encodePacked(leaf1, leaf0));
        proof0 = new bytes32[](1);
        proof0[0] = leaf1;
        proof1 = new bytes32[](1);
        proof1[0] = leaf0;

        for (uint256 i = 0; i < 3; i++) {
            vm.deal(actors[i], 1_000_000 ether);
        }
    }

    function _freshName() internal returns (string memory) {
        string memory n = string.concat(names[nameCursor % 6], vm.toString(nameCursor));
        nameCursor++;
        return n;
    }

    // ---- actions ----------------------------------------------------------------------------------

    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 2 days));
        successes++;
    }

    /// @dev Bounded sunset so most calls land in the valid window; `setAllowlist` itself enforces the
    ///      floor/ceiling, so an out-of-range fuzz value is just an expected revert (not a defect).
    function setAllowlist(bool clear, uint256 sunsetOffset) external {
        calls++;
        vm.prank(admin);
        if (clear) {
            try controller.setAllowlist(bytes32(0), 0) {
                setAllowlistOk++;
                successes++;
            } catch {}
            return;
        }
        uint64 sunset = uint64(block.timestamp + bound(sunsetOffset, 1, controller.MAX_ALLOWLIST_WINDOW()));
        try controller.setAllowlist(root, sunset) {
            setAllowlistOk++;
            successes++;
        } catch {}
    }

    /// @dev Commit, wait past `minCommitmentAge`, then reveal via the plain no-proof `register`.
    function registerPlain(uint256 actorSeed) external {
        calls++;
        address owner = actors[actorSeed % 3];
        string memory name = _freshName();
        bytes32 secret = keccak256(abi.encode("plain", name, owner));
        bytes32 c = controller.makeCommitment(name, owner, secret, 0);
        vm.prank(owner);
        try controller.commit(c) {}
        catch {
            return;
        }
        vm.warp(block.timestamp + controller.minCommitmentAge());

        bool wasActive = controller.allowlistActive();
        uint256 price = controller.quote(name);
        vm.deal(owner, owner.balance + price);
        vm.prank(owner);
        try controller.register{value: price}(name, owner, secret, 0, price) {
            successes++;
            if (wasActive) plainRegisterSucceededWhileActive = true;
        } catch {}
    }

    /// @dev Commit, wait, reveal via `registerWithProof`. `useCorrectProof` picks between the caller's
    ///      own (possibly-not-on-the-tree) proof and a deliberately mismatched one.
    function registerWithProof(uint256 actorSeed, bool useCorrectProof) external {
        calls++;
        address owner = actors[actorSeed % 3];
        string memory name = _freshName();
        bytes32 secret = keccak256(abi.encode("wp", name, owner));
        bytes32 c = controller.makeCommitment(name, owner, secret, 0);
        vm.prank(owner);
        try controller.commit(c) {}
        catch {
            return;
        }
        vm.warp(block.timestamp + controller.minCommitmentAge());

        bytes32[] memory proof;
        bool ownerIsOnTree = owner == actors[0] || owner == actors[1];
        if (useCorrectProof && ownerIsOnTree) {
            proof = owner == actors[0] ? proof0 : proof1;
        } else {
            // Either owner is actors[2] (never on the tree; any proof is "wrong" for it) or we
            // deliberately hand the OTHER actor's proof — never valid for `owner`.
            proof = owner == actors[0] ? proof1 : proof0;
        }
        bool proofIsCorrectForOwner = ownerIsOnTree && useCorrectProof;
        if (proofIsCorrectForOwner) correctProofAttempts++;

        uint256 price = controller.quote(name);
        vm.deal(owner, owner.balance + price);
        vm.prank(owner);
        try controller.registerWithProof{value: price}(name, owner, secret, 0, price, proof) {
            successes++;
            if (proofIsCorrectForOwner) {
                correctProofRegisterOk++;
            } else if (!controller.allowlistActive()) {
                // gate is skipped entirely once inactive: succeeding with a "wrong" proof there is
                // correct behaviour (see `registerWithProof_ignores_proof_once_inactive` unit test),
                // not a violation of INV-ALLOWLIST-2.
            } else {
                wrongProofRegisterSucceeded = true;
            }
        } catch (bytes memory reason) {
            if (proofIsCorrectForOwner) {
                correctProofAttemptReverted++;
                bytes4 selector;
                if (reason.length >= 4) {
                    // solhint-disable-next-line no-inline-assembly
                    assembly {
                        selector := mload(add(reason, 32))
                    }
                }
                lastCorrectProofRevertSelector = selector;
            }
        }
    }
}

contract AllowlistInvariantTest is StdInvariant, Test {
    HandleRegistry internal registry;
    HandleController internal controller;
    MockOracle internal oracle;
    AllowlistHandler internal handler;

    address internal admin = makeAddr("allowlistAdmin");
    address internal deployer = makeAddr("allowlistDeployer");
    address internal pauser = makeAddr("allowlistPauser");
    address internal treasury = makeAddr("allowlistTreasury");

    function setUp() public {
        vm.warp(1_700_000_000);
        oracle = new MockOracle();
        registry = new HandleRegistry(admin, treasury, IArcNSPriceOracle(address(oracle)), 7 days);
        controller = new HandleController(
            HandleController.Init({
                admin: admin,
                genesisAdmin: deployer,
                pauser: pauser,
                registry: address(registry),
                oracle: address(oracle),
                treasury: treasury,
                minCommitmentAge: 60,
                maxCommitmentAge: 24 hours
            })
        );
        oracle.init(ArcNSConstants.HANDLE_ROOT, address(controller), address(registry), 3e18, 1e18);
        vm.prank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(controller));
        vm.prank(deployer);
        controller.sealGenesis(keccak256("root"));

        address[3] memory actors = [makeAddr("allowActor0"), makeAddr("allowActor1"), makeAddr("allowActor2")];
        handler = new AllowlistHandler(controller, registry, admin, actors);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = AllowlistHandler.warp.selector;
        selectors[1] = AllowlistHandler.setAllowlist.selector;
        selectors[2] = AllowlistHandler.registerPlain.selector;
        selectors[3] = AllowlistHandler.registerWithProof.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_ALLOWLIST1_plain_register_never_succeeds_while_active() public view {
        assertFalse(handler.plainRegisterSucceededWhileActive(), "register() succeeded while the allowlist was active");
    }

    function invariant_ALLOWLIST2_wrong_proof_never_succeeds() public view {
        assertFalse(
            handler.wrongProofRegisterSucceeded(), "registerWithProof succeeded with a non-matching proof while active"
        );
    }

    /// @dev Broken-handler guard only (`test/invariant/README.md` convention): with `setUp()`
    ///      re-run fresh before every one of the campaign's `runs`, `afterInvariant` is checked once
    ///      PER RUN, not once for the whole campaign — a narrow, three-way-AND-gated liveness check
    ///      (specific actor AND correct proof AND every commit-reveal precondition) would spuriously
    ///      fail on any individual short run that happened not to roll that exact combination, even
    ///      though the behaviour it certifies is already pinned deterministically by
    ///      `test_registerWithProof_happy_path_for_both_allowlisted_owners` and its fuzz sibling in
    ///      `test/controller/HandleController.t.sol`. So this only asserts the handler generally made
    ///      progress, exactly like `ControllerHandler.afterInvariant`.
    function afterInvariant() public view {
        if (handler.calls() < 12) return;
        assertGt(handler.successes(), 0, "handler never succeeded");
    }
}
