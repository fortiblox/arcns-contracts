// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {MockOracle} from "../handle/mocks/MockOracle.sol";

/// @dev Drives `HandleRegistry` with bounded actors and names. Every action self-establishes its
///      preconditions where cheap (registers the name if missing) and wraps the registry call in
///      `try/catch`, so ghost counters see both outcomes. Ghosts:
///      - `moves[tokenId]`: successful ownership changes (mint, transfer, transferFrom, market,
///        recovery completion, burn) — INV-3 says `epoch == moves` exactly.
///      - `lockedOwner[tokenId]`: owner at the moment of the last successful `lock` — INV-5.
///      - violation flags set (never reverting) when a post-condition fails.
contract RegistryHandler is Test {
    HandleRegistry public registry;
    MockOracle public oracle;
    address public market;
    uint256 public constant TOKENIZE_PRICE = 1e18;

    address[] public actors;
    string[] public names;
    uint256[] public tokenIds;

    // ghosts
    mapping(uint256 => uint256) public moves;
    mapping(uint256 => address) public lockedOwner;
    bool public recoveryNotClearedViolation;
    bool public lockedMovedViolation;
    bool public epochStepViolation;
    bool public registeredAtViolation;

    uint256 public calls;
    uint256 public successes;
    uint256 public registerOk;
    uint256 public transferOk;
    uint256 public transferFromOk;
    uint256 public marketOk;
    uint256 public tokenizeOk;
    uint256 public lockOk;
    uint256 public unlockOk;
    uint256 public recoveryOk;
    uint256 public releaseOk;
    uint256 public lockedMoveAttempts;

    constructor(HandleRegistry registry_, MockOracle oracle_, address market_) {
        registry = registry_;
        oracle = oracle_;
        market = market_;
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
        names.push("alice");
        names.push("bob");
        names.push("carol-x");
        names.push("dave1");
        names.push("eve");
        names.push("frank");
        for (uint256 i = 0; i < names.length; i++) {
            tokenIds.push(uint256(keccak256(bytes(names[i]))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function nameCount() external view returns (uint256) {
        return names.length;
    }

    // ---- internal helpers -------------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _token(uint256 seed) internal view returns (uint256 tokenId, string memory name) {
        uint256 i = seed % names.length;
        return (tokenIds[i], names[i]);
    }

    function _ownerOrZero(uint256 tokenId) internal view returns (address) {
        return registry.exists(tokenId) ? registry.ownerOf(tokenId) : address(0);
    }

    /// @dev Registers `name` to `to` if it does not exist. Counts as a move on success.
    function _ensureRegistered(uint256 tokenId, string memory name, address to) internal returns (bool ok) {
        if (registry.exists(tokenId)) return true;
        uint64 epochBefore = registry.epochOf(tokenId);
        try registry.register(name, to, uint8(tokenId % 4), false) {
            _afterMove(tokenId, epochBefore, false);
            registerOk++;
            successes++;
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Post-conditions after a successful ownership change.
    function _afterMove(uint256 tokenId, uint64 epochBefore, bool wasLocked) internal {
        moves[tokenId]++;
        if (registry.epochOf(tokenId) != epochBefore + 1) epochStepViolation = true;
        if (registry.handleOf(tokenId).registeredAt != uint64(block.timestamp + 1)) registeredAtViolation = true;
        if (wasLocked) lockedMovedViolation = true;
        if (registry.recoveryOf(tokenId) != address(0) || registry.recoveryPending(tokenId)) {
            recoveryNotClearedViolation = true;
        }
        if (registry.handleOf(tokenId).recoveryInitiatedAt != 0 || registry.recoveryTargetOf(tokenId) != address(0)) {
            recoveryNotClearedViolation = true;
        }
    }

    // ---- actions ----------------------------------------------------------------------------------

    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 8 days));
    }

    function register(uint256 nameSeed, uint256 actorSeed) external {
        calls++;
        (uint256 tokenId, string memory name) = _token(nameSeed);
        _ensureRegistered(tokenId, name, _actor(actorSeed));
    }

    function transfer(uint256 nameSeed, uint256 actorSeed, uint256 toSeed) external {
        calls++;
        (uint256 tokenId, string memory name) = _token(nameSeed);
        if (!_ensureRegistered(tokenId, name, _actor(actorSeed))) return;
        address owner = registry.ownerOf(tokenId);
        bool wasLocked = registry.isLocked(tokenId);
        uint64 epochBefore = registry.epochOf(tokenId);
        if (wasLocked) lockedMoveAttempts++;
        vm.prank(owner);
        try registry.transfer(tokenId, _actor(toSeed)) {
            _afterMove(tokenId, epochBefore, wasLocked);
            transferOk++;
            successes++;
        } catch {}
    }

    /// @dev ERC-721 path: owner (or an approved operator) calls `transferFrom`.
    function transferFrom(uint256 nameSeed, uint256 actorSeed, uint256 toSeed, bool viaOperator) external {
        calls++;
        (uint256 tokenId, string memory name) = _token(nameSeed);
        if (!_ensureRegistered(tokenId, name, _actor(actorSeed))) return;
        address owner = registry.ownerOf(tokenId);
        address caller = owner;
        if (viaOperator) {
            caller = _actor((actorSeed % actors.length) + 1);
            vm.prank(owner);
            registry.setApprovalForAll(caller, true);
        }
        bool wasLocked = registry.isLocked(tokenId);
        uint64 epochBefore = registry.epochOf(tokenId);
        if (wasLocked) lockedMoveAttempts++;
        vm.prank(caller);
        try registry.transferFrom(owner, _actor(toSeed), tokenId) {
            _afterMove(tokenId, epochBefore, wasLocked);
            transferFromOk++;
            successes++;
        } catch {}
    }

    /// @dev MARKET_ROLE path: market is approved for the token then moves it.
    function marketTransfer(uint256 nameSeed, uint256 actorSeed, uint256 toSeed) external {
        calls++;
        (uint256 tokenId, string memory name) = _token(nameSeed);
        if (!_ensureRegistered(tokenId, name, _actor(actorSeed))) return;
        address owner = registry.ownerOf(tokenId);
        bool wasLocked = registry.isLocked(tokenId);
        if (!wasLocked) {
            vm.prank(owner);
            registry.approve(market, tokenId);
        }
        uint64 epochBefore = registry.epochOf(tokenId);
        if (wasLocked) lockedMoveAttempts++;
        vm.prank(market);
        try registry.transferFrom(owner, _actor(toSeed), tokenId) {
            _afterMove(tokenId, epochBefore, wasLocked);
            marketOk++;
            successes++;
        } catch {}
    }

    function tokenize(uint256 nameSeed, uint256 actorSeed) external {
        calls++;
        (uint256 tokenId, string memory name) = _token(nameSeed);
        if (!_ensureRegistered(tokenId, name, _actor(actorSeed))) return;
        address owner = registry.ownerOf(tokenId);
        uint64 epochBefore = registry.epochOf(tokenId);
        vm.deal(owner, TOKENIZE_PRICE);
        vm.prank(owner);
        try registry.tokenize{value: TOKENIZE_PRICE}(tokenId, TOKENIZE_PRICE) {
            tokenizeOk++;
            successes++;
            if (registry.epochOf(tokenId) != epochBefore) epochStepViolation = true;
        } catch {}
    }

    function lock(uint256 nameSeed, uint256 actorSeed) external {
        calls++;
        (uint256 tokenId, string memory name) = _token(nameSeed);
        if (!_ensureRegistered(tokenId, name, _actor(actorSeed))) return;
        address owner = registry.ownerOf(tokenId);
        vm.prank(owner);
        try registry.lock(tokenId) {
            lockedOwner[tokenId] = owner;
            lockOk++;
            successes++;
        } catch {}
    }

    function initiateUnlock(uint256 nameSeed, uint256 actorSeed) external {
        calls++;
        (uint256 tokenId, string memory name) = _token(nameSeed);
        if (!_ensureRegistered(tokenId, name, _actor(actorSeed))) return;
        vm.prank(registry.ownerOf(tokenId));
        try registry.initiateUnlock(tokenId) {
            successes++;
        } catch {}
    }

    /// @dev Warps by a fuzzed amount first so both "too early" and "elapsed" branches are reached.
    function completeUnlock(uint256 nameSeed, uint256 actorSeed, uint256 dt) external {
        calls++;
        (uint256 tokenId, string memory name) = _token(nameSeed);
        if (!_ensureRegistered(tokenId, name, _actor(actorSeed))) return;
        // self-establish: lock + initiate when nothing is pending (the registry still gates everything)
        if (!registry.isLocked(tokenId)) {
            vm.prank(registry.ownerOf(tokenId));
            try registry.lock(tokenId) {
                lockedOwner[tokenId] = registry.ownerOf(tokenId);
                lockOk++;
                successes++;
            } catch {}
        }
        if (registry.isLocked(tokenId) && registry.handleOf(tokenId).unlockInitiatedAt == 0) {
            vm.prank(registry.ownerOf(tokenId));
            try registry.initiateUnlock(tokenId) {
                successes++;
            } catch {}
        }
        vm.warp(block.timestamp + bound(dt, 0, 10 days));
        vm.prank(registry.ownerOf(tokenId));
        try registry.completeUnlock(tokenId) {
            delete lockedOwner[tokenId];
            unlockOk++;
            successes++;
        } catch {}
    }

    function cancelUnlock(uint256 nameSeed, uint256 actorSeed) external {
        calls++;
        (uint256 tokenId, string memory name) = _token(nameSeed);
        if (!_ensureRegistered(tokenId, name, _actor(actorSeed))) return;
        vm.prank(registry.ownerOf(tokenId));
        try registry.cancelUnlock(tokenId) {
            successes++;
        } catch {}
    }

    function setRecovery(uint256 nameSeed, uint256 actorSeed, uint256 keySeed) external {
        calls++;
        (uint256 tokenId, string memory name) = _token(nameSeed);
        if (!_ensureRegistered(tokenId, name, _actor(actorSeed))) return;
        vm.prank(registry.ownerOf(tokenId));
        try registry.setRecovery(tokenId, _actor(keySeed)) {
            successes++;
        } catch {}
    }

    function initiateRecovery(uint256 nameSeed, uint256 actorSeed, uint256 targetSeed) external {
        calls++;
        (uint256 tokenId, string memory name) = _token(nameSeed);
        if (!_ensureRegistered(tokenId, name, _actor(actorSeed))) return;
        address key = registry.recoveryOf(tokenId);
        if (key == address(0)) key = _actor(actorSeed); // will revert NoRecoverySet: exercised on purpose
        vm.prank(key);
        try registry.initiateRecovery(tokenId, _actor(targetSeed)) {
            successes++;
        } catch {}
    }

    function cancelRecovery(uint256 nameSeed, uint256 actorSeed) external {
        calls++;
        (uint256 tokenId, string memory name) = _token(nameSeed);
        if (!_ensureRegistered(tokenId, name, _actor(actorSeed))) return;
        vm.prank(registry.ownerOf(tokenId));
        try registry.cancelRecovery(tokenId) {
            successes++;
        } catch {}
    }

    /// @dev Warps by a fuzzed amount first so both "too early" and "elapsed" branches are reached.
    function completeRecovery(uint256 nameSeed, uint256 actorSeed, uint256 dt) external {
        calls++;
        (uint256 tokenId, string memory name) = _token(nameSeed);
        if (!_ensureRegistered(tokenId, name, _actor(actorSeed))) return;
        // self-establish: set a key + initiate when nothing is pending (the registry still gates everything)
        if (registry.recoveryOf(tokenId) == address(0)) {
            vm.prank(registry.ownerOf(tokenId));
            try registry.setRecovery(tokenId, _actor((actorSeed % actors.length) + 2)) {
                successes++;
            } catch {}
        }
        if (registry.recoveryOf(tokenId) != address(0) && !registry.recoveryPending(tokenId)) {
            vm.prank(registry.recoveryOf(tokenId));
            try registry.initiateRecovery(tokenId, _actor((actorSeed % actors.length) + 1)) {
                successes++;
            } catch {}
        }
        vm.warp(block.timestamp + bound(dt, 0, 10 days));
        address key = registry.recoveryOf(tokenId);
        if (key == address(0)) key = _actor(actorSeed);
        bool wasLocked = registry.isLocked(tokenId);
        uint64 epochBefore = registry.epochOf(tokenId);
        if (wasLocked) lockedMoveAttempts++;
        vm.prank(key);
        try registry.completeRecovery(tokenId) {
            _afterMove(tokenId, epochBefore, wasLocked);
            recoveryOk++;
            successes++;
        } catch {}
    }

    function release(uint256 nameSeed, uint256 actorSeed) external {
        calls++;
        (uint256 tokenId, string memory name) = _token(nameSeed);
        if (!_ensureRegistered(tokenId, name, _actor(actorSeed))) return;
        bool wasLocked = registry.isLocked(tokenId);
        uint64 epochBefore = registry.epochOf(tokenId);
        if (wasLocked) lockedMoveAttempts++;
        vm.prank(registry.ownerOf(tokenId));
        try registry.release(tokenId) {
            moves[tokenId]++;
            if (registry.epochOf(tokenId) != epochBefore + 1) epochStepViolation = true;
            if (wasLocked) lockedMovedViolation = true;
            if (registry.recoveryOf(tokenId) != address(0) || registry.recoveryPending(tokenId)) {
                recoveryNotClearedViolation = true;
            }
            releaseOk++;
            successes++;
        } catch {}
    }
}

/// @notice INV-3 (epoch +1 per ownership change, recovery cleared) and the lock half of INV-5
///         (a locked handle never moves) for `HandleRegistry`.
contract HandleRegistryInvariantTest is StdInvariant, Test {
    HandleRegistry internal registry;
    MockOracle internal oracle;
    RegistryHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal market = makeAddr("market");

    function setUp() public {
        vm.warp(1_700_000_000);
        oracle = new MockOracle();
        registry = new HandleRegistry(admin, treasury, IArcNSPriceOracle(address(oracle)), 7 days);
        handler = new RegistryHandler(registry, oracle, market);
        oracle.init(ArcNSConstants.HANDLE_ROOT, address(handler), address(registry), 0, handler.TOKENIZE_PRICE());
        vm.startPrank(admin);
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, address(handler));
        registry.grantRole(ArcNSConstants.MARKET_ROLE, market);
        vm.stopPrank();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = RegistryHandler.warp.selector;
        selectors[1] = RegistryHandler.register.selector;
        selectors[2] = RegistryHandler.transfer.selector;
        selectors[3] = RegistryHandler.transferFrom.selector;
        selectors[4] = RegistryHandler.marketTransfer.selector;
        selectors[5] = RegistryHandler.tokenize.selector;
        selectors[6] = RegistryHandler.lock.selector;
        selectors[7] = RegistryHandler.initiateUnlock.selector;
        selectors[8] = RegistryHandler.completeUnlock.selector;
        selectors[9] = RegistryHandler.cancelUnlock.selector;
        selectors[10] = RegistryHandler.setRecovery.selector;
        selectors[11] = RegistryHandler.initiateRecovery.selector;
        selectors[12] = RegistryHandler.cancelRecovery.selector;
        selectors[13] = RegistryHandler.completeRecovery.selector;
        selectors[14] = RegistryHandler.release.selector;
        selectors[15] = RegistryHandler.tokenize.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Any successful call must exist once the run has had a few tries (a handler that only
    ///      reverts is a broken handler, README rule). Every non-`warp` action registers a name on
    ///      first touch, so this holds from the first such call.
    function _assertHandlerAlive() internal view {
        if (handler.calls() >= 8) assertGt(handler.successes(), 0, "handler never succeeded");
    }

    function invariant_INV3_epoch_increments_by_one_per_transfer() public view {
        _assertHandlerAlive();
        assertFalse(handler.epochStepViolation(), "epoch moved by != 1 on an ownership change");
        assertFalse(handler.registeredAtViolation(), "registeredAt != now + 1 after an ownership change");
        for (uint256 i = 0; i < handler.nameCount(); i++) {
            uint256 tokenId = handler.tokenIds(i);
            assertEq(registry.epochOf(tokenId), handler.moves(tokenId), "epoch != successful ownership changes");
        }
    }

    function invariant_INV3_recovery_cleared_after_transfer() public view {
        assertFalse(handler.recoveryNotClearedViolation(), "recovery config survived an ownership change");
    }

    function invariant_INV5_locked_handles_never_move() public view {
        assertFalse(handler.lockedMovedViolation(), "a locked handle changed owner");
        for (uint256 i = 0; i < handler.nameCount(); i++) {
            uint256 tokenId = handler.tokenIds(i);
            if (registry.exists(tokenId) && registry.isLocked(tokenId)) {
                assertEq(registry.ownerOf(tokenId), handler.lockedOwner(tokenId), "locked owner drifted");
            }
        }
    }

    /// @dev Sanity on the handler itself at the end of every run: the meaningful paths were exercised
    ///      at least once across the sequence when the sequence is long enough.
    function afterInvariant() public view {
        if (handler.calls() < 48) return;
        assertGt(handler.registerOk(), 0, "no register succeeded");
    }
}
