// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Treasury stand-in for `HandleControllerV2` reentrancy tests (WP #7772). Its `receive()` fires
///      mid-`_payTreasury` (after the commitment is consumed and the name is minted, before
///      `_register` returns) and attempts a reentrant call back into the controller's own
///      `nonReentrant`-guarded surface. The attempt is made with a raw `call` (never `try/catch` on a
///      typed interface) so the test can assert on the EXACT revert selector
///      (`ReentrancyGuardTransient.ReentrancyGuardReentrantCall`) rather than merely "it reverted" —
///      any other revert (e.g. a bad-args revert from the reentered function itself) would falsely
///      pass a looser assertion. `receive()` itself never reverts, so the outer `register*` call
///      still completes normally and the test can inspect both outcomes independently.
contract MaliciousTreasury {
    address public target;
    bytes public reentryCalldata;
    bool public attempted;
    bool public reentrantCallOk;
    bytes public reentrantReturnData;

    /// @dev Set after construction: the controller's `Init.treasury` must be this contract's address,
    ///      which is only known once this contract already exists, so `target` cannot be a
    ///      constructor argument (it would be a circular dependency on the controller's own address).
    function setTarget(address target_) external {
        target = target_;
    }

    /// @dev Set once per test to whatever `register*`/`withdraw` calldata should be attempted on
    ///      reentry; defaults to `withdraw()` if never set.
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
