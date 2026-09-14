// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IVeForti} from "../../../src/interfaces/IVeForti.sol";

/// @dev Trivial `IVeForti`: test-settable voting power per account, nothing else
///      (`TldTokenPaymentController` discount tests, issue #192).
contract MockVeForti is IVeForti {
    mapping(address => uint256) public power;

    function setPower(address account, uint256 amount) external {
        power[account] = amount;
    }

    function votingPowerOf(address account) external view returns (uint256) {
        return power[account];
    }
}
