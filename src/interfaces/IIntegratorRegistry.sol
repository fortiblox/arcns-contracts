// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IIntegratorRegistry — WP-129, integrator revenue-share allowlist (onchain-design §1, M3b)
/// @notice Default 2000 bps (20%) / cap 4000 bps (40%) — the exact x1-handles parameters
///         (onchain-design §1 "Integrator share default 2000 bps, cap 4000"), confirming the plan's
///         "likely 20%/40%" guess; no CEO decision needed. An allow-listed integrator may be given a
///         per-integrator override rate, always clamped to the cap.
///
/// @dev Standalone allowlist + rate resolver + split calculator. **Not yet wired** into
///      `HandleController.register`/`TldRegistrarController.register` (WP-129 acceptance: "6-arg
///      register form still works without integrator") — that requires an additional overload on
///      those contracts, in `contracts/src/handle` and `contracts/src/tld`, out of this lane's file
///      scope. Flagged as a cross-lane follow-up in the M3 PR description; this module is complete,
///      correct and tested so that wiring is a small, mechanical change once scheduled.
interface IIntegratorRegistry {
    event IntegratorSet(address indexed integrator, bool allowed);
    event IntegratorRateSet(address indexed integrator, uint16 rateBps);
    event DefaultRateSet(uint16 rateBps);
    event FeeSplit(address indexed integrator, uint256 amount, uint256 integratorShare, uint16 rateBps);

    error NotIntegrator(address integrator);
    error RateAboveCap(uint16 rateBps, uint16 cap);
    error ZeroAddress();

    /// @notice Cap on any rate, default or per-integrator override — 4000 bps (40%).
    function CAP_BPS() external view returns (uint16);

    function isIntegrator(address integrator) external view returns (bool);
    function defaultRateBps() external view returns (uint16); // 2000 (20%) at deploy
    /// @notice Effective rate for `integrator`: its override if set, else `defaultRateBps()`.
    ///         Reverts `NotIntegrator` if `integrator` is not allow-listed.
    function rateOf(address integrator) external view returns (uint16 rateBps);
    /// @notice Pure helper: `amount * rateOf(integrator) / 10_000`. Reverts if not allow-listed.
    function computeSplit(address integrator, uint256 amount) external view returns (uint256 integratorShare);

    function setIntegrator(address integrator, bool allowed) external; // DEFAULT_ADMIN_ROLE (timelock)
    function setIntegratorRate(address integrator, uint16 rateBps) external; // <= CAP_BPS
    function setDefaultRate(uint16 rateBps) external; // <= CAP_BPS
}
