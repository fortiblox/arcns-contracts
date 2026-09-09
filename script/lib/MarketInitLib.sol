// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {AttestationRegistry} from "../../src/parity/AttestationRegistry.sol";
import {IntegratorRegistry} from "../../src/parity/IntegratorRegistry.sol";

/// @title MarketInitLib — WP-124 phase 4: the governance batch that configures the M3b modules
/// @notice `AttestationRegistry.setAttestor`, `IntegratorRegistry.setIntegrator` and
///         `IntegratorRegistry.setIntegratorRate` are all `onlyRole(DEFAULT_ADMIN_ROLE)`, and phase 1
///         (`MarketDeployLib._handoff`) hands that role to the `TimelockController` and revokes it from
///         the deployer before the deploy script returns. So the "market-init" configuration is the
///         same class of action as the WP-7632 `MARKET_ROLE` grant: it can only be applied by the
///         timelock — Admin Safe → `scheduleBatch` → `minDelay` → `executeBatch` — never by the
///         deployer EOA (the 2026-09-09 fork rehearsal of the previous `MarketInit.s.sol` stub reverted
///         with `AccessControlUnauthorizedAccount(deployer, 0x00)` on its first `setAttestor`).
///
///         Two halves, both without signing or broadcasting:
///           `plan`  — reads the live module state and returns only the calls still needed (an entry
///                     already in the desired state produces no call), so the batch is a pure diff and
///                     re-running after execution yields an empty plan;
///           `build` — turns `(targets, payloads)` into one `TimelockController` batch operation: the
///                     op id (`hashOperationBatch`, computed exactly as OZ v5 does), the
///                     `scheduleBatch(...)` / `executeBatch(...)` calldata the Safe sends to the timelock.
///         The Safe `execTransaction` wrapping is `MarketGrantLib`'s (same 1-of-1 pre-validated
///         signature shape on testnet).
///
///         Salt: `keccak256("arcns:wp-124:market-init:" ‖ keccak256(abi.encode(targets, payloads)))` —
///         deterministic for a given plan (re-running the script re-derives the same op id) and unique
///         per plan content, so a changed config is a fresh timelock operation and never collides with
///         an executed one (`TimelockUnexpectedOperationState`).
library MarketInitLib {
    struct Desired {
        address[] attestors; // allow-list these on AttestationRegistry
        address[] revokeAttestors; // and remove these (both optional; an address in both is an error)
        address[] integrators; // allow-list these on IntegratorRegistry …
        bool[] hasRate; // … with an explicit rate override (index-aligned with `integrators`)
        uint16[] rateBps; // the override (ignored when `hasRate[i]` is false: the default rate applies)
        address[] revokeIntegrators; // remove these (rate overrides are left in storage by design)
    }

    struct Plan {
        address[] targets;
        bytes[] payloads;
        string[] what; // one human-readable line per call, for the logs and the JSON
    }

    struct Payload {
        address[] targets;
        uint256[] values; // all zero
        bytes[] payloads;
        bytes32 predecessor; // 0: no ordering dependency
        bytes32 salt; // opSalt(targets, payloads)
        uint256 delay; // timelock.getMinDelay()
        bytes32 operationId; // TimelockController.hashOperationBatch(targets, values, payloads, predecessor, salt)
        bytes scheduleCalldata; // TimelockController.scheduleBatch(…, delay)
        bytes executeCalldata; // TimelockController.executeBatch(…)
    }

    string internal constant SALT_PREFIX = "arcns:wp-124:market-init:";

    /// @dev Validates `d` (no zero address, no duplicates, no allow+revoke of the same address, every
    ///      rate within `CAP_BPS`) and diffs it against the live module state. Order inside the batch is
    ///      revocations first, then attestors, then per integrator `setIntegrator` before
    ///      `setIntegratorRate` (the rate setter requires the integrator to be allowed at execution
    ///      time — the batch executes in order, so a brand-new integrator's rate is set in the same op).
    function plan(AttestationRegistry attestations, IntegratorRegistry integrators, Desired memory d)
        internal
        view
        returns (Plan memory p)
    {
        validate(integrators, d);
        uint256 max =
            d.revokeAttestors.length + d.revokeIntegrators.length + d.attestors.length + 2 * d.integrators.length;
        address[] memory targets = new address[](max);
        bytes[] memory payloads = new bytes[](max);
        string[] memory what = new string[](max);
        uint256 n;

        for (uint256 i = 0; i < d.revokeAttestors.length; i++) {
            if (attestations.isAttestor(d.revokeAttestors[i])) {
                targets[n] = address(attestations);
                payloads[n] = abi.encodeCall(AttestationRegistry.setAttestor, (d.revokeAttestors[i], false));
                what[n++] = string.concat("AttestationRegistry.setAttestor(", _hex(d.revokeAttestors[i]), ", false)");
            }
        }
        for (uint256 i = 0; i < d.revokeIntegrators.length; i++) {
            if (integrators.isIntegrator(d.revokeIntegrators[i])) {
                targets[n] = address(integrators);
                payloads[n] = abi.encodeCall(IntegratorRegistry.setIntegrator, (d.revokeIntegrators[i], false));
                what[n++] = string.concat("IntegratorRegistry.setIntegrator(", _hex(d.revokeIntegrators[i]), ", false)");
            }
        }
        for (uint256 i = 0; i < d.attestors.length; i++) {
            if (!attestations.isAttestor(d.attestors[i])) {
                targets[n] = address(attestations);
                payloads[n] = abi.encodeCall(AttestationRegistry.setAttestor, (d.attestors[i], true));
                what[n++] = string.concat("AttestationRegistry.setAttestor(", _hex(d.attestors[i]), ", true)");
            }
        }
        for (uint256 i = 0; i < d.integrators.length; i++) {
            address a = d.integrators[i];
            bool allowed = integrators.isIntegrator(a);
            if (!allowed) {
                targets[n] = address(integrators);
                payloads[n] = abi.encodeCall(IntegratorRegistry.setIntegrator, (a, true));
                what[n++] = string.concat("IntegratorRegistry.setIntegrator(", _hex(a), ", true)");
            }
            // `rateOf` reverts for a non-integrator, so a new integrator's rate is always scheduled;
            // an existing one only when the live rate differs.
            if (d.hasRate[i] && (!allowed || integrators.rateOf(a) != d.rateBps[i])) {
                targets[n] = address(integrators);
                payloads[n] = abi.encodeCall(IntegratorRegistry.setIntegratorRate, (a, d.rateBps[i]));
                what[n++] = string.concat(
                    "IntegratorRegistry.setIntegratorRate(", _hex(a), ", ", Strings.toString(d.rateBps[i]), ")"
                );
            }
        }

        p.targets = new address[](n);
        p.payloads = new bytes[](n);
        p.what = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            p.targets[i] = targets[i];
            p.payloads[i] = payloads[i];
            p.what[i] = what[i];
        }
    }

    /// @dev Reverts with a precise message on any config the modules themselves would reject at
    ///      execution time (an hour after scheduling is the wrong moment to learn that) or that is
    ///      self-contradictory.
    function validate(IntegratorRegistry integrators, Desired memory d) internal view {
        require(
            d.integrators.length == d.hasRate.length && d.integrators.length == d.rateBps.length,
            "MarketInitLib: rate arrays"
        );
        uint16 cap = integrators.CAP_BPS();
        _noZeroNoDup(d.attestors, "attestors");
        _noZeroNoDup(d.revokeAttestors, "revokeAttestors");
        _noZeroNoDup(d.integrators, "integrators");
        _noZeroNoDup(d.revokeIntegrators, "revokeIntegrators");
        _disjoint(d.attestors, d.revokeAttestors, "attestor both allowed and revoked");
        _disjoint(d.integrators, d.revokeIntegrators, "integrator both allowed and revoked");
        for (uint256 i = 0; i < d.integrators.length; i++) {
            require(
                !d.hasRate[i] || d.rateBps[i] <= cap,
                string.concat("MarketInitLib: rateBps above CAP_BPS for ", _hex(d.integrators[i]))
            );
        }
    }

    function opSalt(address[] memory targets, bytes[] memory payloads) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(SALT_PREFIX, keccak256(abi.encode(targets, payloads))));
    }

    function build(address[] memory targets, bytes[] memory payloads, uint256 delay)
        internal
        pure
        returns (Payload memory p)
    {
        require(targets.length != 0 && targets.length == payloads.length, "MarketInitLib: empty or ragged plan");
        require(delay != 0, "MarketInitLib: zero delay");
        p.targets = targets;
        p.values = new uint256[](targets.length);
        p.payloads = payloads;
        p.predecessor = bytes32(0);
        p.salt = opSalt(targets, payloads);
        p.delay = delay;
        p.operationId = keccak256(abi.encode(p.targets, p.values, p.payloads, p.predecessor, p.salt));
        p.scheduleCalldata = abi.encodeCall(
            TimelockController.scheduleBatch, (p.targets, p.values, p.payloads, p.predecessor, p.salt, p.delay)
        );
        p.executeCalldata =
            abi.encodeCall(TimelockController.executeBatch, (p.targets, p.values, p.payloads, p.predecessor, p.salt));
    }

    function _noZeroNoDup(address[] memory a, string memory name) private pure {
        for (uint256 i = 0; i < a.length; i++) {
            require(a[i] != address(0), string.concat("MarketInitLib: zero address in ", name));
            for (uint256 j = i + 1; j < a.length; j++) {
                require(a[i] != a[j], string.concat("MarketInitLib: duplicate in ", name, ": ", _hex(a[i])));
            }
        }
    }

    function _disjoint(address[] memory a, address[] memory b, string memory why) private pure {
        for (uint256 i = 0; i < a.length; i++) {
            for (uint256 j = 0; j < b.length; j++) {
                require(a[i] != b[j], string.concat("MarketInitLib: ", why, ": ", _hex(a[i])));
            }
        }
    }

    function _hex(address a) private pure returns (string memory) {
        return Strings.toChecksumHexString(a);
    }
}
