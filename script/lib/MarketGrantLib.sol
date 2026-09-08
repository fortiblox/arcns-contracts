// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";

/// @dev Safe v1.4.1 `execTransaction` (canonical singleton, DeployAll's `ISafeSetup` deploys the proxy).
///      Declared here for calldata encoding only — nothing in this repo ever calls it.
interface ISafeExec {
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);
}

/// @title MarketGrantLib — WP-7632 phase 2: the governance payload that grants MARKET_ROLE to the market
/// @notice Pure calldata arithmetic, no chain access, no signing: given the live `HandleRegistry`, the
///         deployed `ArcNSMarket` and the timelock's `minDelay`, builds the single-call
///         `TimelockController` operation `HandleRegistry.grantRole(MARKET_ROLE, market)` — the inner
///         call, the `schedule(...)` / `execute(...)` calldata the Admin Safe sends to the timelock, the
///         operation id (`hashOperation`, computed exactly as OZ v5 does: `keccak256(abi.encode(target,
///         value, data, predecessor, salt))`) and the Safe `execTransaction` inputs for both steps.
///
///         The same struct is asserted byte-for-byte against hand-computed values and executed through
///         a real `TimelockController` in `test/market/MarketGrant.t.sol`; `script/GrantMarketRole.s.sol`
///         serialises it to `deployments/<chainId>.market-grant.json` for the CEO's Safe shell script.
///
///         Salt: `keccak256("arcns:wp-7632:grant-market-role:" ‖ market)` — deterministic (re-running the
///         script reproduces the same op id, so the CEO can re-derive it later), and unique per market
///         address, so a redeploy of the market to a new address is a fresh timelock operation rather
///         than a `TimelockUnexpectedOperationState` collision with the executed one.
library MarketGrantLib {
    /// @dev Safe signature-encoding constant: `v == 1` marks a "pre-validated" signature — the Safe
    ///      accepts it when `msg.sender == r` (the owner encoded in `r`) or the owner has `approveHash`ed
    ///      the tx (Safe `checkNSignatures`). `s` is unused (0). 65 bytes for a 1-of-1 Safe.
    uint8 internal constant SAFE_SIG_PRE_VALIDATED = 1;
    uint8 internal constant SAFE_OPERATION_CALL = 0;

    struct Payload {
        // --- the timelock operation (single call) ---
        address target; // HandleRegistry
        uint256 value; // 0
        bytes data; // abi.encodeCall(IAccessControl.grantRole, (MARKET_ROLE, market))
        bytes32 predecessor; // 0: no ordering dependency
        bytes32 salt; // MarketGrantLib.opSalt(market)
        uint256 delay; // timelock.getMinDelay() — 3600 s on Arc testnet (WP-113 ARCNS_TIMELOCK_DELAY)
        bytes32 operationId; // TimelockController.hashOperation(target, value, data, predecessor, salt)
        // --- what the proposer/executor (Admin Safe) sends to the timelock ---
        bytes scheduleCalldata; // TimelockController.schedule(target, value, data, predecessor, salt, delay)
        bytes executeCalldata; // TimelockController.execute(target, value, data, predecessor, salt)
    }

    function opSalt(address market) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("arcns:wp-7632:grant-market-role:", market));
    }

    function build(address handleRegistry, address market, uint256 delay) internal pure returns (Payload memory p) {
        require(handleRegistry != address(0) && market != address(0), "MarketGrantLib: zero addr");
        require(delay != 0, "MarketGrantLib: zero delay");
        p.target = handleRegistry;
        p.value = 0;
        p.data = abi.encodeCall(IAccessControl.grantRole, (ArcNSConstants.MARKET_ROLE, market));
        p.predecessor = bytes32(0);
        p.salt = opSalt(market);
        p.delay = delay;
        p.operationId = keccak256(abi.encode(p.target, p.value, p.data, p.predecessor, p.salt));
        p.scheduleCalldata =
            abi.encodeCall(TimelockController.schedule, (p.target, p.value, p.data, p.predecessor, p.salt, p.delay));
        p.executeCalldata =
            abi.encodeCall(TimelockController.execute, (p.target, p.value, p.data, p.predecessor, p.salt));
    }

    /// @dev Pre-validated Safe signature for `owner`: `r = owner`, `s = 0`, `v = 1`. Valid for a Safe with
    ///      threshold 1 whose `execTransaction` is sent BY `owner` (the CEO hot wallet on testnet,
    ///      DeployAll's `ARCNS_ADMIN`); a 2-of-3 mainnet Safe needs real signatures instead (WP-133).
    function safePreValidatedSignature(address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), SAFE_SIG_PRE_VALIDATED);
    }

    /// @dev `Safe.execTransaction` calldata for a plain call `to.call(data)` with no gas refund fields.
    function safeExecTransactionCalldata(address to, bytes memory data, bytes memory signatures)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            ISafeExec.execTransaction, (to, 0, data, SAFE_OPERATION_CALL, 0, 0, 0, address(0), address(0), signatures)
        );
    }
}
