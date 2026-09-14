// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {TldStackFixture} from "./mocks/TldStackFixture.sol";
import {MockFortiToken} from "./mocks/MockFortiToken.sol";
import {MockVeForti} from "./mocks/MockVeForti.sol";
import {TldRegistrar} from "../../src/tld/TldRegistrar.sol";
import {TldRegistrarControllerV2} from "../../src/tld/TldRegistrarControllerV2.sol";
import {TldTokenPaymentController} from "../../src/tld/TldTokenPaymentController.sol";
import {ITldRegistrarController} from "../../src/interfaces/ITldRegistrarController.sol";
import {ITldTokenPaymentController} from "../../src/interfaces/ITldTokenPaymentController.sol";
import {IIntegratorRegistry} from "../../src/interfaces/IIntegratorRegistry.sol";
import {IntegratorRegistry} from "../../src/parity/IntegratorRegistry.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {HandleNormalize} from "../../src/lib/HandleNormalize.sol";

/// @notice Unit tests for `TldTokenPaymentController` (issue #192, FORTI-Arc groundwork).
///
/// @dev Fixture shape: ONE `.arc` `TldRegistrar`, authorized for BOTH a native
///      `TldRegistrarControllerV2` (the live, unmodified controller) AND this new
///      `TldTokenPaymentController`, added as a second controller via `TldRegistrar.addController`
///      strictly AFTER the native controller is already wired, sealed and registering names —
///      mirroring the "additive sibling, deployed alongside an already-live controller" model the
///      spec calls for. Every test that touches the native controller exists to show its behaviour
///      (treasury payout in native value, `oracle.recordSale` gating, genesis/pause state) is
///      byte-for-byte unaffected by the token controller's presence.
contract TldTokenPaymentControllerTest is TldStackFixture {
    uint16 internal constant CAP_BPS = 4000; // IntegratorRegistry.CAP_BPS
    uint256 internal constant RATE_WAD = 1e18; // 1 FORTI-wei == 1 native-wei of price, for test simplicity

    IntegratorRegistry internal integratorRegistry;
    MockFortiToken internal forti;
    MockVeForti internal veForti;

    TldRegistrar internal reg;
    TldRegistrarControllerV2 internal nativeCtl;
    TldTokenPaymentController internal tokenCtl;
    bytes32 internal node;

    address internal integrator = makeAddr("integrator");
    address internal buyback = makeAddr("buyback");

    function setUp() public {
        vm.chainId(ArcNSConstants.ARC_TESTNET_CHAIN_ID);
        _deployShared();
        integratorRegistry = new IntegratorRegistry(admin);
        forti = new MockFortiToken();
        veForti = new MockVeForti();

        // ---- the native controller, wired and sealed exactly like TldStackFixture._addTld/_seal ----
        node = HandleNormalize.tldNode("arc");
        reg = new TldRegistrar(registry, node, "arc", address(metadata), address(this));
        nativeCtl = new TldRegistrarControllerV2(
            TldRegistrarControllerV2.Init({
                admin: admin,
                genesisAdmin: genesis,
                pauser: pauser,
                registrar: address(reg),
                ens: address(registry),
                oracle: address(oracle),
                resolver: address(resolver),
                reverseRegistrar: address(reverse),
                directory: address(directory),
                treasury: treasury,
                integratorRegistry: address(integratorRegistry),
                minCommitmentAge: MIN_AGE,
                maxCommitmentAge: MAX_AGE,
                tld: "arc"
            })
        );
        root.setSubnodeOwner(keccak256("arc"), address(reg));
        reg.addController(address(nativeCtl));
        reg.transferOwnership(admin);
        reverse.setController(address(nativeCtl), true);

        vm.startPrank(admin);
        directory.add(node, "arc", address(reg), address(nativeCtl), node);
        oracle.initNamespace(node, address(nativeCtl), address(0), uint64(block.timestamp), _tldTiers(), _zeroTiers());
        vm.stopPrank();

        vm.prank(genesis);
        nativeCtl.sealGenesis(bytes32(0));

        // ---- the token controller, deployed and authorized ADDITIVELY afterwards ----
        tokenCtl = new TldTokenPaymentController(
            TldTokenPaymentController.Init({
                admin: admin,
                pauser: pauser,
                registrar: address(reg),
                ens: address(registry),
                oracle: address(oracle),
                resolver: address(resolver),
                reverseRegistrar: address(reverse),
                directory: address(directory),
                treasury: treasury,
                integratorRegistry: address(integratorRegistry),
                paymentToken: address(forti),
                minCommitmentAge: MIN_AGE,
                maxCommitmentAge: MAX_AGE,
                tld: "arc"
            })
        );
        vm.startPrank(admin);
        reg.addController(address(tokenCtl)); // additive: nativeCtl's own authorization is untouched
        oracle.setPaymentToken(address(forti), true, RATE_WAD);
        integratorRegistry.setIntegrator(integrator, true);
        vm.stopPrank();
    }

    // =============================================================================================
    // Test helpers
    // =============================================================================================

    function _commitAndWaitToken(ITldRegistrarController.Registration memory r, address who)
        internal
        returns (bytes32 commitment)
    {
        commitment = tokenCtl.makeCommitment(r);
        vm.prank(who);
        tokenCtl.commit(commitment);
        vm.warp(block.timestamp + MIN_AGE);
    }

    function _fundAndApprove(address who, uint256 amount) internal {
        forti.mint(who, amount);
        vm.prank(who);
        forti.approve(address(tokenCtl), amount);
    }

    /// @dev Commit, wait, fund `who` with the (undiscounted) quoted price as a safe upper bound, then
    ///      register at that `maxPrice`. Returns the amount actually pulled (post-discount).
    function _registerToken(ITldRegistrarController.Registration memory r, address who)
        internal
        returns (uint256 charged)
    {
        _commitAndWaitToken(r, who);
        (uint256 basePrice, bool supported) = tokenCtl.quote(r.label);
        assertTrue(supported, "payment token must be configured");
        _fundAndApprove(who, basePrice);
        uint256 before = forti.balanceOf(who);
        vm.prank(who);
        tokenCtl.register(r, basePrice);
        charged = before - forti.balanceOf(who);
    }

    function _registerTokenWithIntegrator(
        ITldRegistrarController.Registration memory r,
        address who,
        address integrator_
    ) internal returns (uint256 charged) {
        _commitAndWaitToken(r, who);
        (uint256 basePrice,) = tokenCtl.quote(r.label);
        _fundAndApprove(who, basePrice);
        uint256 before = forti.balanceOf(who);
        vm.prank(who);
        tokenCtl.registerWithIntegrator(r, basePrice, integrator_);
        charged = before - forti.balanceOf(who);
    }

    // =============================================================================================
    // Base discount (Arc Token Constitution v1.0 §6: "~10% base discount") — always applies
    // =============================================================================================

    function test_base_discount_always_applies_when_veForti_unset() public {
        assertEq(tokenCtl.veForti(), address(0), "veFORTI bonus tier disabled by default");
        ITldRegistrarController.Registration memory r =
            _registration("basedisc", alice, keccak256("s"), address(0), false);
        (uint256 basePrice,) = tokenCtl.quote("basedisc");
        uint256 expectedCharge = basePrice - basePrice * tokenCtl.BASE_DISCOUNT_BPS() / 10_000;
        uint256 charged = _registerToken(r, alice);

        assertEq(tokenCtl.BASE_DISCOUNT_BPS(), 1000, "10% base, per the ratified constitution");
        assertEq(charged, expectedCharge, "the 10% base discount always applies, veFORTI or not");
        assertEq(forti.balanceOf(treasury), expectedCharge, "100% of the discounted price to treasury, no integrator");
        assertEq(tokenCtl.paidAmount(_labelhash("basedisc")), expectedCharge);
        assertEq(reg.ownerOf(uint256(_labelhash("basedisc"))), alice);
    }

    /// @dev `veForti` pointed at a real contract and the caller HOLDING power, but `veFortiBonusBps ==
    ///      0` (the default): only the base 10% applies, no bonus on top.
    function test_base_discount_only_when_veForti_set_but_bonus_zero() public {
        vm.prank(admin);
        tokenCtl.setVeForti(address(veForti));
        veForti.setPower(alice, 1000);

        ITldRegistrarController.Registration memory r =
            _registration("basedisc2", alice, keccak256("s"), address(0), false);
        (uint256 basePrice,) = tokenCtl.quote("basedisc2");
        uint256 expectedCharge = basePrice - basePrice * 1000 / 10_000;
        uint256 charged = _registerToken(r, alice);
        assertEq(charged, expectedCharge, "base only - no bonus configured");
    }

    /// @dev `veForti` set and a bonus configured, but the caller holds zero voting power: base only.
    function test_base_discount_only_for_caller_without_voting_power() public {
        vm.startPrank(admin);
        tokenCtl.setVeForti(address(veForti));
        tokenCtl.setVeFortiBonusBps(2000);
        vm.stopPrank();
        // alice never staked (power defaults to 0)

        ITldRegistrarController.Registration memory r =
            _registration("nopower", alice, keccak256("s"), address(0), false);
        (uint256 basePrice,) = tokenCtl.quote("nopower");
        uint256 expectedCharge = basePrice - basePrice * 1000 / 10_000;
        uint256 charged = _registerToken(r, alice);
        assertEq(charged, expectedCharge, "zero voting power => base only, despite a configured bonus rate");
    }

    // =============================================================================================
    // veFORTI bonus tier (constitution §6: "deeper veFORTI-locker bonus (flash-proof)") — various levels
    // =============================================================================================

    function testFuzz_veForti_bonus_levels_applied_on_top_of_base(uint16 bonusBps) public {
        uint16 maxBonus = tokenCtl.MAX_DISCOUNT_BPS() - tokenCtl.BASE_DISCOUNT_BPS();
        bonusBps = uint16(bound(uint256(bonusBps), 0, maxBonus));
        vm.startPrank(admin);
        tokenCtl.setVeForti(address(veForti));
        tokenCtl.setVeFortiBonusBps(bonusBps);
        vm.stopPrank();
        veForti.setPower(alice, 1);

        ITldRegistrarController.Registration memory r = _registration(
            string.concat("bonus", vm.toString(uint256(bonusBps))), alice, keccak256("s"), address(0), false
        );
        (uint256 basePrice,) = tokenCtl.quote(r.label);
        uint256 totalBps = uint256(tokenCtl.BASE_DISCOUNT_BPS()) + bonusBps;
        uint256 expectedCharge = basePrice - (basePrice * totalBps / 10_000);

        uint256 charged = _registerToken(r, alice);
        assertEq(charged, expectedCharge, "base + bonus applied exactly at this level");
        assertEq(forti.balanceOf(treasury), expectedCharge, "treasury receives the discounted amount");
    }

    /// @dev Total discount at each level: 10% (no bonus), 25% (1500 bps bonus), 50% (4000 bps bonus,
    ///      the maximum — `BASE_DISCOUNT_BPS + 4000 == MAX_DISCOUNT_BPS` exactly).
    function test_veForti_bonus_specific_levels_10_25_50_percent_total() public {
        uint16[3] memory bonusLevels = [uint16(0), uint16(1500), uint16(4000)];
        uint16[3] memory expectedTotals = [uint16(1000), uint16(2500), uint16(5000)];
        for (uint256 i = 0; i < bonusLevels.length; i++) {
            vm.startPrank(admin);
            tokenCtl.setVeForti(address(veForti));
            tokenCtl.setVeFortiBonusBps(bonusLevels[i]);
            vm.stopPrank();
            veForti.setPower(alice, 1);

            string memory label = string.concat("lvl", vm.toString(i));
            ITldRegistrarController.Registration memory r =
                _registration(label, alice, keccak256("s"), address(0), false);
            (uint256 basePrice,) = tokenCtl.quote(label);
            uint256 expected = basePrice - (basePrice * expectedTotals[i] / 10_000);
            uint256 charged = _registerToken(r, alice);
            assertEq(charged, expected, "exact total discount at this level");
        }
    }

    function test_setVeFortiBonusBps_above_cap_reverts() public {
        uint16 maxBonus = tokenCtl.MAX_DISCOUNT_BPS() - tokenCtl.BASE_DISCOUNT_BPS();
        uint16 over = maxBonus + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITldTokenPaymentController.DiscountAboveCap.selector, over, maxBonus));
        tokenCtl.setVeFortiBonusBps(over);
    }

    /// @dev `BASE_DISCOUNT_BPS + MAX_DISCOUNT_BPS - BASE_DISCOUNT_BPS == MAX_DISCOUNT_BPS` exactly —
    ///      the maximum allowed bonus is reachable, not off-by-one excluded.
    function test_setVeFortiBonusBps_at_exact_cap_succeeds() public {
        uint16 maxBonus = tokenCtl.MAX_DISCOUNT_BPS() - tokenCtl.BASE_DISCOUNT_BPS();
        vm.prank(admin);
        tokenCtl.setVeFortiBonusBps(maxBonus);
        assertEq(tokenCtl.veFortiBonusBps(), maxBonus);
    }

    function test_discount_setters_are_admin_only() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, tokenCtl.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        tokenCtl.setVeForti(address(veForti));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, tokenCtl.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        tokenCtl.setVeFortiBonusBps(100);
    }

    // =============================================================================================
    // Buyback split correctness — exact remainder, no dust, with and without an integrator
    // =============================================================================================

    function test_buyback_only_no_integrator_exact_split() public {
        vm.prank(admin);
        tokenCtl.setBuyback(buyback, 1500); // 15%

        ITldRegistrarController.Registration memory r = _registration("bb1", alice, keccak256("s"), address(0), false);
        (uint256 basePrice,) = tokenCtl.quote("bb1");
        uint256 price = basePrice - basePrice * tokenCtl.BASE_DISCOUNT_BPS() / 10_000; // base discount, no veFORTI
        uint256 charged = _registerToken(r, alice);
        assertEq(charged, price);

        uint256 expectedBuyback = price * 1500 / 10_000;
        assertEq(tokenCtl.withdrawable(buyback), expectedBuyback, "buyback share credited to pull ledger");
        assertEq(forti.balanceOf(treasury), price - expectedBuyback, "remainder pushed to treasury");
        assertEq(
            tokenCtl.withdrawable(buyback) + forti.balanceOf(treasury), price, "no dust: buyback + treasury == price"
        );
    }

    function testFuzz_buyback_and_integrator_split_no_dust(uint16 buybackBps, uint16 rateBps) public {
        buybackBps = uint16(bound(uint256(buybackBps), 0, tokenCtl.MAX_BUYBACK_BPS()));
        rateBps = uint16(bound(uint256(rateBps), 0, CAP_BPS));

        vm.startPrank(admin);
        if (buybackBps > 0) tokenCtl.setBuyback(buyback, buybackBps);
        integratorRegistry.setIntegratorRate(integrator, rateBps);
        vm.stopPrank();

        ITldRegistrarController.Registration memory r = _registration(
            string.concat("fz", vm.toString(uint256(buybackBps)), "-", vm.toString(uint256(rateBps))),
            alice,
            keccak256("s"),
            address(0),
            false
        );
        (uint256 basePrice,) = tokenCtl.quote(r.label);
        uint256 price = basePrice - basePrice * tokenCtl.BASE_DISCOUNT_BPS() / 10_000; // base discount, no veFORTI bonus in this test
        uint256 charged = _registerTokenWithIntegrator(r, alice, integrator);
        assertEq(charged, price, "only the mandatory base discount applies in this test");

        uint256 buybackShare = tokenCtl.withdrawable(buyback);
        uint256 integratorShare = tokenCtl.withdrawable(integrator);
        uint256 treasuryShare = forti.balanceOf(treasury);

        assertEq(
            buybackShare, price * buybackBps / 10_000, "buyback share is exactly buybackBps of the discounted price"
        );
        uint256 remaining = price - buybackShare;
        assertEq(
            integratorShare, remaining * rateBps / 10_000, "integrator share computed on the post-buyback remainder"
        );
        assertEq(
            buybackShare + integratorShare + treasuryShare,
            price,
            "no dust created or lost across the full [0, cap] x [0, cap] grid"
        );
    }

    function test_buyback_share_bps_above_cap_reverts() public {
        uint16 cap = tokenCtl.MAX_BUYBACK_BPS();
        uint16 over = cap + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITldTokenPaymentController.BuybackAboveCap.selector, over, cap));
        tokenCtl.setBuyback(buyback, over);
    }

    function test_buyback_nonzero_share_requires_recipient() public {
        vm.prank(admin);
        vm.expectRevert(ITldTokenPaymentController.BuybackRecipientRequired.selector);
        tokenCtl.setBuyback(address(0), 100);
    }

    function test_buyback_clearing_share_also_clears_recipient() public {
        vm.startPrank(admin);
        tokenCtl.setBuyback(buyback, 1000);
        assertEq(tokenCtl.buybackRecipient(), buyback);
        tokenCtl.setBuyback(buyback, 0);
        vm.stopPrank();
        assertEq(tokenCtl.buybackRecipient(), address(0), "share=0 clears the recipient back to address(0)");
        assertEq(tokenCtl.buybackShareBps(), 0);
    }

    function test_buyback_and_discount_combined_still_no_dust() public {
        vm.startPrank(admin);
        tokenCtl.setBuyback(buyback, 2000); // 20%
        tokenCtl.setVeForti(address(veForti));
        tokenCtl.setVeFortiBonusBps(1500); // + bonus => total discount 10% + 15% = 25%
        integratorRegistry.setIntegratorRate(integrator, 2500); // 25%
        vm.stopPrank();
        veForti.setPower(alice, 1);

        ITldRegistrarController.Registration memory r = _registration("combo", alice, keccak256("s"), address(0), false);
        (uint256 basePrice,) = tokenCtl.quote("combo");
        uint256 expectedCharge = basePrice - basePrice * 2500 / 10_000;
        uint256 charged = _registerTokenWithIntegrator(r, alice, integrator);
        assertEq(charged, expectedCharge, "base + bonus discount applied before the split");

        uint256 buybackShare = tokenCtl.withdrawable(buyback);
        uint256 integratorShare = tokenCtl.withdrawable(integrator);
        uint256 treasuryShare = forti.balanceOf(treasury);
        assertEq(
            buybackShare + integratorShare + treasuryShare, expectedCharge, "no dust on the discounted price either"
        );
    }

    // =============================================================================================
    // Withdraw (pull ledger) — integrator and buyback shares are ordinary withdrawable[] balances
    // =============================================================================================

    function test_withdraw_integrator_and_buyback_then_double_withdraw_reverts() public {
        vm.prank(admin);
        tokenCtl.setBuyback(buyback, 1000);

        ITldRegistrarController.Registration memory r = _registration("wd", alice, keccak256("s"), address(0), false);
        _registerTokenWithIntegrator(r, alice, integrator);

        uint256 integratorOwed = tokenCtl.withdrawable(integrator);
        uint256 buybackOwed = tokenCtl.withdrawable(buyback);
        assertGt(integratorOwed, 0);
        assertGt(buybackOwed, 0);

        vm.prank(integrator);
        tokenCtl.withdraw();
        assertEq(forti.balanceOf(integrator), integratorOwed);
        assertEq(tokenCtl.withdrawable(integrator), 0);

        vm.prank(buyback);
        tokenCtl.withdraw();
        assertEq(forti.balanceOf(buyback), buybackOwed);

        vm.expectRevert(ITldTokenPaymentController.NothingToWithdraw.selector);
        vm.prank(integrator);
        tokenCtl.withdraw();
    }

    // =============================================================================================
    // Validation surface: bad integrator, unsupported token, pause
    // =============================================================================================

    function test_registerWithIntegrator_zeroAddress_reverts() public {
        ITldRegistrarController.Registration memory r = _registration("zero", alice, keccak256("s"), address(0), false);
        _commitAndWaitToken(r, alice);
        (uint256 price,) = tokenCtl.quote("zero");
        _fundAndApprove(alice, price);
        vm.expectRevert(ITldTokenPaymentController.IntegratorRequired.selector);
        vm.prank(alice);
        tokenCtl.registerWithIntegrator(r, price, address(0));
    }

    function test_unsupported_payment_token_reverts_and_state_untouched() public {
        // Clear support after commit — the same shape as a fee-split fail-closed test: nothing mutates.
        vm.prank(admin);
        oracle.setPaymentToken(address(forti), false, 0);

        ITldRegistrarController.Registration memory r =
            _registration("unsupp", alice, keccak256("s"), address(0), false);
        bytes32 commitment = _commitAndWaitToken(r, alice);

        (, bool supported) = tokenCtl.quote("unsupp");
        assertFalse(supported);

        vm.expectRevert(
            abi.encodeWithSelector(ITldTokenPaymentController.PaymentTokenNotSupported.selector, address(forti))
        );
        vm.prank(alice);
        tokenCtl.register(r, type(uint256).max);

        assertEq(
            tokenCtl.commitments(commitment), block.timestamp - MIN_AGE, "commitment survives a fail-closed revert"
        );
        assertTrue(tokenCtl.available("unsupp"));
    }

    function test_pause_blocks_register_but_not_withdraw() public {
        vm.prank(admin);
        tokenCtl.setBuyback(buyback, 500);
        ITldRegistrarController.Registration memory r =
            _registration("beforepause", alice, keccak256("s"), address(0), false);
        _registerToken(r, alice);

        vm.prank(pauser);
        tokenCtl.pause();

        ITldRegistrarController.Registration memory r2 =
            _registration("duringpause", bob, keccak256("s"), address(0), false);
        _commitAndWaitToken(r2, bob);
        (uint256 price,) = tokenCtl.quote("duringpause");
        _fundAndApprove(bob, price);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(bob);
        tokenCtl.register(r2, price);

        vm.prank(admin);
        tokenCtl.unpause();
        vm.prank(bob);
        tokenCtl.register(r2, price);
        assertEq(reg.ownerOf(uint256(_labelhash("duringpause"))), bob);
    }

    // =============================================================================================
    // Native controller is completely unaffected by the token controller's presence
    // =============================================================================================

    /// @dev The exact same assertions `TldRegistrarControllerV2.t.sol` makes for a plain `register()`,
    ///      run again AFTER the token controller has been deployed and additively authorized on the
    ///      same registrar/oracle namespace — nothing about the native path changes.
    function test_native_register_unaffected_by_sibling_token_controller() public {
        ITldRegistrarController.Registration memory r =
            _registration("nativeok", alice, keccak256("s"), address(0), false);
        bytes32 commitment = nativeCtl.makeCommitment(r);
        vm.prank(alice);
        nativeCtl.commit(commitment);
        vm.warp(block.timestamp + MIN_AGE);
        uint256 price = nativeCtl.quote("nativeok");
        vm.deal(alice, price);

        uint256 treasuryBefore = treasury.balance;
        uint256 soldBefore = oracle.namespaceInfo(node).totalSold;

        vm.prank(alice);
        nativeCtl.register{value: price}(r, price);

        assertEq(treasury.balance - treasuryBefore, price, "native controller still pays treasury in native value");
        assertEq(reg.ownerOf(uint256(_labelhash("nativeok"))), alice);
        assertEq(
            oracle.namespaceInfo(node).totalSold, soldBefore + 1, "native controller still advances the volume ramp"
        );
        assertEq(forti.balanceOf(treasury), 0, "no FORTI ever touched by a native-paid registration");
    }

    /// @dev The flip side: a FORTI-paid registration through the sibling controller does NOT advance
    ///      the shared oracle's volume ramp — `recordSale` stays gated to the native controller alone
    ///      (documented limitation, not a bug: widening that gate is explicitly out of scope here).
    function test_token_paid_registration_does_not_advance_oracle_volume_ramp() public {
        uint64 soldBefore = oracle.namespaceInfo(node).totalSold;
        ITldRegistrarController.Registration memory r =
            _registration("noramp", alice, keccak256("s"), address(0), false);
        _registerToken(r, alice);
        assertEq(oracle.namespaceInfo(node).totalSold, soldBefore, "FORTI-paid sales do not call oracle.recordSale");
    }

    /// @dev Deploying + authorizing the token controller must not touch the directory's row or the
    ///      native controller's own `hasRole`/pause state.
    function test_directory_and_native_roles_untouched_after_sibling_authorization() public view {
        assertEq(directory.controllerOf(node), address(nativeCtl), "directory still points at the native controller");
        assertTrue(nativeCtl.hasRole(nativeCtl.PAUSER_ROLE(), pauser));
        assertFalse(nativeCtl.paused());
        assertTrue(reg.isApprovedForAll(address(0), address(0)) == false); // sanity: registrar still a normal ERC-721
    }
}
