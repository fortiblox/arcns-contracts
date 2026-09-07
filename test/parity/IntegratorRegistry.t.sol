// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IntegratorRegistry} from "../../src/parity/IntegratorRegistry.sol";
import {IIntegratorRegistry} from "../../src/interfaces/IIntegratorRegistry.sol";

/// @notice Unit tests for `IntegratorRegistry` (WP-129): default/override rate resolution, the 4000
///         bps cap, and `computeSplit`.
///
/// @dev This module never emits `FeeSplit` — that event is declared in `IIntegratorRegistry` for a
///      future caller (a controller that actually executes a fee split once this registry is wired
///      into `HandleController`/`TldRegistrarController`, out of this lane's scope). `computeSplit`
///      here is a pure view helper with no side effects, so no test asserts a `FeeSplit` emission.
contract IntegratorRegistryTest is Test {
    IntegratorRegistry internal reg;

    address internal admin = makeAddr("admin");
    address internal attacker = makeAddr("attacker");
    address internal integrator = makeAddr("integrator");
    address internal other = makeAddr("other");

    function setUp() public {
        reg = new IntegratorRegistry(admin);
    }

    function _allow(address who) internal {
        vm.prank(admin);
        reg.setIntegrator(who, true);
    }

    // ---------------------------------------------------------------------------------------------
    // constructor / defaults
    // ---------------------------------------------------------------------------------------------

    function test_constructor_zero_admin_reverts() public {
        vm.expectRevert(IIntegratorRegistry.ZeroAddress.selector);
        new IntegratorRegistry(address(0));
    }

    function test_constructor_defaults() public view {
        assertEq(reg.CAP_BPS(), 4000);
        assertEq(reg.defaultRateBps(), 2000);
        assertTrue(reg.hasRole(reg.DEFAULT_ADMIN_ROLE(), admin));
    }

    // ---------------------------------------------------------------------------------------------
    // setIntegrator
    // ---------------------------------------------------------------------------------------------

    function test_setIntegrator_admin_only_zero_address_and_toggle() public {
        vm.expectRevert(IIntegratorRegistry.ZeroAddress.selector);
        vm.prank(admin);
        reg.setIntegrator(address(0), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, reg.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        reg.setIntegrator(integrator, true);

        assertFalse(reg.isIntegrator(integrator));
        _allow(integrator);
        assertTrue(reg.isIntegrator(integrator));
        vm.prank(admin);
        reg.setIntegrator(integrator, false);
        assertFalse(reg.isIntegrator(integrator));
    }

    // ---------------------------------------------------------------------------------------------
    // rateOf / computeSplit — default path
    // ---------------------------------------------------------------------------------------------

    function test_rateOf_nonIntegrator_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.NotIntegrator.selector, other));
        reg.rateOf(other);
    }

    function test_computeSplit_nonIntegrator_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.NotIntegrator.selector, other));
        reg.computeSplit(other, 1000);
    }

    function test_rateOf_defaults_to_defaultRateBps_when_no_override() public {
        _allow(integrator);
        assertEq(reg.rateOf(integrator), 2000);
    }

    function test_computeSplit_uses_default_rate() public {
        _allow(integrator);
        assertEq(reg.computeSplit(integrator, 10_000), 2000); // 20% of 10_000
        assertEq(reg.computeSplit(integrator, 1), 0); // rounds down
    }

    // ---------------------------------------------------------------------------------------------
    // setIntegratorRate — override, cap, zero-override
    // ---------------------------------------------------------------------------------------------

    function test_setIntegratorRate_requires_allowlisted() public {
        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.NotIntegrator.selector, other));
        vm.prank(admin);
        reg.setIntegratorRate(other, 1000);
    }

    function test_setIntegratorRate_admin_only() public {
        _allow(integrator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, reg.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        reg.setIntegratorRate(integrator, 1000);
    }

    function test_setIntegratorRate_at_cap_succeeds() public {
        _allow(integrator);
        vm.prank(admin);
        reg.setIntegratorRate(integrator, 4000);
        assertEq(reg.rateOf(integrator), 4000);
    }

    function test_setIntegratorRate_above_cap_reverts() public {
        _allow(integrator);
        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.RateAboveCap.selector, 4001, 4000));
        vm.prank(admin);
        reg.setIntegratorRate(integrator, 4001);
    }

    /// @dev A 0-bps override is a legitimate, distinct state from "no override set" — must not be
    ///      confused with falling back to `defaultRateBps` (2000).
    function test_setIntegratorRate_zero_is_respected_not_confused_with_no_override() public {
        _allow(integrator);
        vm.prank(admin);
        reg.setIntegratorRate(integrator, 0);
        assertEq(reg.rateOf(integrator), 0);
        assertEq(reg.computeSplit(integrator, 1_000_000), 0);
    }

    function test_setIntegratorRate_override_then_change() public {
        _allow(integrator);
        vm.startPrank(admin);
        reg.setIntegratorRate(integrator, 3000);
        assertEq(reg.rateOf(integrator), 3000);
        reg.setIntegratorRate(integrator, 500);
        assertEq(reg.rateOf(integrator), 500);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // override survives removal / re-add (documented judgment call)
    // ---------------------------------------------------------------------------------------------

    function test_override_survives_deallowlist_and_reallowlist() public {
        _allow(integrator);
        vm.prank(admin);
        reg.setIntegratorRate(integrator, 3500);
        assertEq(reg.rateOf(integrator), 3500);

        vm.prank(admin);
        reg.setIntegrator(integrator, false);
        // cannot query rateOf while removed
        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.NotIntegrator.selector, integrator));
        reg.rateOf(integrator);

        vm.prank(admin);
        reg.setIntegrator(integrator, true);
        // override rate is restored, not reset to default
        assertEq(reg.rateOf(integrator), 3500);
    }

    // ---------------------------------------------------------------------------------------------
    // setDefaultRate
    // ---------------------------------------------------------------------------------------------

    function test_setDefaultRate_admin_only_and_cap() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, reg.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        reg.setDefaultRate(1000);

        vm.expectRevert(abi.encodeWithSelector(IIntegratorRegistry.RateAboveCap.selector, 4001, 4000));
        vm.prank(admin);
        reg.setDefaultRate(4001);

        vm.prank(admin);
        reg.setDefaultRate(4000);
        assertEq(reg.defaultRateBps(), 4000);
    }

    function test_setDefaultRate_changes_effective_rate_for_non_override_integrators() public {
        _allow(integrator);
        assertEq(reg.rateOf(integrator), 2000);
        vm.prank(admin);
        reg.setDefaultRate(1500);
        assertEq(reg.rateOf(integrator), 1500);

        // but an integrator with an explicit override is unaffected by a default-rate change
        _allow(other);
        vm.prank(admin);
        reg.setIntegratorRate(other, 3000);
        vm.prank(admin);
        reg.setDefaultRate(100);
        assertEq(reg.rateOf(other), 3000);
        assertEq(reg.rateOf(integrator), 100);
    }

    function test_events() public {
        vm.expectEmit(true, true, true, true, address(reg));
        emit IIntegratorRegistry.IntegratorSet(integrator, true);
        vm.prank(admin);
        reg.setIntegrator(integrator, true);

        vm.expectEmit(true, true, true, true, address(reg));
        emit IIntegratorRegistry.IntegratorRateSet(integrator, 2500);
        vm.prank(admin);
        reg.setIntegratorRate(integrator, 2500);

        vm.expectEmit(true, true, true, true, address(reg));
        emit IIntegratorRegistry.DefaultRateSet(1800);
        vm.prank(admin);
        reg.setDefaultRate(1800);
    }
}
