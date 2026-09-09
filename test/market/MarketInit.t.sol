// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {IArcNSMarket} from "../../src/interfaces/IArcNSMarket.sol";
import {AttestationRegistry} from "../../src/parity/AttestationRegistry.sol";
import {IntegratorRegistry} from "../../src/parity/IntegratorRegistry.sol";
import {MarketDeployLib} from "../../script/lib/MarketDeployLib.sol";
import {MarketInitLib} from "../../script/lib/MarketInitLib.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @dev `MarketInitLib.plan` is `internal`; `vm.expectRevert` needs a real call-depth boundary to
///      observe its reverts (see `MarketDeploy.t.sol`'s harness for the same pattern).
contract MarketInitHarness {
    function plan(AttestationRegistry a, IntegratorRegistry i, MarketInitLib.Desired memory d)
        external
        view
        returns (MarketInitLib.Plan memory)
    {
        return MarketInitLib.plan(a, i, d);
    }

    function build(address[] memory t, bytes[] memory p, uint256 d)
        external
        pure
        returns (MarketInitLib.Payload memory)
    {
        return MarketInitLib.build(t, p, d);
    }
}

/// @notice WP-124 phase 4 ("market-init"), end to end, in-process: phase 1 deploys the market stack as
///         the deployer and hands `DEFAULT_ADMIN_ROLE` on `AttestationRegistry` / `IntegratorRegistry`
///         to a real `TimelockController` (proposer = executor = the Admin Safe stand-in), so the
///         deployer can no longer configure either module (the bug the 2026-09-09 fork rehearsal hit);
///         `MarketInitLib.plan` diffs a config against live state, `build` produces the timelock batch,
///         which is checked byte-for-byte and then pushed through `scheduleBatch` → `minDelay` →
///         `executeBatch` exactly as the Safe would, using nothing but the emitted calldata.
contract MarketInitTest is Test {
    uint256 internal constant DELAY = 3600;

    TimelockController internal timelock;
    MarketInitHarness internal h;
    MarketDeployLib.Book internal b;

    address internal deployer = makeAddr("deployer");
    address internal safe = makeAddr("adminSafe");
    address internal treasury = makeAddr("treasury");
    address internal att1 = makeAddr("attestor1");
    address internal att2 = makeAddr("attestor2");
    address internal int1 = makeAddr("integrator1");
    address internal int2 = makeAddr("integrator2");

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        timelock = new TimelockController(DELAY, proposers, proposers, address(0));
        h = new MarketInitHarness();

        address[] memory collections = new address[](1);
        collections[0] = address(new MockERC721("Mock TLD", "MTLD"));
        MarketDeployLib.Params memory p = MarketDeployLib.Params({
            deployer: deployer,
            create2Deployer: deployer,
            timelock: address(timelock),
            pauser: safe,
            treasury: treasury,
            collections: collections,
            needsMarketRole: new bool[](1),
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

    function _desired() internal view returns (MarketInitLib.Desired memory d) {
        d.attestors = new address[](2);
        d.attestors[0] = att1;
        d.attestors[1] = att2;
        d.integrators = new address[](2);
        d.integrators[0] = int1;
        d.integrators[1] = int2;
        d.hasRate = new bool[](2);
        d.hasRate[0] = true; // int1: explicit 25 %
        d.rateBps = new uint16[](2);
        d.rateBps[0] = 2500; // int2: no override, default rate applies
        d.revokeAttestors = new address[](0);
        d.revokeIntegrators = new address[](0);
    }

    // ---------------------------------------------------------------- the bug: deployer cannot configure

    function test_deployerCannotConfigureModulesAfterPhase1() public {
        vm.startPrank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, bytes32(0))
        );
        b.attestations.setAttestor(att1, true);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, bytes32(0))
        );
        b.integrators.setIntegrator(int1, true);
        vm.stopPrank();
        assertTrue(b.attestations.hasRole(0x00, address(timelock)));
        assertTrue(b.integrators.hasRole(0x00, address(timelock)));
    }

    // ---------------------------------------------------------------- plan: a diff against live state

    function test_plan_freshModules_everyEntryBecomesACall() public view {
        MarketInitLib.Plan memory p = MarketInitLib.plan(b.attestations, b.integrators, _desired());
        assertEq(p.targets.length, 5, "2 attestors + int1 (allow + rate) + int2 (allow)");
        assertEq(p.payloads.length, 5);
        assertEq(p.what.length, 5);

        assertEq(p.targets[0], address(b.attestations));
        assertEq(p.payloads[0], abi.encodeCall(AttestationRegistry.setAttestor, (att1, true)));
        assertEq(p.targets[1], address(b.attestations));
        assertEq(p.payloads[1], abi.encodeCall(AttestationRegistry.setAttestor, (att2, true)));
        assertEq(p.targets[2], address(b.integrators));
        assertEq(p.payloads[2], abi.encodeCall(IntegratorRegistry.setIntegrator, (int1, true)));
        assertEq(p.targets[3], address(b.integrators));
        assertEq(p.payloads[3], abi.encodeCall(IntegratorRegistry.setIntegratorRate, (int1, 2500)));
        assertEq(p.targets[4], address(b.integrators));
        assertEq(p.payloads[4], abi.encodeCall(IntegratorRegistry.setIntegrator, (int2, true)));
        assertEq(
            p.what[3],
            string.concat("IntegratorRegistry.setIntegratorRate(", vm.toString(int1), ", 2500)"),
            "human-readable line"
        );
    }

    function test_plan_onlyTheDiffIsScheduled() public {
        // att1 and int1 (at 2500) already live: only att2, int2 remain.
        vm.startPrank(address(timelock));
        b.attestations.setAttestor(att1, true);
        b.integrators.setIntegrator(int1, true);
        b.integrators.setIntegratorRate(int1, 2500);
        vm.stopPrank();

        MarketInitLib.Plan memory p = MarketInitLib.plan(b.attestations, b.integrators, _desired());
        assertEq(p.targets.length, 2);
        assertEq(p.payloads[0], abi.encodeCall(AttestationRegistry.setAttestor, (att2, true)));
        assertEq(p.payloads[1], abi.encodeCall(IntegratorRegistry.setIntegrator, (int2, true)));

        // A live rate that differs from the config is re-set; one that matches is not.
        vm.prank(address(timelock));
        b.integrators.setIntegratorRate(int1, 1000);
        p = MarketInitLib.plan(b.attestations, b.integrators, _desired());
        assertEq(p.targets.length, 3, "att2 allow, int1 rate, int2 allow");
        assertEq(p.payloads[1], abi.encodeCall(IntegratorRegistry.setIntegratorRate, (int1, 2500)));
    }

    function test_plan_revocationsComeFirstAndOnlyWhenLive() public {
        vm.prank(address(timelock));
        b.attestations.setAttestor(att1, true);

        MarketInitLib.Desired memory d;
        d.attestors = new address[](0);
        d.integrators = new address[](0);
        d.hasRate = new bool[](0);
        d.rateBps = new uint16[](0);
        d.revokeAttestors = new address[](2);
        d.revokeAttestors[0] = att1; // live: revoked
        d.revokeAttestors[1] = att2; // never allowed: no call
        d.revokeIntegrators = new address[](1);
        d.revokeIntegrators[0] = int1; // never allowed: no call

        MarketInitLib.Plan memory p = MarketInitLib.plan(b.attestations, b.integrators, d);
        assertEq(p.targets.length, 1);
        assertEq(p.payloads[0], abi.encodeCall(AttestationRegistry.setAttestor, (att1, false)));
    }

    function test_plan_rejectsRateAboveCap() public {
        MarketInitLib.Desired memory d = _desired();
        d.rateBps[0] = 4001; // CAP_BPS = 4000
        vm.expectRevert(bytes(string.concat("MarketInitLib: rateBps above CAP_BPS for ", vm.toString(int1))));
        h.plan(b.attestations, b.integrators, d);
        d.rateBps[0] = 4000; // exactly the cap is fine
        h.plan(b.attestations, b.integrators, d);
    }

    function test_plan_rejectsZeroDuplicateAndContradiction() public {
        MarketInitLib.Desired memory d = _desired();
        d.attestors[1] = address(0);
        vm.expectRevert(bytes("MarketInitLib: zero address in attestors"));
        h.plan(b.attestations, b.integrators, d);

        d = _desired();
        d.integrators[1] = int1;
        vm.expectRevert(bytes(string.concat("MarketInitLib: duplicate in integrators: ", vm.toString(int1))));
        h.plan(b.attestations, b.integrators, d);

        d = _desired();
        d.revokeAttestors = new address[](1);
        d.revokeAttestors[0] = att2;
        vm.expectRevert(bytes(string.concat("MarketInitLib: attestor both allowed and revoked: ", vm.toString(att2))));
        h.plan(b.attestations, b.integrators, d);
    }

    // ---------------------------------------------------------------- build: the timelock batch

    function test_build_matchesHandComputedCalldataAndOpId() public view {
        MarketInitLib.Plan memory plan = MarketInitLib.plan(b.attestations, b.integrators, _desired());
        MarketInitLib.Payload memory p = MarketInitLib.build(plan.targets, plan.payloads, DELAY);

        assertEq(p.values.length, 5);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(p.values[i], 0);
        }
        assertEq(p.predecessor, bytes32(0));
        assertEq(
            p.salt,
            keccak256(
                abi.encodePacked("arcns:wp-124:market-init:", keccak256(abi.encode(plan.targets, plan.payloads)))
            ),
            "salt"
        );
        // OZ v5 hashOperationBatch = keccak256(abi.encode(targets, values, payloads, predecessor, salt)).
        assertEq(
            p.operationId, keccak256(abi.encode(plan.targets, p.values, plan.payloads, bytes32(0), p.salt)), "op id"
        );
        assertEq(
            p.operationId,
            timelock.hashOperationBatch(p.targets, p.values, p.payloads, p.predecessor, p.salt),
            "op id (chain)"
        );
        // scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256) = 0x8f2a0bb0
        // executeBatch(address[],uint256[],bytes[],bytes32,bytes32)          = 0xe38335e5
        assertEq(
            bytes4(0x8f2a0bb0), bytes4(keccak256("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)"))
        );
        assertEq(bytes4(0xe38335e5), bytes4(keccak256("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)")));
        assertEq(
            p.scheduleCalldata,
            abi.encodeWithSelector(
                bytes4(0x8f2a0bb0), plan.targets, p.values, plan.payloads, bytes32(0), p.salt, DELAY
            ),
            "scheduleBatch calldata"
        );
        assertEq(
            p.executeCalldata,
            abi.encodeWithSelector(bytes4(0xe38335e5), plan.targets, p.values, plan.payloads, bytes32(0), p.salt),
            "executeBatch calldata"
        );
    }

    function test_build_rejectsEmptyPlanAndZeroDelay() public {
        MarketInitLib.Plan memory plan = MarketInitLib.plan(b.attestations, b.integrators, _desired());
        vm.expectRevert(bytes("MarketInitLib: empty or ragged plan"));
        h.build(new address[](0), new bytes[](0), DELAY);
        vm.expectRevert(bytes("MarketInitLib: zero delay"));
        h.build(plan.targets, plan.payloads, 0);
    }

    // ---------------------------------------------------------------- executed through the timelock

    function _scheduleAsSafe(MarketInitLib.Payload memory p) internal {
        vm.prank(safe);
        (bool ok,) = address(timelock).call(p.scheduleCalldata);
        assertTrue(ok, "scheduleBatch");
    }

    function _executeAsSafe(MarketInitLib.Payload memory p) internal returns (bool ok) {
        vm.prank(safe);
        (ok,) = address(timelock).call(p.executeCalldata);
    }

    function test_timelock_scheduleBatchWaitExecuteBatch_appliesConfig_thenPlanIsEmpty() public {
        MarketInitLib.Plan memory plan = MarketInitLib.plan(b.attestations, b.integrators, _desired());
        MarketInitLib.Payload memory p = MarketInitLib.build(plan.targets, plan.payloads, DELAY);

        _scheduleAsSafe(p);
        assertTrue(timelock.getOperationState(p.operationId) == TimelockController.OperationState.Waiting);
        assertEq(timelock.getTimestamp(p.operationId), block.timestamp + DELAY);

        vm.warp(block.timestamp + DELAY - 1);
        assertFalse(_executeAsSafe(p), "executeBatch before minDelay must fail");
        assertFalse(b.attestations.isAttestor(att1));

        vm.warp(block.timestamp + 1);
        assertTrue(_executeAsSafe(p), "executeBatch at minDelay");
        assertTrue(timelock.isOperationDone(p.operationId));

        assertTrue(b.attestations.isAttestor(att1));
        assertTrue(b.attestations.isAttestor(att2));
        assertTrue(b.integrators.isIntegrator(int1));
        assertEq(b.integrators.rateOf(int1), 2500);
        assertTrue(b.integrators.isIntegrator(int2));
        assertEq(b.integrators.rateOf(int2), 2000, "default rate, no override");

        // Idempotent: the same config against the new live state is an empty plan.
        MarketInitLib.Plan memory again = MarketInitLib.plan(b.attestations, b.integrators, _desired());
        assertEq(again.targets.length, 0);

        // Nothing else moved: the timelock is still the only admin, the deployer holds nothing.
        assertTrue(b.attestations.hasRole(0x00, address(timelock)));
        assertFalse(b.attestations.hasRole(0x00, deployer));
        assertTrue(b.integrators.hasRole(0x00, address(timelock)));
        assertFalse(b.integrators.hasRole(0x00, deployer));
    }

    function test_timelock_deployerCannotScheduleBatch() public {
        MarketInitLib.Plan memory plan = MarketInitLib.plan(b.attestations, b.integrators, _desired());
        MarketInitLib.Payload memory p = MarketInitLib.build(plan.targets, plan.payloads, DELAY);
        vm.prank(deployer);
        (bool ok,) = address(timelock).call(p.scheduleCalldata);
        assertFalse(ok, "deployer is not a proposer");
    }

    function test_build_changedConfigIsAFreshOperation() public {
        MarketInitLib.Plan memory plan = MarketInitLib.plan(b.attestations, b.integrators, _desired());
        MarketInitLib.Payload memory p1 = MarketInitLib.build(plan.targets, plan.payloads, DELAY);
        MarketInitLib.Desired memory d = _desired();
        d.rateBps[0] = 3000;
        plan = MarketInitLib.plan(b.attestations, b.integrators, d);
        MarketInitLib.Payload memory p2 = MarketInitLib.build(plan.targets, plan.payloads, DELAY);
        assertTrue(p1.operationId != p2.operationId, "different content, different op id");
        assertTrue(p1.salt != p2.salt);
    }
}
