// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {HandleController} from "../../src/handle/HandleController.sol";
import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {MockOracle} from "../handle/mocks/MockOracle.sol";

/// @dev Drives `HandleController` through genesis (reserved batches, seal) and commit-reveal with
///      bounded actors / names. Every registry call is wrapped in `try/catch`; ghosts record the
///      state *before* each reveal so the invariants can be checked without trusting the contract:
///      - `eligibleReveals`: reveals attempted while sealed, name available, commitment aged in
///        `[min, max)` and funded — each MUST succeed (broken-handler detector).
///      - `ineligibleReveals` / `revealOutsideWindowSucceeded`: INV-9.
///      - `preSealMintNotToTreasury`: INV-7 first half.
contract ControllerHandler is Test {
    HandleController public controller;
    HandleRegistry public registry;
    MockOracle public oracle;
    address public treasury;
    address public genesisAdmin;
    uint256 public price;

    address[] public actors;
    string[] public names;

    // ghosts
    uint256 public calls;
    uint256 public successes;
    uint256 public commitOk;
    uint256 public registerOk;
    uint256 public reservedOk;
    uint256 public sealOk;
    uint256 public eligibleReveals;
    uint256 public ineligibleReveals;
    uint256 public preSealRevealAttempts;
    bool public revealOutsideWindowSucceeded;
    bool public revealWithoutCommitmentSucceeded;
    bool public eligibleRevealFailed;
    bool public preSealMintNotToTreasury;
    bool public preSealPublicMint;
    bool public reservedTouchedTotalSold;
    uint256 public sealedAtCall;

    constructor(HandleController controller_, HandleRegistry registry_, MockOracle oracle_, address genesisAdmin_) {
        controller = controller_;
        registry = registry_;
        oracle = oracle_;
        treasury = controller_.treasury();
        genesisAdmin = genesisAdmin_;
        price = oracle_.quote(ArcNSConstants.HANDLE_ROOT, "probe");
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
        // names[0..RESERVED) are the genesis pool; the rest are the public pool
        names.push("apple");
        names.push("bank");
        names.push("coin");
        names.push("alice");
        names.push("bob");
        names.push("carol-x");
        names.push("dave1");
        names.push("eve");
        names.push("frank");
    }

    uint256 public constant RESERVED = 3;

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function nameCount() external view returns (uint256) {
        return names.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Public-pool name.
    function _name(uint256 seed) internal view returns (string memory) {
        return names[RESERVED + (seed % (names.length - RESERVED))];
    }

    function _secret(string memory name, address owner) internal pure returns (bytes32) {
        return keccak256(abi.encode("secret", name, owner));
    }

    // ---- actions ----------------------------------------------------------------------------------

    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 2 hours));
    }

    function commit(uint256 nameSeed, uint256 actorSeed) external {
        calls++;
        string memory name = _name(nameSeed);
        address owner = _actor(actorSeed);
        bytes32 c = controller.makeCommitment(name, owner, _secret(name, owner), 0);
        vm.prank(owner);
        try controller.commit(c) {
            commitOk++;
            successes++;
        } catch {}
    }

    /// @dev Reveal against whatever commitment exists for (name, owner) right now.
    function register(uint256 nameSeed, uint256 actorSeed) external {
        calls++;
        _reveal(_name(nameSeed), _actor(actorSeed));
    }

    /// @dev Commit, age the commitment by a fuzzed amount (inside or outside the window), reveal.
    function commitAgeReveal(uint256 nameSeed, uint256 actorSeed, uint256 age) external {
        calls++;
        string memory name = _name(nameSeed);
        address owner = _actor(actorSeed);
        bytes32 c = controller.makeCommitment(name, owner, _secret(name, owner), 0);
        vm.prank(owner);
        try controller.commit(c) {
            commitOk++;
            successes++;
        } catch {}
        vm.warp(block.timestamp + bound(age, 0, controller.maxCommitmentAge() + 2 hours));
        _reveal(name, owner);
    }

    function _reveal(string memory name, address owner) internal {
        bytes32 secret = _secret(name, owner);
        bytes32 c = controller.makeCommitment(name, owner, secret, 0);
        uint256 ts = controller.commitments(c);
        bool isSealed = controller.genesisSealed();
        bool inWindow = ts != 0 && block.timestamp >= ts + controller.minCommitmentAge()
            && block.timestamp < ts + controller.maxCommitmentAge();
        bool available = controller.available(name);
        bool eligible = isSealed && inWindow && available && !controller.paused();
        if (eligible) eligibleReveals++;
        else ineligibleReveals++;
        if (!isSealed) preSealRevealAttempts++;

        vm.deal(owner, price);
        vm.prank(owner);
        try controller.register{value: price}(name, owner, secret, 0, price) {
            registerOk++;
            successes++;
            if (!inWindow) revealOutsideWindowSucceeded = true;
            if (ts == 0) revealWithoutCommitmentSucceeded = true;
            if (!isSealed) preSealPublicMint = true;
            if (!isSealed && owner != treasury) preSealMintNotToTreasury = true;
        } catch {
            if (eligible) eligibleRevealFailed = true;
        }
    }

    function reservedBatch(uint256 nameSeed, uint256 count) external {
        calls++;
        count = bound(count, 1, RESERVED);
        string[] memory batch = new string[](count);
        uint8[] memory types = new uint8[](count);
        nameSeed = nameSeed % RESERVED;
        for (uint256 i = 0; i < count; i++) {
            batch[i] = names[(nameSeed + i) % RESERVED];
            types[i] = uint8((nameSeed + i) % 4);
        }
        bool isSealed = controller.genesisSealed();
        uint64 soldBefore = oracle.totalSold(ArcNSConstants.HANDLE_ROOT);
        vm.prank(genesisAdmin);
        try controller.registerReservedBatch(batch, types) {
            reservedOk++;
            successes++;
            if (isSealed) preSealMintNotToTreasury = true; // must be unreachable: batch after seal
            if (oracle.totalSold(ArcNSConstants.HANDLE_ROOT) != soldBefore) reservedTouchedTotalSold = true;
            for (uint256 i = 0; i < count; i++) {
                uint256 tokenId = registry.tokenIdOf(batch[i]);
                if (registry.ownerOf(tokenId) != treasury && !isSealed) {
                    // a name minted publicly cannot exist pre-seal; if it does, INV-7 is broken
                    preSealMintNotToTreasury = true;
                }
            }
        } catch {}
    }

    function seal(uint256 rootSeed) external {
        calls++;
        vm.prank(genesisAdmin);
        try controller.sealGenesis(keccak256(abi.encode(rootSeed))) {
            sealOk++;
            successes++;
            sealedAtCall = calls;
        } catch {}
    }

    function withdraw(uint256 actorSeed) external {
        calls++;
        vm.prank(_actor(actorSeed));
        try controller.withdraw() {
            successes++;
        } catch {}
    }
}

/// @notice INV-7 (pre-seal mints only to treasury; GENESIS_ROLE empty after seal) and INV-9 (no
///         reveal outside the commitment window) for `HandleController`.
contract HandleControllerInvariantTest is StdInvariant, Test {
    HandleRegistry internal registry;
    HandleController internal controller;
    MockOracle internal oracle;
    ControllerHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal deployer = makeAddr("deployer");
    address internal pauser = makeAddr("pauser");
    address internal treasury = makeAddr("treasury");

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
        handler = new ControllerHandler(controller, registry, oracle, deployer);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = ControllerHandler.warp.selector;
        selectors[1] = ControllerHandler.commit.selector;
        selectors[2] = ControllerHandler.register.selector;
        selectors[3] = ControllerHandler.commitAgeReveal.selector;
        selectors[4] = ControllerHandler.reservedBatch.selector;
        selectors[5] = ControllerHandler.seal.selector;
        selectors[6] = ControllerHandler.withdraw.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _assertHandlerAlive() internal view {
        // `commit` / `reservedBatch` / `seal` succeed on first touch; only `warp`/`withdraw`/`register`
        // can fail without state, so a handful of calls guarantees a success.
        if (handler.calls() >= 12) assertGt(handler.successes(), 0, "handler never succeeded");
        // every eligible reveal must succeed: otherwise the handler (or the controller) is broken
        assertFalse(handler.eligibleRevealFailed(), "an in-window, funded, available reveal reverted");
    }

    function invariant_INV7_pre_seal_mints_only_to_treasury() public view {
        _assertHandlerAlive();
        assertFalse(handler.preSealMintNotToTreasury(), "pre-seal mint not to treasury");
        assertFalse(handler.preSealPublicMint(), "public register succeeded before seal");
        assertFalse(handler.reservedTouchedTotalSold(), "reserved batch moved totalSold");
        bool isSealed = controller.genesisSealed();
        for (uint256 i = 0; i < handler.nameCount(); i++) {
            uint256 tokenId = registry.tokenIdOf(handler.names(i));
            if (!isSealed && registry.exists(tokenId)) {
                assertEq(registry.ownerOf(tokenId), treasury, "pre-seal owner must be treasury");
            }
        }
        if (isSealed) {
            assertFalse(controller.hasRole(ArcNSConstants.GENESIS_ROLE, deployer), "GENESIS_ROLE survived seal");
            for (uint256 i = 0; i < handler.actorCount(); i++) {
                assertFalse(controller.hasRole(ArcNSConstants.GENESIS_ROLE, handler.actors(i)));
            }
            assertFalse(controller.hasRole(ArcNSConstants.GENESIS_ROLE, admin));
            assertFalse(controller.hasRole(ArcNSConstants.GENESIS_ROLE, address(handler)));
        } else {
            assertEq(oracle.totalSold(ArcNSConstants.HANDLE_ROOT), 0, "no sale before seal");
        }
    }

    function invariant_INV9_no_reveal_outside_commitment_window() public view {
        _assertHandlerAlive();
        assertFalse(handler.revealOutsideWindowSucceeded(), "reveal succeeded outside [min, max)");
        assertFalse(handler.revealWithoutCommitmentSucceeded(), "reveal succeeded without a commitment");
        // every successful reveal was an eligible one, and every eligible one succeeded
        assertEq(handler.registerOk(), handler.eligibleReveals(), "registerOk != eligible reveals");
        assertEq(oracle.totalSold(ArcNSConstants.HANDLE_ROOT), handler.registerOk(), "totalSold != paid registrations");
    }

    function afterInvariant() public view {
        if (handler.calls() < 48) return;
        assertGt(handler.commitOk(), 0, "no commit succeeded");
    }
}
