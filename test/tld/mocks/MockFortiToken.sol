// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal mintable ERC20 standing in for the not-yet-built FORTI-Arc token
///      (`TldTokenPaymentController` tests, issue #192). Plain OZ `ERC20`; `mint` is unrestricted
///      because only test code ever deploys this contract.
contract MockFortiToken is ERC20 {
    constructor() ERC20("Mock FORTI", "mFORTI") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
