// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {NameLocks} from "../../src/parity/NameLocks.sol";
import {NameGiftsDeployLib} from "../../script/lib/NameGiftsDeployLib.sol";
import {Salts} from "../../script/lib/Salts.sol";
import {MockOracle} from "../handle/mocks/MockOracle.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @dev `NameGiftsDeployLib`'s functions are `internal` (inlined) — same `vm.expectRevert` call-depth
///      workaround `MarketDeployHarness` uses in `MarketDeploy.t.sol`.
contract NameGiftsDeployHarness {
    function validate(NameGiftsDeployLib.Params memory p) external pure {
        NameGiftsDeployLib.validateParams(p);
    }

    function assertMarketRole(NameGiftsDeployLib.Book memory b, NameGiftsDeployLib.Params memory p) external view {
        NameGiftsDeployLib.assertMarketRole(b, p);
    }
}

/// @notice M3b: local (no network, no broadcast) exercise of `NameGiftsDeployLib.deployNameGiftsStack`
///         — the same wiring logic `script/DeployNameGifts.s.sol` runs against a live chain — against a
///         real `HandleRegistry` whose `DEFAULT_ADMIN_ROLE` is held by the timelock (the deployer can
///         NOT grant `MARKET_ROLE` there, same WP-7632-class live state `MarketDeploy.t.sol` fixes
///         against) and a `MockERC721` standing in for a TLD registrar (no MARKET_ROLE concept).
///         Mirrors `MarketDeploy.t.sol`'s exact test shape.
contract NameGiftsDeployTest is Test {
    HandleRegistry internal registry;
    MockOracle internal oracle;
    MockERC721 internal tldStandIn;
    NameLocks internal nameLocks;

    address internal deployer = makeAddr("deployer");
    address internal timelock = makeAddr("timelock");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        oracle = new MockOracle();
        registry = new HandleRegistry(timelock, treasury, IArcNSPriceOracle(address(oracle)), 7 days);
        tldStandIn = new MockERC721("Mock TLD", "MTLD");
        nameLocks = new NameLocks(timelock, 7 days); // already-deployed WP-125 module NameGifts reuses
    }

    function _params() internal view returns (NameGiftsDeployLib.Params memory p) {
        address[] memory collections = new address[](2);
        collections[0] = address(registry);
        collections[1] = address(tldStandIn);
        bool[] memory needsMarketRole = new bool[](2);
        needsMarketRole[0] = true;
        needsMarketRole[1] = false;

        p = NameGiftsDeployLib.Params({
            deployer: deployer,
            create2Deployer: deployer, // in-process: CREATE2 derives from the pranked sender
            timelock: timelock,
            nameLocks: address(nameLocks),
            collections: collections,
            needsMarketRole: needsMarketRole
        });
    }

    function _deploy(NameGiftsDeployLib.Params memory p) internal returns (NameGiftsDeployLib.Book memory b) {
        vm.startPrank(deployer);
        b = NameGiftsDeployLib.deployNameGiftsStack(p);
        vm.stopPrank();
    }

    function test_deployNameGiftsStack_wiresRolesAndAllowlist() public {
        NameGiftsDeployLib.Params memory p = _params();
        NameGiftsDeployLib.Book memory b = _deploy(p);

        assertTrue(b.nameGifts.isCollectionAllowed(address(registry)), "handle registry not allowed");
        assertTrue(b.nameGifts.isCollectionAllowed(address(tldStandIn)), "tld stand-in not allowed");

        // MARKET_ROLE is NOT granted by phase 1 — and the phase-1 handoff assertion must pass regardless.
        assertFalse(registry.hasRole(ArcNSConstants.MARKET_ROLE, address(b.nameGifts)), "phase 1 must not grant");
        assertFalse(registry.hasRole(ArcNSConstants.MARKET_ROLE, deployer), "deployer never gets MARKET_ROLE");
        NameGiftsDeployLib.assertHandoff(b, p);
        address[] memory missing = NameGiftsDeployLib.missingMarketRole(b, p);
        assertEq(missing.length, 1, "exactly the registry is pending");
        assertEq(missing[0], address(registry));

        assertEq(b.nameGifts.nameLocks(), address(nameLocks), "nameGifts not wired to the reused NameLocks");
    }

    /// @dev The phase-3 assertion is what still demands the grant — and names the collection + NameGifts
    ///      precisely — until the timelock op has executed; afterwards it passes. This is the check that
    ///      would have caught "forgot to grant MARKET_ROLE" before it shipped.
    function test_assertMarketRole_failsBeforeGovernanceGrant_passesAfter() public {
        NameGiftsDeployLib.Params memory p = _params();
        NameGiftsDeployLib.Book memory b = _deploy(p);
        NameGiftsDeployHarness harness = new NameGiftsDeployHarness();

        vm.expectRevert(
            bytes(
                string.concat(
                    "MARKET_ROLE not granted on ",
                    vm.toString(address(registry)),
                    " to NameGifts ",
                    vm.toString(address(b.nameGifts))
                )
            )
        );
        harness.assertMarketRole(b, p);

        vm.prank(timelock);
        registry.grantRole(ArcNSConstants.MARKET_ROLE, address(b.nameGifts));
        harness.assertMarketRole(b, p);
        assertEq(NameGiftsDeployLib.missingMarketRole(b, p).length, 0);
    }

    function test_predict_matchesDeployedAddress() public {
        NameGiftsDeployLib.Params memory p = _params();
        NameGiftsDeployLib.Book memory predicted = NameGiftsDeployLib.predict(p);
        NameGiftsDeployLib.Book memory b = _deploy(p);
        assertEq(address(predicted.nameGifts), address(b.nameGifts), "nameGifts");
    }

    /// @dev Rerun with identical params after a completed run: nothing is redeployed or re-wired (the
    ///      deployer no longer holds admin), the same book comes back and the handoff still holds.
    function test_deployNameGiftsStack_rerunAfterCompletionIsIdempotent() public {
        NameGiftsDeployLib.Params memory p = _params();
        NameGiftsDeployLib.Book memory first = _deploy(p);
        NameGiftsDeployLib.Book memory second = _deploy(p);
        assertEq(address(first.nameGifts), address(second.nameGifts));
        NameGiftsDeployLib.assertHandoff(second, p);
    }

    function test_deployNameGiftsStack_revertsOnZeroTimelock() public {
        NameGiftsDeployLib.Params memory p = _params();
        p.timelock = address(0);
        NameGiftsDeployHarness harness = new NameGiftsDeployHarness();
        vm.expectRevert(bytes("NameGiftsDeployLib: zero timelock"));
        harness.validate(p);
    }

    function test_deployNameGiftsStack_revertsOnLengthMismatch() public {
        NameGiftsDeployLib.Params memory p = _params();
        address[] memory oneCollection = new address[](1);
        oneCollection[0] = address(registry);
        p.collections = oneCollection;
        NameGiftsDeployHarness harness = new NameGiftsDeployHarness();
        vm.expectRevert(bytes("NameGiftsDeployLib: length mismatch"));
        harness.validate(p);
    }

    function test_deployNameGiftsStack_revertsOnZeroDeployer() public {
        NameGiftsDeployLib.Params memory p = _params();
        p.create2Deployer = address(0);
        NameGiftsDeployHarness harness = new NameGiftsDeployHarness();
        vm.expectRevert(bytes("NameGiftsDeployLib: zero deployer"));
        harness.validate(p);
    }

    /// @dev Proves the deployer window is transient, never externally observable as a completed deploy
    ///      with the deployer still holding admin.
    function test_deployNameGiftsStack_deployerNeverEndsWithAdmin() public {
        NameGiftsDeployLib.Params memory p = _params();
        NameGiftsDeployLib.Book memory b = _deploy(p);
        bytes32 adminRole = b.nameGifts.DEFAULT_ADMIN_ROLE();
        assertFalse(b.nameGifts.hasRole(adminRole, deployer));
        assertTrue(b.nameGifts.hasRole(adminRole, timelock));
    }

    /// @dev `NameGiftsDeployLib` works with `nameLocks == address(0)` too (the market stack not deployed
    ///      yet) — matches `ArcNSMarket`'s own convention for "parity module not deployed yet".
    function test_deployNameGiftsStack_worksWithoutNameLocks() public {
        NameGiftsDeployLib.Params memory p = _params();
        p.nameLocks = address(0);
        NameGiftsDeployLib.Book memory b = _deploy(p);
        assertEq(b.nameGifts.nameLocks(), address(0));
    }
}
