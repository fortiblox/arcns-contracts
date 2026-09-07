// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IArcNSMarket} from "../src/interfaces/IArcNSMarket.sol";
import {MarketDeployLib} from "./lib/MarketDeployLib.sol";

/// @title DeployMarket — WP-124: testnet deploy #2 (marketplace + M3b parity stack)
/// @notice Reads the M1/M2 address book (`deployments/<chainId>.json`, written by `DeployAll.s.sol`)
///         for the collections to allow-list (`HandleRegistry` + every TLD `BaseRegistrar`) and the
///         governance addresses (timelock, Admin Safe, treasury), deploys `ArcNSMarket` and the six
///         M3b parity modules via `MarketDeployLib`, wires roles/allow-lists, hands admin to the
///         timelock, asserts the handoff (INV-8 parity), and appends a `market` object to the same
///         JSON file (never overwrites the M1/M2 keys — `vm.writeJson` with a key path only touches
///         that key).
///
///         Environment (all required, fail fast; names only in `contracts/.env.example`):
///           ARCNS_MARKET_FEE_BPS             default 200 (2%) — CEO may set a different launch fee
///           ARCNS_MARKET_MIN_INCREMENT_BPS   default 500 (5%, onchain-design §8)
///           ARCNS_MARKET_ANTI_SNIPE_WINDOW   default 300 (seconds)
///           ARCNS_MARKET_ANTI_SNIPE_EXTEND   default 300 (seconds, must be >= window)
///           ARCNS_MARKET_MIN_PRICE_USDC      default 1 (1 USDC floor, SR-36 dust guard; 18-dec wei internally)
///           ARCNS_UNLOCK_TIMELOCK            default 604800 (7 days, floored regardless — SR-14 parity)
///           ARCNS_DRY_RUN                    optional, `1` on an anvil fork rehearsal (no live RPC needed
///                                             today — see the M3 PR description on the rpc.testnet.arc.io
///                                             outage): writes deployments/<chainId>.market-dry-run.json
///
///         Local rehearsal (no broadcast, Foundry's own in-process EVM — this is what CI/this lane
///         actually runs, since the deploy is the CEO's live action):
///           forge script script/DeployMarket.s.sol --sig 'run()'
///         Live (CEO only, run from the keystore host, never from this lane):
///           forge script script/DeployMarket.s.sol --rpc-url $ARC_RPC_URL --ledger --broadcast
///             --with-gas-price 20gwei --priority-gas-price 1gwei --verify --verifier blockscout
///             --verifier-url https://testnet.arcscan.app/api/
contract DeployMarket is Script {
    string[] internal tldLabels = ["arc", "circle"];

    function run() external {
        string memory json = _readBook();

        address timelock = vm.parseJsonAddress(json, ".TimelockController");
        address adminSafe = vm.parseJsonAddress(json, ".AdminSafe");
        address treasury = vm.parseJsonAddress(json, ".treasury");
        address handleRegistry = vm.parseJsonAddress(json, ".HandleRegistry");
        require(
            timelock != address(0) && adminSafe != address(0) && treasury != address(0) && handleRegistry != address(0),
            "DeployMarket: M1/M2 address book incomplete"
        );

        address[] memory collections = new address[](1 + tldLabels.length);
        bool[] memory grantMarketRole = new bool[](1 + tldLabels.length);
        collections[0] = handleRegistry;
        grantMarketRole[0] = true; // HandleRegistry exposes MARKET_ROLE (soulbound-bypass path)
        for (uint256 i = 0; i < tldLabels.length; i++) {
            address registrar = vm.parseJsonAddress(json, string.concat(".tlds.", tldLabels[i], ".BaseRegistrar"));
            require(registrar != address(0), "DeployMarket: TLD registrar missing from address book");
            collections[1 + i] = registrar;
            grantMarketRole[1 + i] = false; // verbatim ENS BaseRegistrar has no MARKET_ROLE concept
        }

        MarketDeployLib.Params memory p = MarketDeployLib.Params({
            deployer: address(0), // set below from vm.readCallers()
            timelock: timelock,
            pauser: adminSafe,
            treasury: treasury,
            collections: collections,
            grantMarketRole: grantMarketRole,
            config: IArcNSMarket.MarketConfig({
                feeBps: uint16(vm.envOr("ARCNS_MARKET_FEE_BPS", uint256(200))),
                minBidIncrementBps: uint16(vm.envOr("ARCNS_MARKET_MIN_INCREMENT_BPS", uint256(500))),
                antiSnipeWindow: uint32(vm.envOr("ARCNS_MARKET_ANTI_SNIPE_WINDOW", uint256(300))),
                antiSnipeExtend: uint32(vm.envOr("ARCNS_MARKET_ANTI_SNIPE_EXTEND", uint256(300))),
                minPrice: uint96(vm.envOr("ARCNS_MARKET_MIN_PRICE_USDC", uint256(1)) * 1e18)
            }),
            unlockTimelockSecs: uint64(vm.envOr("ARCNS_UNLOCK_TIMELOCK", uint256(7 days)))
        });

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        p.deployer = deployer;
        console2.log("deployer", deployer, "chainid", block.chainid);

        // The deployer needs DEFAULT_ADMIN_ROLE on HandleRegistry to grant MARKET_ROLE below. On the
        // real chain this is a timelocked proposal executed by the Admin Safe (WP-113 handoff already
        // moved DEFAULT_ADMIN_ROLE to the timelock); this script therefore assumes it is being run
        // *through* that timelock execution context in production, exactly like `DeployAll`'s own
        // deployer-keeps-admin-for-this-script-only pattern. Local rehearsal (no --broadcast) runs as
        // the default `forge script` sender, which `test/market/MarketDeploy.t.sol` sets up directly.
        MarketDeployLib.Book memory b = MarketDeployLib.deployMarketStack(p);
        vm.stopBroadcast();

        MarketDeployLib.assertHandoff(b, p);
        console2.log("MARKET_POST_DEPLOY_ASSERTIONS_OK");
        _writeJson(b);
    }

    function _readBook() internal returns (string memory) {
        string memory suffix = vm.envOr("ARCNS_DRY_RUN", false) ? ".dry-run.json" : ".json";
        string memory path = string.concat("deployments/", vm.toString(block.chainid), suffix);
        return vm.readFile(path);
    }

    function _writeJson(MarketDeployLib.Book memory b) internal {
        string memory root = "market";
        vm.serializeAddress(root, "ArcNSMarket", address(b.market));
        vm.serializeAddress(root, "NameLocks", address(b.nameLocks));
        vm.serializeAddress(root, "RecordDelegate", address(b.recordDelegate));
        vm.serializeAddress(root, "TextRecords", address(b.textRecords));
        vm.serializeAddress(root, "AttestationRegistry", address(b.attestations));
        vm.serializeAddress(root, "IntegratorRegistry", address(b.integrators));
        string memory marketJson = vm.serializeAddress(root, "Vouchers", address(b.vouchers));

        string memory suffix = vm.envOr("ARCNS_DRY_RUN", false) ? ".market-dry-run.json" : ".json";
        string memory path = string.concat("deployments/", vm.toString(block.chainid), suffix);
        // Key-scoped write: only the top-level "market" key is touched, so the M1/M2 keys already in
        // the file (and any sibling keys another lane writes) survive untouched.
        vm.writeJson(marketJson, path, ".market");
        console2.log("MARKET_DEPLOYMENTS_WRITTEN", path);
    }
}
