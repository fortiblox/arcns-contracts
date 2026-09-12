// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IIntegratorRegistry} from "./IIntegratorRegistry.sol";
import {ITldRegistrarController} from "./ITldRegistrarController.sol";

/// @title ITldRegistrarControllerV2 — WP #7772, the integrator-aware overload added on `ITldRegistrarController`
/// @notice `TldRegistrarControllerV2` implements BOTH this interface and `ITldRegistrarController`
///         unchanged: the original `register`/`registerWithProof(Registration, uint256[, proof])` forms
///         are byte-for-byte the same behaviour as V1. This interface adds only the integrator-aware
///         overloads and populates the already-existing verbatim-ENS `NameRegistered.referrer` field
///         (previously hard-coded `bytes32(0)` at every V1 emit site) with the integrator address.
interface ITldRegistrarControllerV2 {
    /// @notice The allow-list + rate resolver consulted for every non-zero `integrator` argument. Same
    ///         contract instance as `HandleControllerV2.integratorRegistry` — one allow-list shared
    ///         across the whole registration surface, `DEFAULT_ADMIN_ROLE` (timelock)-gated.
    function integratorRegistry() external view returns (IIntegratorRegistry);

    /// @notice `register` plus a revenue-share split; `integrator` MUST already be allow-listed on
    ///         `integratorRegistry` (`address(0)` is refused — use plain `register`) or the whole call
    ///         reverts `NotIntegrator` before any state change.
    function registerWithIntegrator(
        ITldRegistrarController.Registration calldata registration,
        uint256 maxPrice,
        address integrator
    ) external payable;

    /// @notice `registerWithProof` plus the same integrator split as `registerWithIntegrator`.
    function registerWithProofAndIntegrator(
        ITldRegistrarController.Registration calldata registration,
        uint256 maxPrice,
        bytes32[] calldata proof,
        address integrator
    ) external payable;

    /// @notice Thrown by both integrator-aware overloads for `integrator == address(0)`.
    error IntegratorRequired();
}
