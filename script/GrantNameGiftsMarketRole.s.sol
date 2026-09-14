// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ArcNSConstants} from "../src/lib/ArcNSConstants.sol";
import {MarketGrantLib} from "./lib/MarketGrantLib.sol";
import {NameGiftsScriptBase} from "./lib/NameGiftsScriptBase.sol";

interface ISafeView {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
}

/// @title GrantNameGiftsMarketRole — M3b phase 2: `HandleRegistry.grantRole(MARKET_ROLE, nameGifts)`
/// @notice Read-only. Never signs, never broadcasts, never needs a key. Sibling of
///         `GrantMarketRole.s.sol` — reuses `MarketGrantLib.build` UNCHANGED (its `market` parameter is
///         just the address being granted `MARKET_ROLE`; `MARKET_ROLE` is a shared role id that may be
///         held by more than one address, so granting it to `NameGifts` here is independent of
///         `ArcNSMarket`'s own grant). Given the address book (M1/M2 governance + the `.nameGifts`
///         object phase 1 wrote), prints and writes to `deployments/<chainId>.nameGifts-grant.json`
///         everything the CEO's Safe shell script needs to run the timelocked grant from the Admin
///         Safe — the exact same two-step path `GrantMarketRole.s.sol` uses:
///
///           AdminSafe.execTransaction(timelock, 0, schedule(...), Call, …, preValidatedSig)   <- t0
///           wait minDelay
///           AdminSafe.execTransaction(timelock, 0, execute(...),  Call, …, preValidatedSig)   <- t0 + minDelay
///
///           ARCNS_ADDRESS_BOOK=deployments/5042002.json forge script script/GrantNameGiftsMarketRole.s.sol --rpc-url $ARC_RPC_URL
contract GrantNameGiftsMarketRole is NameGiftsScriptBase {
    struct Ctx {
        string bookPath;
        string nameGiftsPath;
        address handleRegistry;
        address timelock;
        address safe;
        address safeOwner;
        address nameGifts;
        uint256 delay;
        bool live;
    }

    function run() external {
        Ctx memory c = _load();
        MarketGrantLib.Payload memory p = MarketGrantLib.build(c.handleRegistry, c.nameGifts, c.delay);
        if (c.live) {
            bytes32 onchainId =
                TimelockController(payable(c.timelock)).hashOperation(p.target, p.value, p.data, p.predecessor, p.salt);
            require(onchainId == p.operationId, "hashOperation mismatch");
        }

        console2.log("GRANT_TARGET HandleRegistry", c.handleRegistry);
        console2.log("GRANT_NAME_GIFTS", c.nameGifts);
        console2.log("GRANT_TIMELOCK", c.timelock, "delay", c.delay);
        console2.log("GRANT_SAFE", c.safe, "owner", c.safeOwner);
        console2.log("GRANT_OPERATION_ID", vm.toString(p.operationId));
        console2.log("GRANT_INNER_CALLDATA", vm.toString(p.data));
        console2.log("GRANT_SALT", vm.toString(p.salt));
        console2.log("GRANT_SCHEDULE_CALLDATA", vm.toString(p.scheduleCalldata));
        console2.log("GRANT_EXECUTE_CALLDATA", vm.toString(p.executeCalldata));

        vm.writeJson(_serialize(p, c), _nameGiftsGrantPath());
        console2.log("NAME_GIFTS_GRANT_WRITTEN", _nameGiftsGrantPath());
    }

    function _load() internal returns (Ctx memory c) {
        c.bookPath = _bookPath();
        string memory book = vm.readFile(c.bookPath);
        string memory nameGiftsJson;
        (nameGiftsJson, c.nameGiftsPath) = _readNameGiftsBook(book, c.bookPath);
        _logBook("ADDRESS_BOOK", c.bookPath);
        _logBook("NAME_GIFTS_BOOK", c.nameGiftsPath);

        c.handleRegistry = vm.parseJsonAddress(book, ".HandleRegistry");
        c.timelock = vm.parseJsonAddress(book, ".TimelockController");
        c.safe = vm.parseJsonAddress(book, ".AdminSafe");
        c.safeOwner = vm.parseJsonAddress(book, ".admin");
        c.nameGifts = vm.parseJsonAddress(nameGiftsJson, ".nameGifts.NameGifts");
        _requireAddr(c.handleRegistry, "HandleRegistry");
        _requireAddr(c.timelock, "TimelockController");
        _requireAddr(c.safe, "AdminSafe");
        _requireAddr(c.safeOwner, "admin");
        _requireAddr(c.nameGifts, "nameGifts.NameGifts");

        c.delay = vm.parseJsonUint(book, ".timelockDelay");
        c.live = c.timelock.code.length != 0;
        if (c.live) {
            uint256 onchain = TimelockController(payable(c.timelock)).getMinDelay();
            require(onchain == c.delay, "timelock minDelay differs from the book's .timelockDelay");
        }
    }

    function _serialize(MarketGrantLib.Payload memory p, Ctx memory c) internal returns (string memory) {
        bytes memory sig = MarketGrantLib.safePreValidatedSignature(c.safeOwner);
        string memory sched = _serializeSafeTx("nameGiftsSafeSchedule", c.timelock, p.scheduleCalldata, sig);
        string memory exec = _serializeSafeTx("nameGiftsSafeExecute", c.timelock, p.executeCalldata, sig);
        string memory state = _state(p, c);

        string memory root = "grant";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "sourceBook", c.bookPath);
        vm.serializeString(root, "nameGiftsBook", c.nameGiftsPath);
        vm.serializeAddress(root, "HandleRegistry", c.handleRegistry);
        vm.serializeAddress(root, "NameGifts", c.nameGifts);
        vm.serializeAddress(root, "TimelockController", c.timelock);
        vm.serializeAddress(root, "AdminSafe", c.safe);
        vm.serializeAddress(root, "safeOwner", c.safeOwner);
        vm.serializeBytes32(root, "role", ArcNSConstants.MARKET_ROLE);
        vm.serializeAddress(root, "target", p.target);
        vm.serializeUint(root, "value", p.value);
        vm.serializeBytes(root, "data", p.data);
        vm.serializeBytes32(root, "predecessor", p.predecessor);
        vm.serializeBytes32(root, "salt", p.salt);
        vm.serializeUint(root, "delay", p.delay);
        vm.serializeBytes32(root, "operationId", p.operationId);
        vm.serializeBytes(root, "scheduleCalldata", p.scheduleCalldata);
        vm.serializeBytes(root, "executeCalldata", p.executeCalldata);
        vm.serializeString(root, "safeSchedule", sched);
        vm.serializeString(root, "safeExecute", exec);
        return vm.serializeString(root, "state", state);
    }

    function _state(MarketGrantLib.Payload memory p, Ctx memory c) internal returns (string memory) {
        string memory key = "state";
        vm.serializeBool(key, "rpc", c.live);
        if (!c.live) {
            vm.serializeString(key, "operation", "no-rpc");
            return vm.serializeBool(key, "marketRoleGranted", false);
        }
        TimelockController tl = TimelockController(payable(c.timelock));
        string memory name = _stateName(tl.getOperationState(p.operationId));
        vm.serializeString(key, "operation", name);
        vm.serializeUint(key, "operationReadyAt", tl.getTimestamp(p.operationId));
        vm.serializeUint(key, "minDelay", tl.getMinDelay());
        vm.serializeBool(key, "safeIsProposer", tl.hasRole(tl.PROPOSER_ROLE(), c.safe));
        vm.serializeBool(key, "safeIsExecutor", tl.hasRole(tl.EXECUTOR_ROLE(), c.safe));
        vm.serializeBool(key, "timelockIsRegistryAdmin", IAccessControl(c.handleRegistry).hasRole(0x00, c.timelock));
        vm.serializeBool(key, "nameGiftsHasCode", c.nameGifts.code.length != 0);
        if (c.safe.code.length != 0) {
            vm.serializeAddress(key, "safeOwners", ISafeView(c.safe).getOwners());
            vm.serializeUint(key, "safeThreshold", ISafeView(c.safe).getThreshold());
            vm.serializeUint(key, "safeNonce", ISafeView(c.safe).nonce());
        }
        bool granted = IAccessControl(c.handleRegistry).hasRole(ArcNSConstants.MARKET_ROLE, c.nameGifts);
        console2.log("GRANT_STATE operation", name, "marketRoleGranted", granted);
        return vm.serializeBool(key, "marketRoleGranted", granted);
    }
}
