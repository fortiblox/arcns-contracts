// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {IArcNSMarket} from "../../src/interfaces/IArcNSMarket.sol";
import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {MarketDeployLib} from "../../script/lib/MarketDeployLib.sol";
import {MarketGrantLib} from "../../script/lib/MarketGrantLib.sol";
import {VerifyMarketRoles} from "../../script/VerifyMarketRoles.s.sol";
import {MockOracle} from "../handle/mocks/MockOracle.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @notice WP-7632 phases 2 + 3, end to end, in-process: a real `TimelockController` (proposer =
///         executor = the Admin Safe stand-in, admin = none — DeployAll's exact constructor shape) holds
///         `DEFAULT_ADMIN_ROLE` on a real `HandleRegistry`; phase 1 deploys the market stack as the
///         deployer (who cannot grant MARKET_ROLE); `MarketGrantLib` builds the governance payload,
///         which is checked byte-for-byte against hand-computed calldata and the op id, then pushed
///         through the timelock exactly as the Safe would (`schedule` → wait `minDelay` → `execute`)
///         using nothing but the emitted calldata; `VerifyMarketRoles.verify` is run before (must fail
///         with the precise MARKET_ROLE line) and after (must pass).
contract MarketGrantTest is Test {
    uint256 internal constant DELAY = 3600; // Arc testnet ARCNS_TIMELOCK_DELAY (deployments/5042002.json)

    HandleRegistry internal registry;
    TimelockController internal timelock;
    MockOracle internal oracle;
    MockERC721 internal tldStandIn;

    address internal deployer = makeAddr("deployer");
    address internal safe = makeAddr("adminSafe");
    address internal treasury = makeAddr("treasury");

    MarketDeployLib.Params internal p;
    MarketDeployLib.Book internal b;

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        timelock = new TimelockController(DELAY, proposers, proposers, address(0));
        oracle = new MockOracle();
        registry = new HandleRegistry(address(timelock), treasury, IArcNSPriceOracle(address(oracle)), 7 days);
        tldStandIn = new MockERC721("Mock TLD", "MTLD");

        address[] memory collections = new address[](2);
        collections[0] = address(registry);
        collections[1] = address(tldStandIn);
        bool[] memory needsMarketRole = new bool[](2);
        needsMarketRole[0] = true;
        p = MarketDeployLib.Params({
            deployer: deployer,
            create2Deployer: deployer,
            timelock: address(timelock),
            pauser: safe,
            treasury: treasury,
            collections: collections,
            needsMarketRole: needsMarketRole,
            config: IArcNSMarket.MarketConfig({
                feeBps: 200, minBidIncrementBps: 500, antiSnipeWindow: 300, antiSnipeExtend: 300, minPrice: 1e18
            }),
            unlockTimelockSecs: 7 days
        });
        vm.startPrank(deployer);
        b = MarketDeployLib.deployMarketStack(p);
        vm.stopPrank();
        MarketDeployLib.assertHandoff(b, p);
    }

    // ---------------------------------------------------------------- phase 2: the payload itself

    function test_payload_matchesHandComputedCalldataAndOpId() public view {
        MarketGrantLib.Payload memory g = MarketGrantLib.build(address(registry), address(b.market), DELAY);

        // Inner call: grantRole(bytes32,address) = 0x2f2ff15d, keccak256("MARKET_ROLE"), market.
        bytes memory data = abi.encodeWithSelector(bytes4(0x2f2ff15d), keccak256("MARKET_ROLE"), address(b.market));
        assertEq(bytes4(0x2f2ff15d), IAccessControl.grantRole.selector, "grantRole selector");
        assertEq(g.target, address(registry));
        assertEq(g.value, 0);
        assertEq(g.data, data, "inner calldata");
        assertEq(g.predecessor, bytes32(0));
        assertEq(g.salt, keccak256(abi.encodePacked("arcns:wp-7632:grant-market-role:", address(b.market))), "salt");
        assertEq(g.delay, DELAY);

        // Operation id: OZ v5 hashOperation = keccak256(abi.encode(target, value, data, predecessor, salt)).
        bytes32 id = keccak256(abi.encode(address(registry), uint256(0), data, bytes32(0), g.salt));
        assertEq(g.operationId, id, "op id (hand)");
        assertEq(
            g.operationId, timelock.hashOperation(g.target, g.value, g.data, g.predecessor, g.salt), "op id (chain)"
        );

        // schedule(address,uint256,bytes,bytes32,bytes32,uint256) = 0x01d5062a,
        // execute(address,uint256,bytes,bytes32,bytes32)          = 0x134008d3.
        assertEq(bytes4(0x01d5062a), bytes4(keccak256("schedule(address,uint256,bytes,bytes32,bytes32,uint256)")));
        assertEq(bytes4(0x134008d3), bytes4(keccak256("execute(address,uint256,bytes,bytes32,bytes32)")));
        assertEq(
            g.scheduleCalldata,
            abi.encodeWithSelector(bytes4(0x01d5062a), address(registry), uint256(0), data, bytes32(0), g.salt, DELAY),
            "schedule calldata"
        );
        assertEq(
            g.executeCalldata,
            abi.encodeWithSelector(bytes4(0x134008d3), address(registry), uint256(0), data, bytes32(0), g.salt),
            "execute calldata"
        );
    }

    function test_payload_safeInputs() public {
        // Pre-validated signature: r = owner (left-padded), s = 0, v = 1 — 65 bytes.
        address owner = makeAddr("ceo");
        bytes memory sig = MarketGrantLib.safePreValidatedSignature(owner);
        assertEq(sig.length, 65);
        assertEq(sig, abi.encodePacked(bytes12(0), owner, bytes32(0), uint8(1)));

        // execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes) = 0x6a761202
        bytes memory inner = hex"deadbeef";
        bytes memory c = MarketGrantLib.safeExecTransactionCalldata(address(timelock), inner, sig);
        assertEq(
            bytes4(0x6a761202),
            bytes4(
                keccak256("execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)")
            )
        );
        assertEq(
            c,
            abi.encodeWithSelector(
                bytes4(0x6a761202),
                address(timelock),
                uint256(0),
                inner,
                uint8(0),
                uint256(0),
                uint256(0),
                uint256(0),
                address(0),
                address(0),
                sig
            )
        );
    }

    function test_payload_rejectsZeroInputs() public {
        vm.expectRevert(bytes("MarketGrantLib: zero addr"));
        this.buildExt(address(0), address(b.market), DELAY);
        vm.expectRevert(bytes("MarketGrantLib: zero delay"));
        this.buildExt(address(registry), address(b.market), 0);
    }

    function buildExt(address r, address m, uint256 d) external pure returns (MarketGrantLib.Payload memory) {
        return MarketGrantLib.build(r, m, d);
    }

    // ---------------------------------------------------------------- phase 2 executed through the timelock

    function _scheduleAsSafe(MarketGrantLib.Payload memory g) internal {
        vm.prank(safe);
        (bool ok,) = address(timelock).call(g.scheduleCalldata);
        assertTrue(ok, "schedule");
    }

    function _executeAsSafe(MarketGrantLib.Payload memory g) internal returns (bool ok) {
        vm.prank(safe);
        (ok,) = address(timelock).call(g.executeCalldata);
    }

    function test_timelock_scheduleWaitExecute_grantsMarketRole() public {
        MarketGrantLib.Payload memory g = MarketGrantLib.build(address(registry), address(b.market), DELAY);
        assertFalse(registry.hasRole(ArcNSConstants.MARKET_ROLE, address(b.market)));
        assertTrue(timelock.getOperationState(g.operationId) == TimelockController.OperationState.Unset);

        _scheduleAsSafe(g);
        assertTrue(timelock.getOperationState(g.operationId) == TimelockController.OperationState.Waiting);
        assertEq(timelock.getTimestamp(g.operationId), block.timestamp + DELAY, "ready at t0 + minDelay");

        // Too early: the executor is refused; the role is still absent.
        vm.warp(block.timestamp + DELAY - 1);
        assertFalse(_executeAsSafe(g), "execute before minDelay must fail");
        assertFalse(registry.hasRole(ArcNSConstants.MARKET_ROLE, address(b.market)));

        vm.warp(block.timestamp + 1);
        assertTrue(timelock.isOperationReady(g.operationId));
        assertTrue(_executeAsSafe(g), "execute at minDelay");
        assertTrue(timelock.isOperationDone(g.operationId));
        assertTrue(registry.hasRole(ArcNSConstants.MARKET_ROLE, address(b.market)), "MARKET_ROLE granted");

        // Nothing else moved: the timelock is still the registry's only admin, the deployer holds nothing.
        assertTrue(registry.hasRole(0x00, address(timelock)));
        assertFalse(registry.hasRole(0x00, deployer));
        assertFalse(registry.hasRole(ArcNSConstants.MARKET_ROLE, deployer));
        MarketDeployLib.assertMarketRole(b, p);
    }

    function test_timelock_deployerCannotScheduleOrGrant() public {
        MarketGrantLib.Payload memory g = MarketGrantLib.build(address(registry), address(b.market), DELAY);
        vm.prank(deployer);
        (bool ok,) = address(timelock).call(g.scheduleCalldata);
        assertFalse(ok, "deployer is not a proposer");
        vm.prank(deployer);
        (ok,) = address(registry).call(g.data);
        assertFalse(ok, "deployer is not the registry admin (the WP-7632 revert)");
    }

    function test_timelock_scheduleBelowMinDelayIsRefused() public {
        MarketGrantLib.Payload memory g = MarketGrantLib.build(address(registry), address(b.market), DELAY - 1);
        vm.prank(safe);
        (bool ok,) = address(timelock).call(g.scheduleCalldata);
        assertFalse(ok, "delay < minDelay refused by the timelock");
    }

    // ---------------------------------------------------------------- phase 3: VerifyMarketRoles

    function _inputs() internal view returns (VerifyMarketRoles.Inputs memory i) {
        i.deployer = deployer;
        i.timelock = address(timelock);
        i.adminSafe = safe;
        i.treasury = treasury;
        i.handleRegistry = address(registry);
        i.collections = p.collections;
        i.market = address(b.market);
        i.nameLocks = address(b.nameLocks);
        i.recordDelegate = address(b.recordDelegate);
        i.textRecords = address(b.textRecords);
        i.attestations = address(b.attestations);
        i.integrators = address(b.integrators);
        i.vouchers = address(b.vouchers);
    }

    function test_verify_failsBeforeGrantWithPreciseLine_passesAfter() public {
        VerifyMarketRoles v = new VerifyMarketRoles();
        assertFalse(v.verify(_inputs()), "before phase 2 the market stack is not verified");
        assertEq(v.failureCount(), 1, "exactly one failing line: the MARKET_ROLE grant");
        assertEq(
            v.failure(0),
            string.concat(
                "HandleRegistry ",
                vm.toString(address(registry)),
                ": MARKET_ROLE granted to ArcNSMarket ",
                vm.toString(address(b.market))
            )
        );

        MarketGrantLib.Payload memory g = MarketGrantLib.build(address(registry), address(b.market), DELAY);
        _scheduleAsSafe(g);
        vm.warp(block.timestamp + DELAY);
        assertTrue(_executeAsSafe(g));

        assertTrue(v.verify(_inputs()), "after phase 2: ROLES_VERIFIED");
        assertEq(v.failureCount(), 0);
    }

    function test_verify_reportsMissingCodeAndBadWiring() public {
        VerifyMarketRoles v = new VerifyMarketRoles();
        VerifyMarketRoles.Inputs memory i = _inputs();
        i.vouchers = makeAddr("nowhere"); // phase 1 not broadcast for this one
        i.treasury = makeAddr("otherTreasury"); // book and chain disagree
        assertFalse(v.verify(i));
        // MARKET_ROLE (not granted yet) + Vouchers code + treasury mismatch.
        assertEq(v.failureCount(), 3);
        assertEq(
            v.failure(0), string.concat("Vouchers ", vm.toString(i.vouchers), ": code present (phase 1 broadcast)")
        );
        assertEq(v.failure(1), "ArcNSMarket: treasury = book treasury");
    }

    function test_verify_flagsDeployerHoldingMarketRole() public {
        // A wrong grant (MARKET_ROLE to the deployer EOA) must be reported even once the market has it.
        MarketGrantLib.Payload memory g = MarketGrantLib.build(address(registry), address(b.market), DELAY);
        _scheduleAsSafe(g);
        vm.warp(block.timestamp + DELAY);
        assertTrue(_executeAsSafe(g));
        vm.prank(address(timelock));
        registry.grantRole(ArcNSConstants.MARKET_ROLE, deployer);

        VerifyMarketRoles v = new VerifyMarketRoles();
        assertFalse(v.verify(_inputs()));
        assertEq(v.failureCount(), 1);
        assertEq(v.failure(0), "HandleRegistry: deployer has no MARKET_ROLE");
    }
}
