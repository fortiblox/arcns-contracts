// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

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

/// @title MarketDeployLib — WP-124: the M3 marketplace + M3b parity stack, deterministic + resumable
/// @notice Phase 1 of the three-phase market deploy (WP-7632, `docs/runbooks/market-deploy.md`):
///         deploys `ArcNSMarket` (C10) and the six M3b parity modules (`NameLocks`, `RecordDelegate`,
///         `TextRecords`, `AttestationRegistry`, `IntegratorRegistry`, `Vouchers`) at their CREATE2
///         addresses, allow-lists every collection it is told about on the market, hands
///         `DEFAULT_ADMIN_ROLE` to the timelock and asserts the deployer keeps no residual role — the
///         same shape and post-deploy assertion discipline as `ArcNSDeployLib` (WP-113 / INV-8).
///
///         What this library deliberately does NOT do (the WP-7632 root cause): grant `MARKET_ROLE` on
///         `HandleRegistry`. On the live chain `DEFAULT_ADMIN_ROLE` on every M1/M2 contract belongs to
///         the `TimelockController` (WP-113 handoff, verified by `VerifyRoles`), so the deployer EOA
///         cannot grant anything there; that grant is a governance action — Admin Safe →
///         `TimelockController.schedule` → `minDelay` → `execute` — whose payload phase 2
///         (`script/GrantMarketRole.s.sol`) prints and phase 3 (`script/VerifyMarketRoles.s.sol`)
///         verifies. `Params.needsMarketRole` therefore only records WHICH collections need that grant,
///         so `assertMarketRole` / `missingMarketRole` can report it; `deployMarketStack` never
///         attempts it.
///
///         Resumable: every contract is created with `Salts.forName(<Name>)`; a rerun with identical
///         `Params` predicts each CREATE2 address (`predict`) and reuses whatever already has code,
///         re-wires only while the deployer still holds `DEFAULT_ADMIN_ROLE` on the market (i.e. the
///         previous attempt died before `_handoff`), and is a pure assertion once the handoff is done.
///
/// @dev Used by `script/DeployMarket.s.sol` (broadcast) and by `test/market/MarketDeploy.t.sol`
///      (in-process, local-only, no network — this library takes explicit collection addresses rather
///      than reading `deployments/<chainId>.json` itself, so both callers exercise the identical wiring
///      logic without a live chain). `Params.create2Deployer` is the address forge derives CREATE2
///      addresses from: the Arachnid factory (`Salts.CREATE2_FACTORY`) inside `vm.startBroadcast` in a
///      script, the pranked deployer in an in-process test (no factory routing there).
library MarketDeployLib {
    struct Params {
        address deployer; // EOA running the script; temporary admin for the wiring calls in this run
        address create2Deployer; // address CREATE2 derives from (factory in scripts, pranked sender in tests)
        address timelock; // final DEFAULT_ADMIN_ROLE everywhere (OZ TimelockController from WP-113)
        address pauser; // Admin Safe (no delay) — PAUSER_ROLE on the market
        address treasury; // Treasury Safe — pull-credited market fees, escrowed voucher refunds' payer side is per-voucher
        address[] collections; // every allow-listed ERC-721 (HandleRegistry + every TldRegistrar)
        bool[] needsMarketRole; // true for collections that expose MARKET_ROLE (HandleRegistry) — granted by
        // governance in phase 2, never by this library; false for plain-transferable
        // collections (TLD registrars) where no such role exists
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
        require(p.deployer != address(0) && p.create2Deployer != address(0), "MarketDeployLib: zero deployer");
        require(p.collections.length == p.needsMarketRole.length, "MarketDeployLib: length mismatch");
    }

    /// @dev The CREATE2 address book for `p` — pure arithmetic over `Salts` + init-code hashes, so it can
    ///      be printed before any broadcast and re-derived on a rerun. Constructor args are part of the
    ///      init-code hash: a different `deployer`, config, treasury or pauser is a different address.
    function predict(Params memory p) internal pure returns (Book memory b) {
        b.nameLocks = NameLocks(
            _create2(
                p.create2Deployer,
                Salts.forName("NameLocks"),
                abi.encodePacked(type(NameLocks).creationCode, abi.encode(p.deployer, p.unlockTimelockSecs))
            )
        );
        b.recordDelegate = RecordDelegate(
            _create2(p.create2Deployer, Salts.forName("RecordDelegate"), type(RecordDelegate).creationCode)
        );
        b.textRecords =
            TextRecords(_create2(p.create2Deployer, Salts.forName("TextRecords"), type(TextRecords).creationCode));
        b.attestations = AttestationRegistry(
            _create2(
                p.create2Deployer,
                Salts.forName("AttestationRegistry"),
                abi.encodePacked(type(AttestationRegistry).creationCode, abi.encode(p.deployer))
            )
        );
        b.integrators = IntegratorRegistry(
            _create2(
                p.create2Deployer,
                Salts.forName("IntegratorRegistry"),
                abi.encodePacked(type(IntegratorRegistry).creationCode, abi.encode(p.deployer))
            )
        );
        b.vouchers =
            Vouchers(payable(_create2(p.create2Deployer, Salts.forName("Vouchers"), type(Vouchers).creationCode)));
        b.market = ArcNSMarket(
            payable(_create2(
                    p.create2Deployer,
                    Salts.forName("ArcNSMarket"),
                    abi.encodePacked(type(ArcNSMarket).creationCode, abi.encode(_marketInit(p, address(b.nameLocks))))
                ))
        );
    }

    /// @dev Deploy-or-reuse every contract at its predicted address, wire the market while the deployer
    ///      still holds `DEFAULT_ADMIN_ROLE` on it, then hand off to the timelock. Must be called with
    ///      `msg.sender == p.deployer` for every external call it makes (`vm.startBroadcast` in a script,
    ///      `vm.startPrank` in a test). Does NOT touch `MARKET_ROLE` on any collection (see the title
    ///      NatSpec); that is phase 2.
    function deployMarketStack(Params memory p) internal returns (Book memory b) {
        validateParams(p);
        Book memory expected = predict(p);

        if (address(expected.nameLocks).code.length == 0) {
            b.nameLocks = new NameLocks{salt: Salts.forName("NameLocks")}(p.deployer, p.unlockTimelockSecs);
            _same(address(b.nameLocks), address(expected.nameLocks), "NameLocks");
        }
        if (address(expected.recordDelegate).code.length == 0) {
            b.recordDelegate = new RecordDelegate{salt: Salts.forName("RecordDelegate")}();
            _same(address(b.recordDelegate), address(expected.recordDelegate), "RecordDelegate");
        }
        if (address(expected.textRecords).code.length == 0) {
            b.textRecords = new TextRecords{salt: Salts.forName("TextRecords")}();
            _same(address(b.textRecords), address(expected.textRecords), "TextRecords");
        }
        if (address(expected.attestations).code.length == 0) {
            b.attestations = new AttestationRegistry{salt: Salts.forName("AttestationRegistry")}(p.deployer);
            _same(address(b.attestations), address(expected.attestations), "AttestationRegistry");
        }
        if (address(expected.integrators).code.length == 0) {
            b.integrators = new IntegratorRegistry{salt: Salts.forName("IntegratorRegistry")}(p.deployer);
            _same(address(b.integrators), address(expected.integrators), "IntegratorRegistry");
        }
        if (address(expected.vouchers).code.length == 0) {
            b.vouchers = new Vouchers{salt: Salts.forName("Vouchers")}();
            _same(address(b.vouchers), address(expected.vouchers), "Vouchers");
        }
        if (address(expected.market).code.length == 0) {
            b.market = new ArcNSMarket{salt: Salts.forName("ArcNSMarket")}(_marketInit(p, address(expected.nameLocks)));
            _same(address(b.market), address(expected.market), "ArcNSMarket");
        }
        b = expected; // every address now has code, freshly created or reused

        // Wiring + handoff only while this run (or a crashed earlier one) still holds admin on the market.
        // After a completed handoff the deployer cannot (and must not) touch the market again; the
        // caller's `assertHandoff` then proves the earlier run left everything in place.
        if (b.market.hasRole(b.market.DEFAULT_ADMIN_ROLE(), p.deployer)) {
            for (uint256 i = 0; i < p.collections.length; i++) {
                if (!b.market.isCollectionAllowed(p.collections[i])) {
                    b.market.setCollectionAllowed(p.collections[i], true);
                }
            }
            _handoff(b, p);
        }
    }

    /// @dev Timelock becomes `DEFAULT_ADMIN_ROLE` on `ArcNSMarket` and `NameLocks`, `AttestationRegistry`
    ///      and `IntegratorRegistry` (the only four contracts here with an admin role at all —
    ///      `RecordDelegate`, `TextRecords` and `Vouchers` have no admin surface); the deployer's own
    ///      admin grant is revoked in the same call, matching `ArcNSDeployLib.handoff`'s
    ///      grant-then-revoke-self pattern (INV-8: deployer holds no role once this returns). Each step
    ///      is a no-op when already done, so a resumed run cannot fail here.
    function _handoff(Book memory b, Params memory p) private {
        _handoffOne(IAccessControl(address(b.market)), p);
        _handoffOne(IAccessControl(address(b.nameLocks)), p);
        _handoffOne(IAccessControl(address(b.attestations)), p);
        _handoffOne(IAccessControl(address(b.integrators)), p);
    }

    function _handoffOne(IAccessControl c, Params memory p) private {
        bytes32 admin = 0x00;
        if (!c.hasRole(admin, p.timelock)) c.grantRole(admin, p.timelock);
        if (c.hasRole(admin, p.deployer)) c.renounceRole(admin, p.deployer);
    }

    /// @dev Post-deploy assertions for phase 1 (INV-8 parity): the deployer holds no admin role on any of
    ///      the four admin-bearing contracts, the timelock holds it on all four, the market's pauser and
    ///      treasury are the governance addresses from `p`, it points at the deployed `NameLocks`, and
    ///      every collection is allow-listed. Deliberately silent on `MARKET_ROLE` — see `assertMarketRole`.
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
        require(b.market.hasRole(ArcNSConstants.PAUSER_ROLE, p.pauser), "market pauser");
        require(b.market.treasury() == p.treasury, "market treasury");
        require(b.market.nameLocks() == address(b.nameLocks), "market nameLocks");
        for (uint256 i = 0; i < p.collections.length; i++) {
            require(b.market.isCollectionAllowed(p.collections[i]), "collection not allow-listed");
        }
    }

    /// @dev Phase 3 assertion: every collection flagged `needsMarketRole` has granted `MARKET_ROLE` to the
    ///      market (the governance payload from phase 2 has executed). Reverts with the address of the
    ///      first collection still missing it.
    function assertMarketRole(Book memory b, Params memory p) internal view {
        address[] memory missing = missingMarketRole(b, p);
        if (missing.length != 0) {
            revert(
                string.concat(
                    "MARKET_ROLE not granted on ",
                    Strings.toChecksumHexString(missing[0]),
                    " to ArcNSMarket ",
                    Strings.toChecksumHexString(address(b.market))
                )
            );
        }
    }

    /// @dev The collections flagged `needsMarketRole` that have NOT granted `MARKET_ROLE` to the market.
    function missingMarketRole(Book memory b, Params memory p) internal view returns (address[] memory missing) {
        uint256 n;
        address[] memory tmp = new address[](p.collections.length);
        for (uint256 i = 0; i < p.collections.length; i++) {
            if (
                p.needsMarketRole[i]
                    && !IAccessControl(p.collections[i]).hasRole(ArcNSConstants.MARKET_ROLE, address(b.market))
            ) {
                tmp[n++] = p.collections[i];
            }
        }
        missing = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            missing[i] = tmp[i];
        }
    }

    function _marketInit(Params memory p, address nameLocks) private pure returns (ArcNSMarket.Init memory) {
        return ArcNSMarket.Init({
            admin: p.deployer, // handed to the timelock in `_handoff`
            pauser: p.pauser,
            treasury: p.treasury,
            nameLocks: nameLocks,
            config: p.config
        });
    }

    function _create2(address deployer, bytes32 salt, bytes memory initCode) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(initCode))))));
    }

    function _same(address got, address want, string memory name) private pure {
        require(got == want, string.concat("MarketDeployLib: CREATE2 address mismatch for ", name));
    }
}
