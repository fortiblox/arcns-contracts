// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IVeForti — placeholder read surface for a future vote-escrowed FORTI stake (issue #192)
/// @notice Design-stage only: the real veFORTI contract, its lockup mechanics and its voting-power
///         curve do not exist yet. This interface exposes nothing but a single balance-style read so
///         `TldTokenPaymentController` can gate a flat payment discount on "does this address hold any
///         veFORTI stake" without depending on any real tokenomics. `TldTokenPaymentController.veForti`
///         defaults to `address(0)` (discount disabled) until an admin points it at a real deployment.
interface IVeForti {
    /// @notice Voting power / stake weight for `account`. Any non-zero value qualifies for the
    ///         controller's flat `discountBps`; the exact curve behind this number is out of scope here.
    function votingPowerOf(address account) external view returns (uint256);
}
