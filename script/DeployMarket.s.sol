// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";

import {IArcNSMarket} from "../src/interfaces/IArcNSMarket.sol";
import {MarketDeployLib} from "./lib/MarketDeployLib.sol";
import {MarketScriptBase} from "./lib/MarketScriptBase.sol";
import {Salts} from "./lib/Salts.sol";

/// @title DeployMarket — WP-124 / WP-7632 phase 1: testnet deploy #2 (marketplace + M3b parity stack)
/// @notice Reads the M1/M2 address book (`deployments/<chainId>.json`, written by `DeployAll.s.sol`)
///         for the collections to allow-list (`HandleRegistry` + every TLD `BaseRegistrar`) and the
///         governance addresses (timelock, Admin Safe, treasury), deploys `ArcNSMarket` and the six
///         M3b parity modules at their CREATE2 addresses via `MarketDeployLib` (deploy-or-reuse, so a
///         rerun after a crash resumes), allow-lists the collections, hands `DEFAULT_ADMIN_ROLE` on
///         `ArcNSMarket` / `NameLocks` / `AttestationRegistry` / `IntegratorRegistry` to the timelock,
///         asserts the handoff (INV-8 parity, deployer keeps nothing) and appends a `market` object to
///         the address book (`vm.writeJson` with a key path only touches `.market`; the M1/M2 keys are
///         never rewritten).
///
///         This phase does NOT grant `MARKET_ROLE` on `HandleRegistry` (WP-7632 root cause: the deployer
///         no longer holds `DEFAULT_ADMIN_ROLE` there — the WP-113 handoff moved it to the timelock, so
///         the old in-script `grantRole` reverted with `AccessControlUnauthorizedAccount(deployer, 0x00)`
///         on the live chain). The three phases, in order (`docs/runbooks/market-deploy.md`):
///           1. this script (deployer EOA, `--broadcast`)                     → `.market` in the book
///           2. `GrantMarketRole.s.sol` (read-only; prints the timelock op)   → Admin Safe schedules,
///              waits `minDelay` (1 h on testnet), executes                   → MARKET_ROLE granted
///           3. `VerifyMarketRoles.s.sol` (read-only)                         → `ROLES_VERIFIED`
///           4. `MarketInit.s.sol` (read-only; prints the timelock batch)      → attestors / integrators
///              configured by the same Safe → schedule → 1 h → execute path (the modules' admin is the
///              timelock too, so the deployer cannot configure them either)
///         Until phase 2 executes, the market is fully deployed and governed but `HandleRegistry`
///         refuses market-driven transfers of handles (soulbound-bypass path needs MARKET_ROLE); TLD
///         names (plain ERC-721 registrars) trade immediately.
///
///         Environment (names only in `contracts/.env.example`; all optional, defaults shown):
///           ARCNS_ADDRESS_BOOK               path of the M1/M2 book to read (default
///                                             deployments/<chainId>.json, or .dry-run.json with ARCNS_DRY_RUN=1)
///           ARCNS_DRY_RUN                    `1` forces the output to deployments/<chainId>.market-dry-run.json;
///                                             any run without --broadcast writes there anyway (never the book)
///           ARCNS_MARKET_FEE_BPS             default 200 (2%) — CEO may set a different launch fee
///           ARCNS_MARKET_MIN_INCREMENT_BPS   default 500 (5%, onchain-design §8)
///           ARCNS_MARKET_ANTI_SNIPE_WINDOW   default 300 (seconds)
///           ARCNS_MARKET_ANTI_SNIPE_EXTEND   default 300 (seconds, must be >= window)
///           ARCNS_MARKET_MIN_PRICE_USDC      default 1 (1 USDC floor, SR-36 dust guard; 18-dec wei internally)
///           ARCNS_UNLOCK_TIMELOCK            default 604800 (7 days, floored regardless — SR-14 parity)
///         The CREATE2 addresses depend on every one of these plus the sender: rehearse and broadcast
///         with the SAME values and the SAME `--sender`, or the rehearsal's address book is not the one
///         that gets deployed.
///
///         Fork rehearsal against the LIVE book (no broadcast, no keys — the deployer is only simulated,
///         and it is never given anything the real EOA lacks; this is what the WP-7632 fix was verified with):
///           ARCNS_ADDRESS_BOOK=deployments/5042002.json forge script script/DeployMarket.s.sol --sig 'run()' \
///             --rpc-url $ARC_RPC_URL --sender 0xd91d1F6abB7243910B38Fe86CdCd0754a00cB152
///         Local rehearsal (Foundry's in-process EVM, an anvil-fresh `.dry-run.json` book):
///           ARCNS_DRY_RUN=1 forge script script/DeployMarket.s.sol --sig 'run()'
///         Live (CEO only, run from the keystore host, never from this lane):
///           forge script script/DeployMarket.s.sol --sig 'run()' --rpc-url $ARC_RPC_URL --ledger --broadcast \
///             --with-gas-price 20gwei --priority-gas-price 1gwei --verify --verifier blockscout \
///             --verifier-url https://testnet.arcscan.app/api/
contract DeployMarket is MarketScriptBase {
    string[] internal tldLabels = ["arc", "circle"];

    function run() external {
        string memory bookPath = _bookPath();
        string memory json = vm.readFile(bookPath);
        _logBook("ADDRESS_BOOK", bookPath);

        MarketDeployLib.Params memory p = _params(json);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        p.deployer = deployer;
        p.create2Deployer = Salts.CREATE2_FACTORY;
        console2.log("deployer", deployer, "chainid", block.chainid);
        address bookDeployer = vm.parseJsonAddress(json, ".deployer");
        if (deployer != bookDeployer) {
            console2.log("NOTE sender differs from the book's .deployer", bookDeployer, "- CREATE2 addresses differ");
        }

        MarketDeployLib.Book memory predicted = MarketDeployLib.predict(p);
        _logBookAddresses("PREDICTED", predicted);
        bool fresh = address(predicted.market).code.length == 0;

        MarketDeployLib.Book memory b = MarketDeployLib.deployMarketStack(p);
        vm.stopBroadcast();

        MarketDeployLib.assertHandoff(b, p);
        console2.log("MARKET_POST_DEPLOY_ASSERTIONS_OK");
        _logBookAddresses("DEPLOYED", b);
        address[] memory missing = MarketDeployLib.missingMarketRole(b, p);
        for (uint256 i = 0; i < missing.length; i++) {
            console2.log("MARKET_ROLE_PENDING collection", missing[i], "- run phase 2 (GrantMarketRole.s.sol)");
        }
        _writeJson(b, p, bookPath, json, fresh);
    }

    function _params(string memory json) internal view returns (MarketDeployLib.Params memory p) {
        address timelock = vm.parseJsonAddress(json, ".TimelockController");
        address adminSafe = vm.parseJsonAddress(json, ".AdminSafe");
        address treasury = vm.parseJsonAddress(json, ".treasury");
        address handleRegistry = vm.parseJsonAddress(json, ".HandleRegistry");
        _requireAddr(timelock, "TimelockController");
        _requireAddr(adminSafe, "AdminSafe");
        _requireAddr(treasury, "treasury");
        _requireAddr(handleRegistry, "HandleRegistry");

        address[] memory collections = new address[](1 + tldLabels.length);
        bool[] memory needsMarketRole = new bool[](1 + tldLabels.length);
        collections[0] = handleRegistry;
        needsMarketRole[0] = true; // HandleRegistry exposes MARKET_ROLE (soulbound-bypass path) — phase 2
        for (uint256 i = 0; i < tldLabels.length; i++) {
            address registrar = vm.parseJsonAddress(json, string.concat(".tlds.", tldLabels[i], ".BaseRegistrar"));
            _requireAddr(registrar, string.concat("tlds.", tldLabels[i], ".BaseRegistrar"));
            collections[1 + i] = registrar;
            needsMarketRole[1 + i] = false; // verbatim ENS BaseRegistrar has no MARKET_ROLE concept
        }

        p = MarketDeployLib.Params({
            deployer: address(0), // set from vm.readCallers() inside the broadcast window
            create2Deployer: address(0), // idem
            timelock: timelock,
            pauser: adminSafe,
            treasury: treasury,
            collections: collections,
            needsMarketRole: needsMarketRole,
            config: IArcNSMarket.MarketConfig({
                feeBps: uint16(vm.envOr("ARCNS_MARKET_FEE_BPS", uint256(200))),
                minBidIncrementBps: uint16(vm.envOr("ARCNS_MARKET_MIN_INCREMENT_BPS", uint256(500))),
                antiSnipeWindow: uint32(vm.envOr("ARCNS_MARKET_ANTI_SNIPE_WINDOW", uint256(300))),
                antiSnipeExtend: uint32(vm.envOr("ARCNS_MARKET_ANTI_SNIPE_EXTEND", uint256(300))),
                minPrice: uint96(vm.envOr("ARCNS_MARKET_MIN_PRICE_USDC", uint256(1)) * 1e18)
            }),
            unlockTimelockSecs: uint64(vm.envOr("ARCNS_UNLOCK_TIMELOCK", uint256(7 days)))
        });
    }

    function _logBookAddresses(string memory tag, MarketDeployLib.Book memory b) internal pure {
        console2.log(tag, "ArcNSMarket", address(b.market));
        console2.log(tag, "NameLocks", address(b.nameLocks));
        console2.log(tag, "RecordDelegate", address(b.recordDelegate));
        console2.log(tag, "TextRecords", address(b.textRecords));
        console2.log(tag, "AttestationRegistry", address(b.attestations));
        console2.log(tag, "IntegratorRegistry", address(b.integrators));
        console2.log(tag, "Vouchers", address(b.vouchers));
    }

    /// @dev Live broadcast: key-scoped append of `.market` to the input book (only that top-level key is
    ///      touched, so the M1/M2 keys and any sibling keys another lane writes survive). Everything
    ///      else: a self-contained `deployments/<chainId>.market-dry-run.json` (`sourceBook` records which
    ///      book the rehearsal read) that phases 2 and 3 pick up in their own rehearsal.
    ///
    ///      Besides the seven addresses, `.market` carries `deployBlock` — the block this run simulated
    ///      at, i.e. a LOWER bound on the creation block (the broadcast lands at or after it), which is
    ///      what a log consumer needs as its paging floor (both public Arc RPCs reject `eth_getLogs`
    ///      ranges over 10,000 blocks; the app pages from `deployBlock` in ≤ 5,000-block windows) — and
    ///      `bytecodeHashes` (keccak256 of each runtime bytecode, the same field the M1/M2 book carries
    ///      for `deploy/BUILD.md` §4). On a resumed run (the market already had code when this run
    ///      started) the earlier `.market.deployBlock` is kept when the book has one; otherwise the exact
    ///      creation block must be taken from the earlier broadcast's receipts (the NOTE below says so).
    function _writeJson(
        MarketDeployLib.Book memory b,
        MarketDeployLib.Params memory p,
        string memory bookPath,
        string memory bookJson,
        bool fresh
    ) internal {
        uint256 deployBlock = block.number;
        if (!fresh) {
            if (vm.keyExistsJson(bookJson, ".market.deployBlock")) {
                deployBlock = vm.parseJsonUint(bookJson, ".market.deployBlock");
            } else {
                console2.log(
                    "NOTE resumed run: .market.deployBlock is this run's block; take the exact creation block from the first broadcast's receipts"
                );
            }
        }
        string memory hashes = "market.bytecodeHashes";
        vm.serializeBytes32(hashes, "ArcNSMarket", keccak256(address(b.market).code));
        vm.serializeBytes32(hashes, "NameLocks", keccak256(address(b.nameLocks).code));
        vm.serializeBytes32(hashes, "RecordDelegate", keccak256(address(b.recordDelegate).code));
        vm.serializeBytes32(hashes, "TextRecords", keccak256(address(b.textRecords).code));
        vm.serializeBytes32(hashes, "AttestationRegistry", keccak256(address(b.attestations).code));
        vm.serializeBytes32(hashes, "IntegratorRegistry", keccak256(address(b.integrators).code));
        string memory hashesJson = vm.serializeBytes32(hashes, "Vouchers", keccak256(address(b.vouchers).code));

        string memory root = "market";
        vm.serializeAddress(root, "ArcNSMarket", address(b.market));
        vm.serializeAddress(root, "NameLocks", address(b.nameLocks));
        vm.serializeAddress(root, "RecordDelegate", address(b.recordDelegate));
        vm.serializeAddress(root, "TextRecords", address(b.textRecords));
        vm.serializeAddress(root, "AttestationRegistry", address(b.attestations));
        vm.serializeAddress(root, "IntegratorRegistry", address(b.integrators));
        vm.serializeAddress(root, "Vouchers", address(b.vouchers));
        vm.serializeUint(root, "deployBlock", deployBlock);
        string memory marketJson = vm.serializeString(root, "bytecodeHashes", hashesJson);

        if (_isLiveWrite()) {
            vm.writeJson(marketJson, bookPath, ".market");
            console2.log("MARKET_DEPLOYMENTS_WRITTEN", bookPath);
            return;
        }
        string memory outer = "dry-run";
        vm.serializeUint(outer, "chainId", block.chainid);
        vm.serializeString(outer, "sourceBook", bookPath);
        vm.serializeAddress(outer, "deployer", p.deployer);
        string memory out = vm.serializeString(outer, "market", marketJson);
        vm.writeJson(out, _marketDryRunPath());
        console2.log("MARKET_DRY_RUN_WRITTEN", _marketDryRunPath(), "(input book untouched)");
    }
}
