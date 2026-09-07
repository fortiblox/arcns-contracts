// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {AttestationRegistry} from "../src/parity/AttestationRegistry.sol";
import {IntegratorRegistry} from "../src/parity/IntegratorRegistry.sol";

/// @title MarketInit — WP-124 "market-init tool" STUB
/// @notice Post-deploy admin configuration for the M3 stack that is genuinely a CEO decision, not a
///         deploy-time constant: which addresses hold `ATTESTOR_ROLE`-equivalent status on
///         `AttestationRegistry`, and which addresses are allow-listed integrators (and at what rate,
///         within the WP-129 40% cap). Reads `script/config/market-init.json` and applies it against
///         the addresses in `deployments/<chainId>.json` `.market.*`.
///
/// @dev **This is intentionally a stub, not the full `tools/market-init` CLI** the WP-124 row names.
///      `tools/` is a Node/TypeScript workspace (`tools/genesis`, `tools/reservation-sync`,
///      `tools/claim`, …) owned by a different lane's toolchain (api-architect / data-director per
///      `docs/plan/work-packages.md` WP-114/141/312) and outside this lane's file scope
///      (`contracts/**` only). This Foundry script is a fully working, locally-tested equivalent of
///      the SAME operation (idempotent config application, one line of output per entry) so the
///      capability exists today; porting it to a `tools/market-init` TS CLI matching `tools/genesis`'s
///      UX (for a consistent CEO-facing tool surface) is a small, mechanical follow-up flagged in the
///      M3 PR description for whichever lane owns `tools/`.
///
///      Config shape (`script/config/market-init.json`):
///      ```json
///      {
///        "attestors": ["0x...", "0x..."],
///        "integrators": [{"address": "0x...", "rateBps": 2500}]
///      }
///      ```
///      Idempotent: setting an already-allowed attestor/integrator to the same state is a cheap no-op
///      write, never an error — safe to re-run after a partial failure (same idempotency discipline as
///      `tools/genesis --reconcile`, WP-114).
contract MarketInit is Script {
    function run() external {
        string memory book = _readBook();
        address attestationRegistry = vm.parseJsonAddress(book, ".market.AttestationRegistry");
        address integratorRegistry = vm.parseJsonAddress(book, ".market.IntegratorRegistry");
        require(
            attestationRegistry != address(0) && integratorRegistry != address(0),
            "MarketInit: market address book incomplete (run DeployMarket first)"
        );

        string memory cfg = vm.readFile("script/config/market-init.json");

        vm.startBroadcast();
        _applyAttestors(cfg, AttestationRegistry(attestationRegistry));
        _applyIntegrators(cfg, IntegratorRegistry(integratorRegistry));
        vm.stopBroadcast();

        console2.log("MARKET_INIT_APPLIED");
    }

    function _applyAttestors(string memory cfg, AttestationRegistry registry) internal {
        address[] memory attestors = vm.parseJsonAddressArray(cfg, ".attestors");
        for (uint256 i = 0; i < attestors.length; i++) {
            if (!registry.isAttestor(attestors[i])) {
                registry.setAttestor(attestors[i], true);
                console2.log("attestor allowed", attestors[i]);
            }
        }
    }

    function _applyIntegrators(string memory cfg, IntegratorRegistry registry) internal {
        uint256 count = vm.parseJsonUint(cfg, ".integrators.length");
        for (uint256 i = 0; i < count; i++) {
            string memory base = string.concat(".integrators[", vm.toString(i), "]");
            address addr = vm.parseJsonAddress(cfg, string.concat(base, ".address"));
            uint16 rateBps = uint16(vm.parseJsonUint(cfg, string.concat(base, ".rateBps")));
            if (!registry.isIntegrator(addr)) {
                registry.setIntegrator(addr, true);
                console2.log("integrator allowed", addr);
            }
            if (registry.rateOf(addr) != rateBps) {
                registry.setIntegratorRate(addr, rateBps);
                console2.log("integrator rate set", addr, rateBps);
            }
        }
    }

    function _readBook() internal returns (string memory) {
        string memory suffix = vm.envOr("ARCNS_DRY_RUN", false) ? ".dry-run.json" : ".json";
        return vm.readFile(string.concat("deployments/", vm.toString(block.chainid), suffix));
    }
}
