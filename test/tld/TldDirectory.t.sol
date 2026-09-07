// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {TldDirectory} from "../../src/tld/TldDirectory.sol";
import {ITldDirectory} from "../../src/interfaces/ITldDirectory.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {HandleNormalize} from "../../src/lib/HandleNormalize.sol";

/// @notice Every transition and every revert path of the "TLDs are data" table (onchain-design §3.5,
///         SR-09, WP-145 `TldStatusChanged` with `sunsetAt`).
contract TldDirectoryTest is Test {
    bytes32 internal constant ARC = ArcNSConstants.ARC_NODE;
    bytes32 internal constant CIRCLE = ArcNSConstants.CIRCLE_NODE;
    bytes32 internal constant TEST_NODE = keccak256(abi.encodePacked(bytes32(0), keccak256("test")));

    address internal admin = makeAddr("timelock");
    address internal pauser = makeAddr("adminSafe");
    address internal stranger = makeAddr("stranger");
    address internal arcRegistrar = makeAddr("arcRegistrar");
    address internal arcController = makeAddr("arcController");
    address internal circleRegistrar = makeAddr("circleRegistrar");
    address internal circleController = makeAddr("circleController");
    address internal migration = makeAddr("migrationTarget");
    address internal pool = makeAddr("refundPool");

    TldDirectory internal dir;

    function setUp() public {
        vm.warp(1_757_000_000);
        dir = new TldDirectory(admin, pauser);
    }

    function _addArc() internal {
        vm.prank(admin);
        dir.add(ARC, "arc", arcRegistrar, arcController, ARC);
    }

    function _addCircle() internal {
        vm.prank(admin);
        dir.add(CIRCLE, "circle", circleRegistrar, circleController, CIRCLE);
    }

    function _unauthorised(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
    }

    function _rowHash(bytes32 node) internal view returns (bytes32) {
        return keccak256(abi.encode(dir.get(node)));
    }

    // ---------------------------------------------------------------------------------------------
    // add
    // ---------------------------------------------------------------------------------------------

    function test_add_creates_active_row_and_emits() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ITldDirectory.TldAdded(ARC, "arc", arcRegistrar, arcController, ARC);
        vm.expectEmit(true, false, false, true);
        emit ITldDirectory.TldStatusChanged(ARC, uint8(ITldDirectory.TldStatus.Active), 0, address(0), address(0));
        dir.add(ARC, "arc", arcRegistrar, arcController, ARC);

        ITldDirectory.Tld memory row = dir.get(ARC);
        assertEq(row.registrar, arcRegistrar);
        assertEq(row.controller, arcController);
        assertEq(row.namespaceId, ARC);
        assertEq(uint8(row.status), uint8(ITldDirectory.TldStatus.Active));
        assertEq(row.sunsetAt, 0);
        assertEq(row.migrationTarget, address(0));
        assertEq(row.refundPool, address(0));
        assertEq(row.label, "arc");

        assertEq(uint8(dir.statusOf(ARC)), uint8(ITldDirectory.TldStatus.Active));
        assertEq(dir.registrarOf(ARC), arcRegistrar);
        assertEq(dir.controllerOf(ARC), arcController);
        assertTrue(dir.isController(arcController));
        assertFalse(dir.isController(arcRegistrar));
        assertEq(dir.tldNodeOfController(arcController), ARC);
        assertEq(dir.tldNodeOfController(stranger), bytes32(0));
        assertTrue(dir.registrationsOpen(ARC));
        assertTrue(dir.resolvable(ARC));
        assertEq(dir.count(), 1);
        assertEq(dir.tldNodes()[0], ARC);
    }

    function test_add_second_tld_is_independent_row() public {
        _addArc();
        _addCircle();
        assertEq(dir.count(), 2);
        assertEq(dir.tldNodes()[1], CIRCLE);
        assertEq(dir.tldNodeOfController(circleController), CIRCLE);
        assertEq(dir.tldNodeOfController(arcController), ARC);
    }

    function test_add_reverts_TldExists() public {
        _addArc();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITldDirectory.TldExists.selector, ARC));
        dir.add(ARC, "arc", arcRegistrar, arcController, ARC);
    }

    function test_add_reverts_ZeroAddress() public {
        vm.startPrank(admin);
        vm.expectRevert(ITldDirectory.ZeroAddress.selector);
        dir.add(ARC, "arc", address(0), arcController, ARC);
        vm.expectRevert(ITldDirectory.ZeroAddress.selector);
        dir.add(ARC, "arc", arcRegistrar, address(0), ARC);
        vm.stopPrank();
    }

    function test_add_reverts_LabelNodeMismatch() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITldDirectory.LabelNodeMismatch.selector, "circle", ARC));
        dir.add(ARC, "circle", arcRegistrar, arcController, ARC);
    }

    function test_add_reverts_NamespaceIdMismatch() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TldDirectory.NamespaceIdMismatch.selector, ARC, CIRCLE));
        dir.add(ARC, "arc", arcRegistrar, arcController, CIRCLE);
    }

    function test_add_reverts_ControllerInUse() public {
        _addArc();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TldDirectory.ControllerInUse.selector, arcController, ARC));
        dir.add(CIRCLE, "circle", circleRegistrar, arcController, CIRCLE);
    }

    function test_add_admin_only() public {
        vm.prank(pauser);
        vm.expectRevert(_unauthorised(pauser, bytes32(0)));
        dir.add(ARC, "arc", arcRegistrar, arcController, ARC);
        vm.prank(stranger);
        vm.expectRevert(_unauthorised(stranger, bytes32(0)));
        dir.add(ARC, "arc", arcRegistrar, arcController, ARC);
    }

    function test_unknown_row_views() public view {
        assertEq(uint8(dir.statusOf(TEST_NODE)), uint8(ITldDirectory.TldStatus.Unknown));
        assertFalse(dir.registrationsOpen(TEST_NODE));
        assertFalse(dir.resolvable(TEST_NODE));
        assertEq(dir.registrarOf(TEST_NODE), address(0));
        assertEq(dir.controllerOf(TEST_NODE), address(0));
        assertEq(dir.count(), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // pause / unpause
    // ---------------------------------------------------------------------------------------------

    function test_pause_by_pauser_then_unpause_by_admin() public {
        _addArc();
        vm.prank(pauser);
        vm.expectEmit(true, false, false, true);
        emit ITldDirectory.TldStatusChanged(
            ARC, uint8(ITldDirectory.TldStatus.RegistrationsPaused), 0, address(0), address(0)
        );
        dir.pause(ARC);
        assertEq(uint8(dir.statusOf(ARC)), uint8(ITldDirectory.TldStatus.RegistrationsPaused));
        assertFalse(dir.registrationsOpen(ARC));
        assertTrue(dir.resolvable(ARC));

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ITldDirectory.TldStatusChanged(ARC, uint8(ITldDirectory.TldStatus.Active), 0, address(0), address(0));
        dir.unpause(ARC);
        assertTrue(dir.registrationsOpen(ARC));
    }

    function test_pause_by_admin_allowed() public {
        _addArc();
        vm.prank(admin);
        dir.pause(ARC);
        assertEq(uint8(dir.statusOf(ARC)), uint8(ITldDirectory.TldStatus.RegistrationsPaused));
    }

    function test_pause_reverts_for_stranger_and_controller() public {
        _addArc();
        vm.prank(stranger);
        vm.expectRevert(_unauthorised(stranger, ArcNSConstants.PAUSER_ROLE));
        dir.pause(ARC);
        vm.prank(arcController);
        vm.expectRevert(_unauthorised(arcController, ArcNSConstants.PAUSER_ROLE));
        dir.pause(ARC);
    }

    function test_pause_reverts_unless_Active() public {
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(ITldDirectory.TldUnknown.selector, ARC));
        dir.pause(ARC);

        _addArc();
        vm.prank(pauser);
        dir.pause(ARC);
        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITldDirectory.InvalidTransition.selector,
                ARC,
                uint8(ITldDirectory.TldStatus.RegistrationsPaused),
                uint8(ITldDirectory.TldStatus.RegistrationsPaused)
            )
        );
        dir.pause(ARC);

        vm.prank(admin);
        dir.sunset(ARC, uint64(block.timestamp + 30 days), address(0), address(0));
        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITldDirectory.InvalidTransition.selector,
                ARC,
                uint8(ITldDirectory.TldStatus.Sunset),
                uint8(ITldDirectory.TldStatus.RegistrationsPaused)
            )
        );
        dir.pause(ARC);
    }

    function test_unpause_admin_only_pauser_cannot() public {
        _addArc();
        vm.prank(pauser);
        dir.pause(ARC);
        vm.prank(pauser);
        vm.expectRevert(_unauthorised(pauser, bytes32(0)));
        dir.unpause(ARC);
        vm.prank(stranger);
        vm.expectRevert(_unauthorised(stranger, bytes32(0)));
        dir.unpause(ARC);
    }

    function test_unpause_reverts_unless_RegistrationsPaused() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITldDirectory.TldUnknown.selector, ARC));
        dir.unpause(ARC);
        _addArc();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITldDirectory.InvalidTransition.selector,
                ARC,
                uint8(ITldDirectory.TldStatus.Active),
                uint8(ITldDirectory.TldStatus.Active)
            )
        );
        dir.unpause(ARC);
    }

    // ---------------------------------------------------------------------------------------------
    // sunset
    // ---------------------------------------------------------------------------------------------

    function test_sunset_from_active_records_fields_and_emits_sunsetAt() public {
        _addArc();
        uint64 at = uint64(block.timestamp + 180 days);
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ITldDirectory.TldStatusChanged(ARC, uint8(ITldDirectory.TldStatus.Sunset), at, migration, pool);
        dir.sunset(ARC, at, migration, pool);
        ITldDirectory.Tld memory row = dir.get(ARC);
        assertEq(uint8(row.status), uint8(ITldDirectory.TldStatus.Sunset));
        assertEq(row.sunsetAt, at);
        assertEq(row.migrationTarget, migration);
        assertEq(row.refundPool, pool);
        assertFalse(dir.registrationsOpen(ARC));
        assertTrue(dir.resolvable(ARC));
    }

    function test_sunset_from_paused_allowed_with_zero_hooks() public {
        _addArc();
        vm.prank(pauser);
        dir.pause(ARC);
        vm.prank(admin);
        dir.sunset(ARC, uint64(block.timestamp + 1), address(0), address(0));
        assertEq(uint8(dir.statusOf(ARC)), uint8(ITldDirectory.TldStatus.Sunset));
    }

    function test_sunset_reverts_when_date_not_in_future() public {
        _addArc();
        uint64 now_ = uint64(block.timestamp);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITldDirectory.SunsetNotExtendOnly.selector, now_, now_));
        dir.sunset(ARC, now_, address(0), address(0));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITldDirectory.SunsetNotExtendOnly.selector, now_, now_ - 1));
        dir.sunset(ARC, now_ - 1, address(0), address(0));
    }

    function test_sunset_extend_only() public {
        _addArc();
        uint64 at = uint64(block.timestamp + 30 days);
        vm.prank(admin);
        dir.sunset(ARC, at, migration, pool);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITldDirectory.SunsetNotExtendOnly.selector, at, at - 1));
        dir.sunset(ARC, at - 1, migration, pool);

        // Same date is allowed (>=), and the hooks may be re-pointed.
        address pool2 = makeAddr("pool2");
        vm.prank(admin);
        dir.sunset(ARC, at, migration, pool2);
        assertEq(dir.get(ARC).refundPool, pool2);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ITldDirectory.TldStatusChanged(ARC, uint8(ITldDirectory.TldStatus.Sunset), at + 1 days, migration, pool2);
        dir.sunset(ARC, at + 1 days, migration, pool2);
        assertEq(dir.get(ARC).sunsetAt, at + 1 days);
    }

    function test_sunset_reverts_from_Retired_and_Unknown_and_non_admin() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITldDirectory.TldUnknown.selector, ARC));
        dir.sunset(ARC, uint64(block.timestamp + 1), address(0), address(0));

        _addArc();
        vm.prank(pauser);
        vm.expectRevert(_unauthorised(pauser, bytes32(0)));
        dir.sunset(ARC, uint64(block.timestamp + 1), address(0), address(0));

        uint64 at = uint64(block.timestamp + 1);
        vm.prank(admin);
        dir.sunset(ARC, at, address(0), address(0));
        vm.warp(at);
        vm.prank(admin);
        dir.retire(ARC);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITldDirectory.InvalidTransition.selector,
                ARC,
                uint8(ITldDirectory.TldStatus.Retired),
                uint8(ITldDirectory.TldStatus.Sunset)
            )
        );
        dir.sunset(ARC, uint64(block.timestamp + 1), address(0), address(0));
    }

    // ---------------------------------------------------------------------------------------------
    // retire
    // ---------------------------------------------------------------------------------------------

    function test_retire_only_after_sunsetAt() public {
        _addArc();
        uint64 at = uint64(block.timestamp + 30 days);
        vm.prank(admin);
        dir.sunset(ARC, at, migration, pool);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITldDirectory.SunsetNotReached.selector, at, uint64(block.timestamp)));
        dir.retire(ARC);

        vm.warp(at - 1);
        assertTrue(dir.resolvable(ARC));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITldDirectory.SunsetNotReached.selector, at, at - 1));
        dir.retire(ARC);

        vm.warp(at);
        assertFalse(dir.resolvable(ARC), "Sunset past sunsetAt is not resolvable even before retire");
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ITldDirectory.TldStatusChanged(ARC, uint8(ITldDirectory.TldStatus.Retired), at, migration, pool);
        dir.retire(ARC);
        assertEq(uint8(dir.statusOf(ARC)), uint8(ITldDirectory.TldStatus.Retired));
        assertFalse(dir.resolvable(ARC));
        assertFalse(dir.registrationsOpen(ARC));
        // The row keeps its data (holders' refund / migration hooks stay readable).
        assertEq(dir.get(ARC).sunsetAt, at);
        assertEq(dir.get(ARC).refundPool, pool);
        assertEq(dir.registrarOf(ARC), arcRegistrar);
    }

    function test_retire_reverts_unless_Sunset() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITldDirectory.TldUnknown.selector, ARC));
        dir.retire(ARC);
        _addArc();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITldDirectory.InvalidTransition.selector,
                ARC,
                uint8(ITldDirectory.TldStatus.Active),
                uint8(ITldDirectory.TldStatus.Retired)
            )
        );
        dir.retire(ARC);
        vm.prank(pauser);
        dir.pause(ARC);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITldDirectory.InvalidTransition.selector,
                ARC,
                uint8(ITldDirectory.TldStatus.RegistrationsPaused),
                uint8(ITldDirectory.TldStatus.Retired)
            )
        );
        dir.retire(ARC);
    }

    function test_retire_admin_only_and_terminal() public {
        _addArc();
        uint64 at = uint64(block.timestamp + 1);
        vm.prank(admin);
        dir.sunset(ARC, at, address(0), address(0));
        vm.warp(at);
        vm.prank(pauser);
        vm.expectRevert(_unauthorised(pauser, bytes32(0)));
        dir.retire(ARC);
        vm.prank(admin);
        dir.retire(ARC);
        // Terminal: no transition leaves Retired.
        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITldDirectory.InvalidTransition.selector,
                ARC,
                uint8(ITldDirectory.TldStatus.Retired),
                uint8(ITldDirectory.TldStatus.Retired)
            )
        );
        dir.retire(ARC);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITldDirectory.InvalidTransition.selector,
                ARC,
                uint8(ITldDirectory.TldStatus.Retired),
                uint8(ITldDirectory.TldStatus.RegistrationsPaused)
            )
        );
        dir.pause(ARC);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITldDirectory.InvalidTransition.selector,
                ARC,
                uint8(ITldDirectory.TldStatus.Retired),
                uint8(ITldDirectory.TldStatus.Active)
            )
        );
        dir.unpause(ARC);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // resolvable table
    // ---------------------------------------------------------------------------------------------

    function test_resolvable_table() public {
        assertFalse(dir.resolvable(ARC), "Unknown");
        _addArc();
        assertTrue(dir.resolvable(ARC), "Active");
        vm.prank(pauser);
        dir.pause(ARC);
        assertTrue(dir.resolvable(ARC), "RegistrationsPaused");
        uint64 at = uint64(block.timestamp + 10 days);
        vm.prank(admin);
        dir.sunset(ARC, at, address(0), address(0));
        assertTrue(dir.resolvable(ARC), "Sunset before sunsetAt");
        vm.warp(at - 1);
        assertTrue(dir.resolvable(ARC), "Sunset one second before sunsetAt");
        vm.warp(at);
        assertFalse(dir.resolvable(ARC), "Sunset at sunsetAt");
        vm.prank(admin);
        dir.retire(ARC);
        assertFalse(dir.resolvable(ARC), "Retired");
    }

    // ---------------------------------------------------------------------------------------------
    // setController
    // ---------------------------------------------------------------------------------------------

    function test_setController_updates_reverse_map_and_emits() public {
        _addArc();
        address v2 = makeAddr("arcControllerV2");
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ITldDirectory.TldControllerChanged(ARC, arcController, v2);
        dir.setController(ARC, v2);
        assertEq(dir.controllerOf(ARC), v2);
        assertTrue(dir.isController(v2));
        assertFalse(dir.isController(arcController));
        assertEq(dir.tldNodeOfController(v2), ARC);
        assertEq(dir.tldNodeOfController(arcController), bytes32(0));
        // Idempotent re-set to the same controller.
        vm.prank(admin);
        dir.setController(ARC, v2);
        assertEq(dir.tldNodeOfController(v2), ARC);
    }

    function test_setController_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITldDirectory.TldUnknown.selector, ARC));
        dir.setController(ARC, arcController);
        _addArc();
        _addCircle();
        vm.prank(admin);
        vm.expectRevert(ITldDirectory.ZeroAddress.selector);
        dir.setController(ARC, address(0));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TldDirectory.ControllerInUse.selector, circleController, CIRCLE));
        dir.setController(ARC, circleController);
        vm.prank(pauser);
        vm.expectRevert(_unauthorised(pauser, bytes32(0)));
        dir.setController(ARC, makeAddr("v2"));
    }

    // ---------------------------------------------------------------------------------------------
    // per-TLD isolation
    // ---------------------------------------------------------------------------------------------

    function test_circle_lifecycle_leaves_arc_row_untouched() public {
        _addArc();
        _addCircle();
        bytes32 arcBefore = _rowHash(ARC);
        vm.prank(pauser);
        dir.pause(CIRCLE);
        assertEq(_rowHash(ARC), arcBefore);
        vm.prank(admin);
        dir.sunset(CIRCLE, uint64(block.timestamp + 1), migration, pool);
        assertEq(_rowHash(ARC), arcBefore);
        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        dir.retire(CIRCLE);
        assertEq(_rowHash(ARC), arcBefore);
        assertTrue(dir.registrationsOpen(ARC));
        assertTrue(dir.resolvable(ARC));
        assertFalse(dir.resolvable(CIRCLE));
        assertEq(dir.count(), 2);
    }

    function test_roles_are_wired() public view {
        assertTrue(dir.hasRole(dir.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(dir.hasRole(dir.PAUSER_ROLE(), pauser));
        assertFalse(dir.hasRole(dir.DEFAULT_ADMIN_ROLE(), pauser));
        assertEq(dir.PAUSER_ROLE(), keccak256("PAUSER_ROLE"));
    }

    function test_label_node_helper_agrees_with_HandleNormalize() public pure {
        assertEq(HandleNormalize.tldNode("arc"), ARC);
        assertEq(HandleNormalize.tldNode("test"), TEST_NODE);
    }
}
