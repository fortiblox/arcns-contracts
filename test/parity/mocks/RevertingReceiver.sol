// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev A recipient that can receive an ERC-20-style credit (claim/refund never sends value) but
///      reverts on `receive()`, so a `withdraw()` pull always fails for it (T-MKT-3-class
///      pull-payment safety test fixture, matches `test/handle/mocks/TestHelpers.sol:RevertingReceiver`).
contract RevertingReceiver {
    error Nope();

    receive() external payable {
        revert Nope();
    }
}
