// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Treasury stand-in for `TldRegistrarControllerV2` reentrancy tests (WP #7772). Same pattern as
///      `test/handle/mocks/MaliciousTreasury.sol`: `receive()` fires mid-`_settle` and attempts a raw
///      `call` reentry into the controller so the test can assert on the exact
///      `ReentrancyGuardReentrantCall` selector, without itself reverting (so the outer `register*`
///      call completes and both outcomes are independently observable).
contract MaliciousTreasury {
    address public target;
    bytes public reentryCalldata;
    bool public attempted;
    bool public reentrantCallOk;
    bytes public reentrantReturnData;

    /// @dev Set after construction — see `test/handle/mocks/MaliciousTreasury.sol` for why `target`
    ///      cannot be a constructor argument here.
    function setTarget(address target_) external {
        target = target_;
    }

    function setReentryCalldata(bytes calldata data) external {
        reentryCalldata = data;
    }

    receive() external payable {
        attempted = true;
        bytes memory data = reentryCalldata.length > 0 ? reentryCalldata : abi.encodeWithSignature("withdraw()");
        (bool ok, bytes memory ret) = target.call(data);
        reentrantCallOk = ok;
        reentrantReturnData = ret;
    }
}
