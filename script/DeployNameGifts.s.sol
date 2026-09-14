// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";

import {NameGiftsDeployLib} from "./lib/NameGiftsDeployLib.sol";
import {NameGiftsScriptBase} from "./lib/NameGiftsScriptBase.sol";
import {Salts} from "./lib/Salts.sol";

/// @title DeployNameGifts — M3b phase 1: the `NameGifts` send-a-name-by-email escrow
/// @notice Sibling of `DeployMarket.s.sol`, same three-phase shape (`docs/runbooks/market-deploy.md`,
///         WP-7632): reads the M1/M2 address book for the collections to allow-list (`HandleRegistry` +
///         every TLD `BaseRegistrar`) and the governance addresses (timelock, treasury Safe not needed —
///         `NameGifts` never custodies value), reads `.market.NameLocks` (WP-125, already deployed) to
///         reuse rather than redeploy, deploys `NameGifts` at its CREATE2 address via
///         `NameGiftsDeployLib` (deploy-or-reuse, so a rerun after a crash resumes), allow-lists the
///         collections, hands `DEFAULT_ADMIN_ROLE` to the timelock, asserts the handoff (INV-8 parity)
///         and appends a `nameGifts` object to the address book.
///
///         This phase does NOT grant `MARKET_ROLE` on `HandleRegistry` (same WP-7632-class reason
///         `DeployMarket.s.sol` documents: the deployer no longer holds `DEFAULT_ADMIN_ROLE` there).
///         The three phases, in order:
///           1. this script (deployer EOA, `--broadcast`)                          -> `.nameGifts` in the book
///           2. `GrantNameGiftsMarketRole.s.sol` (read-only; prints the timelock op) -> Admin Safe
///              schedules, waits `minDelay`, executes                               -> MARKET_ROLE granted
///           3. `VerifyNameGiftsRoles.s.sol` (read-only)                            -> `ROLES_VERIFIED`
///         Until phase 2 executes, `NameGifts` is fully deployed and governed but `HandleRegistry`
///         refuses its market-driven transfers of soulbound handles; TLD names (plain ERC-721
///         registrars) can be gifted immediately.
///
///         Environment (all optional, defaults shown): ARCNS_ADDRESS_BOOK, ARCNS_DRY_RUN — same as
///         `DeployMarket.s.sol`. Requires the market stack already deployed (reads `.market.NameLocks`);
///         run `DeployMarket.s.sol` first, or set `ARCNS_NAME_GIFTS_NO_NAME_LOCKS=1` to deploy without
///         the parity lock module wired (native-lock-only, matches `ArcNSMarket`'s own
///         `nameLocks == address(0)` convention for "not deployed yet").
///
///         Fork rehearsal against the LIVE book (no broadcast, no keys):
///           ARCNS_ADDRESS_BOOK=deployments/5042002.json forge script script/DeployNameGifts.s.sol --sig 'run()' \
///             --rpc-url $ARC_RPC_URL --sender 0xd91d1F6abB7243910B38Fe86CdCd0754a00cB152
///         Live (CEO only, run from the keystore host, never from this lane):
///           forge script script/DeployNameGifts.s.sol --sig 'run()' --rpc-url $ARC_RPC_URL --ledger --broadcast \
///             --with-gas-price 20gwei --priority-gas-price 1gwei --verify --verifier blockscout \
///             --verifier-url https://testnet.arcscan.app/api/
contract DeployNameGifts is NameGiftsScriptBase {
    string[] internal tldLabels = ["arc", "circle"];

    function run() external {
        string memory bookPath = _bookPath();
        string memory json = vm.readFile(bookPath);
        _logBook("ADDRESS_BOOK", bookPath);

        NameGiftsDeployLib.Params memory p = _params(json, bookPath);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        p.deployer = deployer;
        p.create2Deployer = Salts.CREATE2_FACTORY;
        console2.log("deployer", deployer, "chainid", block.chainid);

        NameGiftsDeployLib.Book memory predicted = NameGiftsDeployLib.predict(p);
        console2.log("PREDICTED NameGifts", address(predicted.nameGifts));
        bool fresh = address(predicted.nameGifts).code.length == 0;

        NameGiftsDeployLib.Book memory b = NameGiftsDeployLib.deployNameGiftsStack(p);
        vm.stopBroadcast();

        NameGiftsDeployLib.assertHandoff(b, p);
        console2.log("NAME_GIFTS_POST_DEPLOY_ASSERTIONS_OK");
        console2.log("DEPLOYED NameGifts", address(b.nameGifts));
        address[] memory missing = NameGiftsDeployLib.missingMarketRole(b, p);
        for (uint256 k = 0; k < missing.length; k++) {
            console2.log("MARKET_ROLE_PENDING collection", missing[k], "- run phase 2 (GrantNameGiftsMarketRole.s.sol)");
        }
        _writeJson(b, p, bookPath, json, fresh);
    }

    function _params(string memory json, string memory bookPath)
        internal
        view
        returns (NameGiftsDeployLib.Params memory p)
    {
        address timelock = vm.parseJsonAddress(json, ".TimelockController");
        address handleRegistry = vm.parseJsonAddress(json, ".HandleRegistry");
        _requireAddr(timelock, "TimelockController");
        _requireAddr(handleRegistry, "HandleRegistry");

        address nameLocks = address(0);
        if (!vm.envOr("ARCNS_NAME_GIFTS_NO_NAME_LOCKS", false)) {
            (string memory marketJson,) = _readMarketBook(json, bookPath);
            nameLocks = vm.parseJsonAddress(marketJson, ".market.NameLocks");
            _requireAddr(nameLocks, "market.NameLocks");
        }

        address[] memory collections = new address[](1 + tldLabels.length);
        bool[] memory needsMarketRole = new bool[](1 + tldLabels.length);
        collections[0] = handleRegistry;
        needsMarketRole[0] = true; // HandleRegistry exposes MARKET_ROLE (soulbound-bypass path) — phase 2
        for (uint256 k = 0; k < tldLabels.length; k++) {
            address registrar = vm.parseJsonAddress(json, string.concat(".tlds.", tldLabels[k], ".BaseRegistrar"));
            _requireAddr(registrar, string.concat("tlds.", tldLabels[k], ".BaseRegistrar"));
            collections[1 + k] = registrar;
            needsMarketRole[1 + k] = false; // verbatim ENS BaseRegistrar has no MARKET_ROLE concept
        }

        p = NameGiftsDeployLib.Params({
            deployer: address(0), // set from vm.readCallers() inside the broadcast window
            create2Deployer: address(0), // idem
            timelock: timelock,
            nameLocks: nameLocks,
            collections: collections,
            needsMarketRole: needsMarketRole
        });
    }

    /// @dev Live broadcast: key-scoped append of `.nameGifts` to the input book (only that top-level key
    ///      is touched — the M1/M2/`.market` keys and any sibling keys survive). Everything else: a
    ///      self-contained `deployments/<chainId>.nameGifts-dry-run.json`.
    ///
    ///      `.nameGifts` carries `deployBlock` (a LOWER bound on the creation block, the log-scan paging
    ///      floor) and `bytecodeHashes` — same convention `DeployMarket.s.sol._writeJson` uses.
    function _writeJson(
        NameGiftsDeployLib.Book memory b,
        NameGiftsDeployLib.Params memory p,
        string memory bookPath,
        string memory bookJson,
        bool fresh
    ) internal {
        uint256 deployBlock = block.number;
        if (!fresh) {
            if (vm.keyExistsJson(bookJson, ".nameGifts.deployBlock")) {
                deployBlock = vm.parseJsonUint(bookJson, ".nameGifts.deployBlock");
            } else {
                console2.log(
                    "NOTE resumed run: .nameGifts.deployBlock is this run's block; take the exact creation block from the first broadcast's receipts"
                );
            }
        }
        string memory hashes = "nameGifts.bytecodeHashes";
        string memory hashesJson = vm.serializeBytes32(hashes, "NameGifts", keccak256(address(b.nameGifts).code));

        string memory root = "nameGifts";
        vm.serializeAddress(root, "NameGifts", address(b.nameGifts));
        vm.serializeAddress(root, "nameLocks", p.nameLocks);
        vm.serializeUint(root, "deployBlock", deployBlock);
        string memory nameGiftsJson = vm.serializeString(root, "bytecodeHashes", hashesJson);

        if (_isLiveWrite()) {
            vm.writeJson(nameGiftsJson, bookPath, ".nameGifts");
            console2.log("NAME_GIFTS_DEPLOYMENTS_WRITTEN", bookPath);
            return;
        }
        string memory outer = "dry-run";
        vm.serializeUint(outer, "chainId", block.chainid);
        vm.serializeString(outer, "sourceBook", bookPath);
        vm.serializeAddress(outer, "deployer", p.deployer);
        string memory out = vm.serializeString(outer, "nameGifts", nameGiftsJson);
        vm.writeJson(out, _nameGiftsDryRunPath());
        console2.log("NAME_GIFTS_DRY_RUN_WRITTEN", _nameGiftsDryRunPath(), "(input book untouched)");
    }
}
