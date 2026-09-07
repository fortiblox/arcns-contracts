// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IIntegratorRegistry} from "../interfaces/IIntegratorRegistry.sol";

/// @title IntegratorRegistry — WP-129, integrator revenue-share allowlist (onchain-design §1, M3b)
/// @notice Standalone allowlist + rate resolver: default 2000 bps (20%), hard cap 4000 bps (40%),
///         with an optional per-integrator override rate always clamped to the cap. Not wired into
///         any registration flow (see `IIntegratorRegistry` NatSpec) — this module is complete,
///         correct and tested on its own so that wiring is a small follow-up.
///
/// @dev Roles: DEFAULT_ADMIN_ROLE = timelock (all setters). `0` is a legitimate override rate (a
///      free-tier integrator), so "no override" is tracked with a separate `_hasOverride` flag
///      rather than overloading `0` as a sentinel. Removing an integrator (`setIntegrator(_, false)`)
///      intentionally leaves any rate override in storage untouched, so re-adding the same integrator
///      restores its prior rate instead of silently resetting it to the default.
contract IntegratorRegistry is IIntegratorRegistry, AccessControl {
    /// @inheritdoc IIntegratorRegistry
    uint16 public constant CAP_BPS = 4000;

    /// @inheritdoc IIntegratorRegistry
    uint16 public defaultRateBps;

    mapping(address integrator => bool allowed) internal _isIntegrator;
    mapping(address integrator => uint16 rateBps) internal _rateOverride;
    mapping(address integrator => bool set) internal _hasOverride;

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        defaultRateBps = 2000;
        emit DefaultRateSet(2000);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IIntegratorRegistry
    function isIntegrator(address integrator) public view returns (bool) {
        return _isIntegrator[integrator];
    }

    /// @inheritdoc IIntegratorRegistry
    function rateOf(address integrator) public view returns (uint16 rateBps) {
        if (!_isIntegrator[integrator]) revert NotIntegrator(integrator);
        return _hasOverride[integrator] ? _rateOverride[integrator] : defaultRateBps;
    }

    /// @inheritdoc IIntegratorRegistry
    function computeSplit(address integrator, uint256 amount) external view returns (uint256 integratorShare) {
        return amount * rateOf(integrator) / 10_000;
    }

    // ---------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IIntegratorRegistry
    function setIntegrator(address integrator, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (integrator == address(0)) revert ZeroAddress();
        _isIntegrator[integrator] = allowed;
        emit IntegratorSet(integrator, allowed);
    }

    /// @inheritdoc IIntegratorRegistry
    function setIntegratorRate(address integrator, uint16 rateBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_isIntegrator[integrator]) revert NotIntegrator(integrator);
        if (rateBps > CAP_BPS) revert RateAboveCap(rateBps, CAP_BPS);
        _rateOverride[integrator] = rateBps;
        _hasOverride[integrator] = true;
        emit IntegratorRateSet(integrator, rateBps);
    }

    /// @inheritdoc IIntegratorRegistry
    function setDefaultRate(uint16 rateBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (rateBps > CAP_BPS) revert RateAboveCap(rateBps, CAP_BPS);
        defaultRateBps = rateBps;
        emit DefaultRateSet(rateBps);
    }
}
