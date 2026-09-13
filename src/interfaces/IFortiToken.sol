// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IFortiToken — placeholder for the future FORTI-Arc token (design-stage, issue #192)
/// @notice Deliberately nothing but a plain `IERC20` alias. The real FORTI-Arc token does not exist
///         yet (docs-only, design-stage in a separate repo) — this interface exists solely so
///         `TldTokenPaymentController` has something concrete to hold and pull via `SafeERC20`. It
///         carries no tokenomics, no minting/burning surface, no governance hooks: none of that is
///         designed yet, and this file must not grow any of it speculatively. Point the controller's
///         immutable `paymentToken` at the real deployed FORTI-Arc token once it exists; this
///         interface can be deleted at that point without touching the controller's logic.
interface IFortiToken is IERC20 {}
