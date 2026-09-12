// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IHandleControllerV2 — WP #7772, the integrator-aware overload added on top of `IHandleController`
/// @notice `HandleControllerV2` implements BOTH this interface and `IHandleController` unchanged: the
///         original 5-arg `register`/6-arg `registerWithProof` forms are byte-for-byte the same
///         behaviour as V1 (WP-129's own acceptance bar — "6-arg register form still works without an
///         integrator" — carries forward to V2 by construction, see `HandleControllerV2` NatSpec). This
///         interface adds ONLY the integrator-aware overloads; everything else (roles, pull ledger,
///         genesis, allowlist, pause) is `IHandleController` verbatim.
interface IHandleControllerV2 {
    /// @notice The allow-list + rate resolver consulted for every non-zero `integrator` argument.
    ///         `DEFAULT_ADMIN_ROLE` (the timelock) is the ONLY writer of its allow-list and rates — see
    ///         `IIntegratorRegistry` NatSpec. This controller never grants, revokes or overrides an
    ///         integrator; it only reads `rateOf`/`computeSplit`, both of which revert `NotIntegrator`
    ///         for any address the timelock has not allow-listed.
    function integratorRegistry() external view returns (address);

    /// @notice `register` plus a revenue-share split. `integrator == address(0)` is refused (use the
    ///         plain `register` instead) so a caller can never accidentally end up on the zero-split
    ///         path expecting a split. Any other `integrator` MUST already be allow-listed on
    ///         `integratorRegistry` or the whole call reverts `NotIntegrator` before any state changes
    ///         (fail-closed: no partial mutation, the caller's commitment is not consumed).
    function registerWithIntegrator(
        string calldata name,
        address owner,
        bytes32 secret,
        uint8 handleType,
        uint256 maxPrice,
        address integrator
    ) external payable;

    /// @notice `registerWithProof` plus the same integrator split as `registerWithIntegrator`.
    function registerWithProofAndIntegrator(
        string calldata name,
        address owner,
        bytes32 secret,
        uint8 handleType,
        uint256 maxPrice,
        bytes32[] calldata proof,
        address integrator
    ) external payable;

    /// @notice Thrown by both integrator-aware overloads for `integrator == address(0)`.
    error IntegratorRequired();
}
