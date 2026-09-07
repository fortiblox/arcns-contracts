// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ArcNSMarket} from "../../src/market/ArcNSMarket.sol";
import {IArcNSMarket} from "../../src/interfaces/IArcNSMarket.sol";
import {NameLocks} from "../../src/parity/NameLocks.sol";
import {RecordDelegate} from "../../src/parity/RecordDelegate.sol";
import {TextRecords} from "../../src/parity/TextRecords.sol";
import {AttestationRegistry} from "../../src/parity/AttestationRegistry.sol";
import {IntegratorRegistry} from "../../src/parity/IntegratorRegistry.sol";
import {Vouchers} from "../../src/parity/Vouchers.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {Salts} from "./Salts.sol";

/// @title MarketDeployLib — WP-124: the M3 marketplace + M3b parity stack, deterministic
/// @notice Deploys `ArcNSMarket` (C10) and the six M3b parity modules (`NameLocks`, `RecordDelegate`,
///         `TextRecords`, `AttestationRegistry`, `IntegratorRegistry`, `Vouchers`), wires
///         `MARKET_ROLE` on every collection this deploy is told about, allow-lists those collections
///         on the market, and asserts the deployer keeps no residual role once `handoff` returns —
///         same shape and same post-deploy assertion discipline as `ArcNSDeployLib` (WP-113/INV-8).
///
/// @dev Used by `script/DeployMarket.s.sol` (broadcast) and by `test/market/MarketDeploy.t.sol`
///      (in-process, local-only, no network — this library takes explicit collection addresses rather
///      than reading `deployments/<chainId>.json` itself, so both callers can exercise the identical
///      wiring logic without a live chain). This lane does not own `contracts/src/handle` or
///      `contracts/src/tld`; `collections` is therefore supplied by the caller (read from the M1/M2
///      deploy artifact in the real script, or a local mock/registry in tests) rather than derived
///      here.
library MarketDeployLib {
    struct Params {
        address deployer; // EOA running the script; temporary admin for the wiring calls in this run
        address timelock; // final DEFAULT_ADMIN_ROLE everywhere (OZ TimelockController from WP-113)
        address pauser; // Admin Safe (no delay) — PAUSER_ROLE on the market
        address treasury; // Treasury Safe — pull-credited market fees, escrowed voucher refunds' payer side is per-voucher
        address[] collections; // every allow-listed ERC-721 (HandleRegistry + every TldRegistrar)
        bool[] grantMarketRole; // true for collections that expose MARKET_ROLE (HandleRegistry); false
        // for plain-transferable collections (TLD registrars) where no such role exists
        IArcNSMarket.MarketConfig config;
        uint64 unlockTimelockSecs; // NameLocks config (floored at 7 days on read, SR-14 parity)
    }

    struct Book {
        ArcNSMarket market;
        NameLocks nameLocks;
        RecordDelegate recordDelegate;
        TextRecords textRecords;
        AttestationRegistry attestations;
        IntegratorRegistry integrators;
        Vouchers vouchers;
    }

    /// @dev Split out from `deployMarketStack` so a caller that only needs the early revert paths (a
    ///      test harness giving `vm.expectRevert` a real call-depth boundary, see
    ///      `test/market/MarketDeploy.t.sol`'s `MarketDeployHarness`) does not have to pull in the six
    ///      `new X()` contract creations' bytecode too — that inlining alone put a bare pass-through
    ///      harness over the EIP-170 24,576-byte runtime limit (45,128 bytes measured).
    function validateParams(Params memory p) internal pure {
        require(
            p.timelock != address(0) && p.pauser != address(0) && p.treasury != address(0), "MarketDeployLib: zero addr"
        );
        require(p.collections.length == p.grantMarketRole.length, "MarketDeployLib: length mismatch");
    }

    /// @dev Deployer must be `p.deployer` (the caller holds `DEFAULT_ADMIN_ROLE` on every collection in
    ///      `p.collections` where `grantMarketRole[i]` is true, so it can grant `MARKET_ROLE` there —
    ///      the real script runs this from the Admin Safe / a role the timelock has delegated for the
    ///      wiring window, exactly like `ArcNSDeployLib.handoff`'s pattern of "deployer keeps admin only
    ///      for the duration of this script").
    function deployMarketStack(Params memory p) internal returns (Book memory b) {
        validateParams(p);

        b.nameLocks = new NameLocks{salt: Salts.forName("NameLocks")}(p.deployer, p.unlockTimelockSecs);
        b.recordDelegate = new RecordDelegate{salt: Salts.forName("RecordDelegate")}();
        b.textRecords = new TextRecords{salt: Salts.forName("TextRecords")}();
        b.attestations = new AttestationRegistry{salt: Salts.forName("AttestationRegistry")}(p.deployer);
        b.integrators = new IntegratorRegistry{salt: Salts.forName("IntegratorRegistry")}(p.deployer);
        b.vouchers = new Vouchers{salt: Salts.forName("Vouchers")}();

        b.market = new ArcNSMarket{salt: Salts.forName("ArcNSMarket")}(
            ArcNSMarket.Init({
                admin: p.deployer, // handed to the timelock in `handoff` below
                pauser: p.pauser,
                treasury: p.treasury,
                nameLocks: address(b.nameLocks),
                config: p.config
            })
        );

        for (uint256 i = 0; i < p.collections.length; i++) {
            b.market.setCollectionAllowed(p.collections[i], true);
            if (p.grantMarketRole[i]) {
                IAccessControl(p.collections[i]).grantRole(ArcNSConstants.MARKET_ROLE, address(b.market));
            }
        }

        _handoff(b, p);
    }

    /// @dev Timelock becomes `DEFAULT_ADMIN_ROLE` on `ArcNSMarket` and `NameLocks`, `AttestationRegistry`
    ///      and `IntegratorRegistry` (the only four contracts here with an admin role at all —
    ///      `RecordDelegate`, `TextRecords` and `Vouchers` have no admin surface); the deployer's own
    ///      admin grant is revoked in the same call, matching `ArcNSDeployLib.handoff`'s
    ///      grant-then-revoke-self pattern (INV-8: deployer holds no role once this returns).
    function _handoff(Book memory b, Params memory p) internal {
        b.market.grantRole(b.market.DEFAULT_ADMIN_ROLE(), p.timelock);
        b.market.renounceRole(b.market.DEFAULT_ADMIN_ROLE(), p.deployer);

        b.nameLocks.grantRole(b.nameLocks.DEFAULT_ADMIN_ROLE(), p.timelock);
        b.nameLocks.renounceRole(b.nameLocks.DEFAULT_ADMIN_ROLE(), p.deployer);

        b.attestations.grantRole(b.attestations.DEFAULT_ADMIN_ROLE(), p.timelock);
        b.attestations.renounceRole(b.attestations.DEFAULT_ADMIN_ROLE(), p.deployer);

        b.integrators.grantRole(b.integrators.DEFAULT_ADMIN_ROLE(), p.timelock);
        b.integrators.renounceRole(b.integrators.DEFAULT_ADMIN_ROLE(), p.deployer);
    }

    /// @dev Post-deploy assertions (INV-8 parity): the deployer holds no admin role on any of the four
    ///      admin-bearing contracts, and the timelock holds it on all four. Callable by anyone
    ///      (`view`), used by both the script and the local test.
    function assertHandoff(Book memory b, Params memory p) internal view {
        bytes32 adminRole = b.market.DEFAULT_ADMIN_ROLE();
        require(!b.market.hasRole(adminRole, p.deployer) && b.market.hasRole(adminRole, p.timelock), "market admin");
        require(
            !b.nameLocks.hasRole(adminRole, p.deployer) && b.nameLocks.hasRole(adminRole, p.timelock), "nameLocks admin"
        );
        require(
            !b.attestations.hasRole(adminRole, p.deployer) && b.attestations.hasRole(adminRole, p.timelock),
            "attestations admin"
        );
        require(
            !b.integrators.hasRole(adminRole, p.deployer) && b.integrators.hasRole(adminRole, p.timelock),
            "integrators admin"
        );
        for (uint256 i = 0; i < p.collections.length; i++) {
            require(b.market.isCollectionAllowed(p.collections[i]), "collection not allow-listed");
            if (p.grantMarketRole[i]) {
                require(
                    IAccessControl(p.collections[i]).hasRole(ArcNSConstants.MARKET_ROLE, address(b.market)),
                    "MARKET_ROLE not granted"
                );
            }
        }
    }
}
