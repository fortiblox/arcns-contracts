// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {NameGifts} from "../../src/parity/NameGifts.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {Salts} from "./Salts.sol";

/// @title NameGiftsDeployLib — M3b: the `NameGifts` escrow, deterministic + resumable
/// @notice Phase 1 of the same three-phase deploy `MarketDeployLib` uses for `ArcNSMarket`
///         (`docs/runbooks/market-deploy.md`, mirrored here for `NameGifts`): deploys `NameGifts` at
///         its CREATE2 address, allow-lists every collection it is told about, hands
///         `DEFAULT_ADMIN_ROLE` to the timelock and asserts the deployer keeps no residual role.
///
///         Reuses the ALREADY-DEPLOYED `NameLocks` parity module (WP-125, `.market.NameLocks` in the
///         address book) rather than deploying a second one — one `INameLocks` instance serves both
///         `ArcNSMarket` and `NameGifts` (T-MKT-1 class: no third lock reimplementation).
///
///         What this library deliberately does NOT do (mirrors `MarketDeployLib`'s WP-7632 fix): grant
///         `MARKET_ROLE` on `HandleRegistry`. The deployer EOA does not hold `DEFAULT_ADMIN_ROLE` there
///         (it belongs to the `TimelockController`, WP-113 handoff) — that grant is a governance action,
///         Admin Safe -> `TimelockController.schedule` -> `minDelay` -> `execute`, whose payload
///         `script/GrantNameGiftsMarketRole.s.sol` prints and `script/VerifyNameGiftsRoles.s.sol`
///         verifies. `Params.needsMarketRole` only records WHICH collections need that grant so
///         `assertMarketRole` / `missingMarketRole` can report it.
library NameGiftsDeployLib {
    struct Params {
        address deployer; // EOA running the script; temporary admin for the wiring calls in this run
        address create2Deployer; // address CREATE2 derives from
        address timelock; // final DEFAULT_ADMIN_ROLE (OZ TimelockController from WP-113)
        address nameLocks; // the already-deployed WP-125 parity module (`.market.NameLocks`); may be
        // `address(0)` if the market stack is not deployed yet — NameGifts works
        // without it (native-lock-only), same convention as `ArcNSMarket.nameLocks`
        address[] collections; // every allow-listed ERC-721 (HandleRegistry + every TldRegistrar)
        bool[] needsMarketRole; // true for collections that expose MARKET_ROLE (HandleRegistry)
    }

    struct Book {
        NameGifts nameGifts;
    }

    function validateParams(Params memory p) internal pure {
        require(p.timelock != address(0), "NameGiftsDeployLib: zero timelock");
        require(p.deployer != address(0) && p.create2Deployer != address(0), "NameGiftsDeployLib: zero deployer");
        require(p.collections.length == p.needsMarketRole.length, "NameGiftsDeployLib: length mismatch");
    }

    /// @dev The CREATE2 address — pure arithmetic over `Salts` + the init-code hash, so it can be printed
    ///      before any broadcast and re-derived on a rerun. A different `deployer` or `nameLocks` is a
    ///      different address.
    function predict(Params memory p) internal pure returns (Book memory b) {
        b.nameGifts = NameGifts(
            payable(_create2(
                    p.create2Deployer,
                    Salts.forName("NameGifts"),
                    abi.encodePacked(type(NameGifts).creationCode, abi.encode(_init(p)))
                ))
        );
    }

    /// @dev Deploy-or-reuse at the predicted address, allow-list every collection while the deployer
    ///      still holds `DEFAULT_ADMIN_ROLE`, then hand off to the timelock. Must be called with
    ///      `msg.sender == p.deployer` for every external call (`vm.startBroadcast` in a script,
    ///      `vm.startPrank` in a test). Does NOT touch `MARKET_ROLE` on any collection — that is phase 2.
    function deployNameGiftsStack(Params memory p) internal returns (Book memory b) {
        validateParams(p);
        Book memory expected = predict(p);

        if (address(expected.nameGifts).code.length == 0) {
            b.nameGifts = new NameGifts{salt: Salts.forName("NameGifts")}(_init(p));
            _same(address(b.nameGifts), address(expected.nameGifts), "NameGifts");
        }
        b = expected;

        if (b.nameGifts.hasRole(b.nameGifts.DEFAULT_ADMIN_ROLE(), p.deployer)) {
            for (uint256 i = 0; i < p.collections.length; i++) {
                if (!b.nameGifts.isCollectionAllowed(p.collections[i])) {
                    b.nameGifts.setCollectionAllowed(p.collections[i], true);
                }
            }
            _handoff(b, p);
        }
    }

    /// @dev Timelock becomes `DEFAULT_ADMIN_ROLE`; the deployer's own admin grant is revoked in the same
    ///      call (INV-8: deployer holds no role once this returns). No-op when already done, so a
    ///      resumed run cannot fail here.
    function _handoff(Book memory b, Params memory p) private {
        bytes32 admin = 0x00;
        IAccessControl c = IAccessControl(address(b.nameGifts));
        if (!c.hasRole(admin, p.timelock)) c.grantRole(admin, p.timelock);
        if (c.hasRole(admin, p.deployer)) c.renounceRole(admin, p.deployer);
    }

    /// @dev Post-deploy assertions (INV-8 parity): the deployer holds no admin role, the timelock holds
    ///      it, and every collection is allow-listed. Deliberately silent on `MARKET_ROLE` — see
    ///      `assertMarketRole`.
    function assertHandoff(Book memory b, Params memory p) internal view {
        bytes32 adminRole = b.nameGifts.DEFAULT_ADMIN_ROLE();
        require(
            !b.nameGifts.hasRole(adminRole, p.deployer) && b.nameGifts.hasRole(adminRole, p.timelock), "nameGifts admin"
        );
        for (uint256 i = 0; i < p.collections.length; i++) {
            require(b.nameGifts.isCollectionAllowed(p.collections[i]), "collection not allow-listed");
        }
    }

    /// @dev Phase 3 assertion: every collection flagged `needsMarketRole` has granted `MARKET_ROLE` to
    ///      `NameGifts` (the phase-2 governance op has executed). Reverts with the first missing collection.
    function assertMarketRole(Book memory b, Params memory p) internal view {
        address[] memory missing = missingMarketRole(b, p);
        if (missing.length != 0) {
            revert(
                string.concat(
                    "MARKET_ROLE not granted on ",
                    Strings.toChecksumHexString(missing[0]),
                    " to NameGifts ",
                    Strings.toChecksumHexString(address(b.nameGifts))
                )
            );
        }
    }

    /// @dev The collections flagged `needsMarketRole` that have NOT granted `MARKET_ROLE` to `NameGifts`.
    function missingMarketRole(Book memory b, Params memory p) internal view returns (address[] memory missing) {
        uint256 n;
        address[] memory tmp = new address[](p.collections.length);
        for (uint256 i = 0; i < p.collections.length; i++) {
            if (
                p.needsMarketRole[i]
                    && !IAccessControl(p.collections[i]).hasRole(ArcNSConstants.MARKET_ROLE, address(b.nameGifts))
            ) {
                tmp[n++] = p.collections[i];
            }
        }
        missing = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            missing[i] = tmp[i];
        }
    }

    function _init(Params memory p) private pure returns (NameGifts.Init memory) {
        return NameGifts.Init({admin: p.deployer, nameLocks: p.nameLocks}); // admin handed to the timelock in `_handoff`
    }

    function _create2(address deployer, bytes32 salt, bytes memory initCode) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(initCode))))));
    }

    function _same(address got, address want, string memory name) private pure {
        require(got == want, string.concat("NameGiftsDeployLib: CREATE2 address mismatch for ", name));
    }
}
