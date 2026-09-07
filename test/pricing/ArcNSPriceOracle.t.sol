// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ArcNSPriceOracle} from "../../src/pricing/ArcNSPriceOracle.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";

/// @notice Twins of every pricing test in `x1-handles/programs/x1-handles/src/lib.rs` `mod tests`
///         (same names, `test_` prefix), plus the stateful oracle surface (roles, namespaces,
///         isolation) and the CEO tables from `docs/plan/pricing.md` §3 Model A.
contract ArcNSPriceOracleTest is Test {
    uint256 internal constant LAUNCH = 1_000_000;
    uint256 internal constant Q = 91 days;
    uint256 internal constant STEP = 500;
    /// @dev `total_handles_sold` at which the volume ramp is fully maxed (4 steps).
    uint256 internal constant VOLUME_CEILING = STEP * 4;
    uint256 internal constant USDC = 1e18;

    bytes32 internal constant ARC = ArcNSConstants.ARC_NODE;
    bytes32 internal constant CIRCLE = ArcNSConstants.CIRCLE_NODE;
    bytes32 internal constant HANDLE = ArcNSConstants.HANDLE_ROOT;

    address internal admin = makeAddr("timelock");
    address internal arcController = makeAddr("arcController");
    address internal circleController = makeAddr("circleController");
    address internal handleController = makeAddr("handleController");
    address internal tokenizer = makeAddr("handleRegistry");
    address internal stranger = makeAddr("stranger");

    ArcNSPriceOracle internal oracle;

    function setUp() public {
        vm.warp(LAUNCH);
        oracle = new ArcNSPriceOracle(admin);
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    function _flat(uint256 v) internal pure returns (uint256[10] memory t) {
        for (uint256 i = 0; i < 10; i++) {
            t[i] = v;
        }
    }

    function _handleTiers() internal pure returns (uint256[10] memory t) {
        uint256[10] memory usdc = [uint256(100_000), 10_000, 1000, 200, 40, 20, 20, 20, 20, 10];
        for (uint256 i = 0; i < 10; i++) {
            t[i] = usdc[i] * USDC;
        }
    }

    function _tldTiers() internal pure returns (uint256[10] memory t) {
        t = _handleTiers();
        for (uint256 i = 0; i < 10; i++) {
            t[i] /= 2;
        }
    }

    function _tokenizeTiers() internal pure returns (uint256[10] memory t) {
        uint256[10] memory usdc = [uint256(80), 60, 40, 12, 4, 3, 3, 3, 3, 2];
        for (uint256 i = 0; i < 10; i++) {
            t[i] = usdc[i] * USDC;
        }
    }

    function _init(bytes32 ns, address controller, address tok, uint256[10] memory tiers, uint256[10] memory tok_)
        internal
    {
        vm.prank(admin);
        oracle.initNamespace(ns, controller, tok, uint64(LAUNCH), tiers, tok_);
    }

    function _sell(bytes32 ns, address controller, uint256 n) internal {
        vm.startPrank(controller);
        for (uint256 i = 0; i < n; i++) {
            oracle.recordSale(ns);
        }
        vm.stopPrank();
    }

    function _tokenize(bytes32 ns, address tok, uint256 n) internal {
        vm.startPrank(tok);
        for (uint256 i = 0; i < n; i++) {
            oracle.recordTokenize(ns);
        }
        vm.stopPrank();
    }

    /// @dev X1 `quarters_elapsed`: saturating at 0 when `now < launch`.
    function _steps(uint256 launch, uint256 now_) internal pure returns (uint256) {
        return now_ < launch ? 0 : (now_ - launch) / Q;
    }

    /// @dev X1 `price_now` twin over the oracle's pure helpers (the Rust tests are pure too).
    function _priceNow(uint256 tier, uint256 launch, uint256 now_, uint256 sold) internal view returns (uint256) {
        return oracle.computePrice(tier, oracle.rampBps(_steps(launch, now_)), oracle.rampBps(sold / STEP));
    }

    /// @dev X1 `nft_mint_price_now` twin.
    function _nftMintPriceNow(uint256 tier, uint256 launch, uint256 now_, uint256 minted)
        internal
        view
        returns (uint256)
    {
        return oracle.computePrice(tier, oracle.rampBps(_steps(launch, now_)), oracle.rampBps(minted / STEP));
    }

    function _label(uint256 len) internal pure returns (string memory) {
        bytes memory b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = "a";
        }
        return string(b);
    }

    // ---------------------------------------------------------------------------------------------
    // Rust twins (lib.rs `mod tests`)
    // ---------------------------------------------------------------------------------------------

    function test_intro_ramp_runs_50_to_100_percent_over_four_quarters() public view {
        uint256 full = 40_000_000_000; // 40 XNT, the 6-9 char tier
        uint256[5] memory expected = [uint256(50), 62, 75, 87, 100];
        for (uint256 q = 0; q <= 4; q++) {
            assertEq(_priceNow(full, LAUNCH, LAUNCH + q * Q, VOLUME_CEILING) * 100 / full, expected[q]);
        }
    }

    function test_ramp_is_capped_and_never_exceeds_full_price() public view {
        uint256 full = 1_000_000;
        uint256[5] memory qs = [uint256(4), 5, 10, 100, 10_000];
        for (uint256 i = 0; i < qs.length; i++) {
            assertEq(_priceNow(full, LAUNCH, LAUNCH + qs[i] * Q, VOLUME_CEILING), full);
        }
        uint256[3] memory solds = [VOLUME_CEILING, VOLUME_CEILING + 1, VOLUME_CEILING * 1000];
        for (uint256 i = 0; i < solds.length; i++) {
            assertEq(_priceNow(full, LAUNCH, LAUNCH + 4 * Q, solds[i]), full);
        }
        // rampBps itself saturates for any input (no overflow on absurd step counts).
        assertEq(oracle.rampBps(type(uint256).max), 10_000);
    }

    function test_a_clock_before_launch_does_not_underflow_or_discount_further() public {
        assertEq(_priceNow(1_000_000, LAUNCH, LAUNCH - 999_999, VOLUME_CEILING), 500_000);
        assertEq(_priceNow(1_000_000, LAUNCH, 0, VOLUME_CEILING), 500_000);
        // Stateful: the oracle's clock is block.timestamp.
        _init(ARC, arcController, address(0), _flat(1_000_000), _flat(0));
        _sell(ARC, arcController, VOLUME_CEILING);
        vm.warp(LAUNCH - 999_999);
        assertEq(oracle.timeBps(ARC), 5000);
        assertEq(oracle.quote(ARC, "abc"), 500_000);
        vm.warp(1);
        assertEq(oracle.quote(ARC, "abc"), 500_000);
    }

    function test_price_math_does_not_overflow_at_realistic_maximums() public view {
        uint256 twoChar = 15_000 * 1_000_000_000;
        assertEq(_priceNow(twoChar, LAUNCH, LAUNCH, VOLUME_CEILING), twoChar / 2);
        // Worst case: a u64::MAX tier at both ramps 100 % returns exactly the ceiling.
        assertEq(_priceNow(type(uint64).max, LAUNCH, LAUNCH + 4 * Q, VOLUME_CEILING), type(uint64).max);
    }

    function test_both_ramps_at_floor_multiply_to_a_quarter_of_ceiling_price() public view {
        uint256 ceiling = 100_000_000_000;
        assertEq(_priceNow(ceiling, LAUNCH, LAUNCH, 0), 25_000_000_000);
    }

    function test_both_ramps_at_ceiling_equal_the_full_tier_price() public view {
        uint256 ceiling = 100_000_000_000;
        assertEq(_priceNow(ceiling, LAUNCH, LAUNCH + 4 * Q, VOLUME_CEILING), ceiling);
    }

    function test_time_floor_volume_ceiling_is_half_price() public view {
        uint256 ceiling = 100_000_000_000;
        assertEq(_priceNow(ceiling, LAUNCH, LAUNCH, VOLUME_CEILING), 50_000_000_000);
    }

    function test_time_ceiling_volume_floor_is_also_half_price() public view {
        uint256 ceiling = 100_000_000_000;
        assertEq(_priceNow(ceiling, LAUNCH, LAUNCH + 4 * Q, 0), 50_000_000_000);
    }

    function test_mid_ramp_combination_matches_a_hand_computed_value() public view {
        uint256 ceiling = 100_000_000_000;
        uint256 timeBps = oracle.rampBps(2);
        assertEq(timeBps, 7500);
        uint256 volumeBps = oracle.rampBps(500 / STEP);
        assertEq(volumeBps, 6250);
        uint256 expected = 46_875_000_000; // 100e9 * 0.75 * 0.625
        assertEq(oracle.computePrice(ceiling, timeBps, volumeBps), expected);
        assertEq(_priceNow(ceiling, LAUNCH, LAUNCH + 2 * Q, 500), expected);
    }

    function test_volume_ramp_steps_exactly_at_multiples_of_the_step_count() public {
        assertEq(oracle.rampBps((STEP - 1) / STEP), 5000);
        assertEq(oracle.rampBps(STEP / STEP), 6250);
        assertEq(oracle.rampBps((2 * STEP - 1) / STEP), 6250);
        assertEq(oracle.rampBps(2 * STEP / STEP), 7500);
        // Stateful boundaries 499 / 500 / 999 / 1000 through the real counter.
        _init(ARC, arcController, address(0), _flat(1e18), _flat(0));
        _sell(ARC, arcController, 499);
        assertEq(oracle.volumeBps(ARC), 5000);
        assertEq(oracle.quote(ARC, "abc"), 0.25e18);
        _sell(ARC, arcController, 1);
        assertEq(oracle.volumeBps(ARC), 6250);
        assertEq(oracle.quote(ARC, "abc"), 0.3125e18);
        _sell(ARC, arcController, 499);
        assertEq(oracle.volumeBps(ARC), 6250);
        _sell(ARC, arcController, 1);
        assertEq(oracle.volumeBps(ARC), 7500);
        assertEq(oracle.namespaceInfo(ARC).totalSold, 1000);
    }

    function test_nft_mint_price_shares_the_time_ramp_but_has_an_independent_volume_counter() public {
        uint256 regTier = 100_000_000_000;
        uint256 nftTier = 50_000_000_000;
        assertEq(_priceNow(regTier, LAUNCH, LAUNCH, VOLUME_CEILING), 50_000_000_000);
        assertEq(_nftMintPriceNow(nftTier, LAUNCH, LAUNCH, 0), 12_500_000_000);
        // Stateful: 2000 sales move `quote`, not `quoteTokenize`; tokenize moves only its own ramp.
        _init(HANDLE, handleController, tokenizer, _flat(regTier), _flat(nftTier));
        _sell(HANDLE, handleController, VOLUME_CEILING);
        assertEq(oracle.quote(HANDLE, "abc"), 50_000_000_000);
        assertEq(oracle.quoteTokenize(HANDLE, "abc"), 12_500_000_000);
        _tokenize(HANDLE, tokenizer, STEP);
        assertEq(oracle.tokenizeVolumeBps(HANDLE), 6250);
        assertEq(oracle.volumeBps(HANDLE), 10_000);
        assertEq(oracle.namespaceInfo(HANDLE).tokenized, STEP);
        assertEq(oracle.namespaceInfo(HANDLE).totalSold, VOLUME_CEILING);
    }

    function test_tier_index_maps_lengths_to_the_intended_bands() public view {
        assertEq(oracle.tierIndex(1), 0);
        assertEq(oracle.tierIndex(2), 1);
        assertEq(oracle.tierIndex(6), 5);
        assertEq(oracle.tierIndex(10), 9);
        assertEq(oracle.tierIndex(11), 9);
        assertEq(oracle.tierIndex(32), 9);
        assertEq(oracle.tierIndex(0), 0);
    }

    function test_every_tier_index_is_in_bounds_for_the_config_array() public view {
        for (uint256 len = 0; len <= 64; len++) {
            assertLt(oracle.tierIndex(len), 10);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    function test_curve_constants_are_the_x1_values() public view {
        assertEq(oracle.START_BPS(), 5000);
        assertEq(oracle.STEP_BPS(), 1250);
        assertEq(oracle.STEP_COUNT(), 500);
        assertEq(oracle.STEP_SECS(), 91 days);
    }

    // ---------------------------------------------------------------------------------------------
    // CEO tables (pricing.md §3 Model A) at launch: both ramps 50 % ⇒ 25 % of ceiling
    // ---------------------------------------------------------------------------------------------

    function test_handle_table_at_launch_matches_pricing_md() public {
        _init(HANDLE, handleController, tokenizer, _handleTiers(), _tokenizeTiers());
        assertEq(oracle.quote(HANDLE, "ab"), 2500 * USDC);
        assertEq(oracle.quote(HANDLE, "abc"), 250 * USDC);
        assertEq(oracle.quote(HANDLE, "abcd"), 50 * USDC);
        assertEq(oracle.quote(HANDLE, "abcde"), 10 * USDC);
        for (uint256 len = 6; len <= 9; len++) {
            assertEq(oracle.quote(HANDLE, _label(len)), 5 * USDC);
        }
        assertEq(oracle.quote(HANDLE, _label(10)), 2.5e18);
        assertEq(oracle.quote(HANDLE, _label(32)), 2.5e18);
        // 1-char is treasury inventory but the curve still prices it.
        assertEq(oracle.quote(HANDLE, "a"), 25_000 * USDC);
    }

    function test_tld_table_at_launch_is_half_the_handle_table() public {
        _init(ARC, arcController, address(0), _tldTiers(), _flat(0));
        _init(CIRCLE, circleController, address(0), _tldTiers(), _flat(0));
        assertEq(oracle.quote(ARC, "ab"), 1250 * USDC);
        assertEq(oracle.quote(ARC, "abc"), 125 * USDC);
        assertEq(oracle.quote(ARC, "nike"), 25 * USDC);
        assertEq(oracle.quote(ARC, "abcde"), 5 * USDC);
        for (uint256 len = 6; len <= 9; len++) {
            assertEq(oracle.quote(ARC, _label(len)), 2.5e18);
        }
        assertEq(oracle.quote(ARC, _label(10)), 1.25e18);
        assertEq(oracle.quote(CIRCLE, "nike"), 25 * USDC);
        assertEq(oracle.quote(CIRCLE, _label(10)), 1.25e18);
    }

    function test_tokenize_table_at_launch_matches_pricing_md() public {
        _init(HANDLE, handleController, tokenizer, _handleTiers(), _tokenizeTiers());
        assertEq(oracle.quoteTokenize(HANDLE, "a"), 20 * USDC);
        assertEq(oracle.quoteTokenize(HANDLE, "ab"), 15 * USDC);
        assertEq(oracle.quoteTokenize(HANDLE, "abc"), 10 * USDC);
        assertEq(oracle.quoteTokenize(HANDLE, "abcd"), 3 * USDC);
        assertEq(oracle.quoteTokenize(HANDLE, "abcde"), 1 * USDC);
        assertEq(oracle.quoteTokenize(HANDLE, "abcdef"), 0.75e18);
        assertEq(oracle.quoteTokenize(HANDLE, _label(10)), 0.5e18);
    }

    // ---------------------------------------------------------------------------------------------
    // Namespace lifecycle and roles
    // ---------------------------------------------------------------------------------------------

    function test_quote_reverts_when_namespace_not_initialised() public {
        vm.expectRevert(abi.encodeWithSelector(IArcNSPriceOracle.NamespaceNotInitialised.selector, ARC));
        oracle.quote(ARC, "abc");
        vm.expectRevert(abi.encodeWithSelector(IArcNSPriceOracle.NamespaceNotInitialised.selector, ARC));
        oracle.quoteTokenize(ARC, "abc");
    }

    function test_quote_reverts_for_non_canonical_label() public {
        _init(ARC, arcController, address(0), _tldTiers(), _flat(0));
        string[6] memory bad = ["Nike", "nik-", "a--b", "123", "", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(IArcNSPriceOracle.NotCanonicalLabel.selector, bad[i]));
            oracle.quote(ARC, bad[i]);
            vm.expectRevert(abi.encodeWithSelector(IArcNSPriceOracle.NotCanonicalLabel.selector, bad[i]));
            oracle.quoteTokenize(ARC, bad[i]);
        }
    }

    function test_initNamespace_once_and_admin_only() public {
        vm.expectEmit(true, false, false, true);
        emit IArcNSPriceOracle.NamespaceInitialised(ARC, arcController, address(0), uint64(LAUNCH));
        vm.expectEmit(true, false, false, true);
        emit IArcNSPriceOracle.TiersUpdated(ARC, _tldTiers());
        vm.expectEmit(true, false, false, true);
        emit IArcNSPriceOracle.TokenizeTiersUpdated(ARC, _flat(0));
        _init(ARC, arcController, address(0), _tldTiers(), _flat(0));

        IArcNSPriceOracle.NamespaceInfo memory info = oracle.namespaceInfo(ARC);
        assertTrue(info.initialised);
        assertEq(info.controller, arcController);
        assertEq(info.launchTs, uint64(LAUNCH));
        assertEq(info.totalSold, 0);
        assertEq(oracle.tiers(ARC)[3], 100 * USDC);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IArcNSPriceOracle.NamespaceAlreadyInitialised.selector, ARC));
        oracle.initNamespace(ARC, arcController, address(0), uint64(LAUNCH), _tldTiers(), _flat(0));

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        oracle.initNamespace(CIRCLE, circleController, address(0), uint64(LAUNCH), _tldTiers(), _flat(0));
    }

    function test_setTiers_admin_only_and_emits_TiersUpdated() public {
        _init(ARC, arcController, address(0), _tldTiers(), _flat(0));
        uint256[10] memory next = _flat(7e18);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        oracle.setTiers(ARC, next);
        vm.prank(arcController);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, arcController, bytes32(0))
        );
        oracle.setTiers(ARC, next);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit IArcNSPriceOracle.TiersUpdated(ARC, next);
        oracle.setTiers(ARC, next);
        assertEq(oracle.quote(ARC, "abc"), 1.75e18);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IArcNSPriceOracle.NamespaceNotInitialised.selector, CIRCLE));
        oracle.setTiers(CIRCLE, next);
    }

    function test_setTokenizeTiers_admin_only_and_emits() public {
        _init(HANDLE, handleController, tokenizer, _handleTiers(), _tokenizeTiers());
        uint256[10] memory next = _flat(4e18);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        oracle.setTokenizeTiers(HANDLE, next);
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit IArcNSPriceOracle.TokenizeTiersUpdated(HANDLE, next);
        oracle.setTokenizeTiers(HANDLE, next);
        assertEq(oracle.quoteTokenize(HANDLE, "abc"), 1e18);
        assertEq(oracle.quote(HANDLE, "abc"), 250 * USDC, "sale tiers untouched");
    }

    function test_setController_admin_only_and_rotates_both_roles() public {
        _init(HANDLE, handleController, tokenizer, _handleTiers(), _tokenizeTiers());
        address c2 = makeAddr("controller2");
        address t2 = makeAddr("tokenizer2");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        oracle.setController(HANDLE, c2, t2);
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit IArcNSPriceOracle.ControllerChanged(HANDLE, c2, t2);
        oracle.setController(HANDLE, c2, t2);

        vm.prank(handleController);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSPriceOracle.NotNamespaceController.selector, HANDLE, handleController)
        );
        oracle.recordSale(HANDLE);
        vm.prank(tokenizer);
        vm.expectRevert(abi.encodeWithSelector(IArcNSPriceOracle.NotNamespaceTokenizer.selector, HANDLE, tokenizer));
        oracle.recordTokenize(HANDLE);
        _sell(HANDLE, c2, 1);
        _tokenize(HANDLE, t2, 1);
        assertEq(oracle.namespaceInfo(HANDLE).totalSold, 1);
        assertEq(oracle.namespaceInfo(HANDLE).tokenized, 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IArcNSPriceOracle.NamespaceNotInitialised.selector, ARC));
        oracle.setController(ARC, c2, t2);
    }

    function test_recordSale_only_by_namespace_controller() public {
        _init(ARC, arcController, address(0), _tldTiers(), _flat(0));
        _init(CIRCLE, circleController, address(0), _tldTiers(), _flat(0));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IArcNSPriceOracle.NotNamespaceController.selector, ARC, stranger));
        oracle.recordSale(ARC);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IArcNSPriceOracle.NotNamespaceController.selector, ARC, admin));
        oracle.recordSale(ARC);
        // The `.circle` controller cannot bump `.arc`.
        vm.prank(circleController);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSPriceOracle.NotNamespaceController.selector, ARC, circleController)
        );
        oracle.recordSale(ARC);
        // Uninitialised namespace: reported as such, not as a role error.
        vm.prank(arcController);
        vm.expectRevert(abi.encodeWithSelector(IArcNSPriceOracle.NamespaceNotInitialised.selector, HANDLE));
        oracle.recordSale(HANDLE);

        vm.prank(arcController);
        vm.expectEmit(true, false, false, true);
        emit IArcNSPriceOracle.SaleRecorded(ARC, 1);
        oracle.recordSale(ARC);
        assertEq(oracle.namespaceInfo(ARC).totalSold, 1);
    }

    function test_recordTokenize_only_by_namespace_tokenizer() public {
        _init(HANDLE, handleController, tokenizer, _handleTiers(), _tokenizeTiers());
        _init(ARC, arcController, address(0), _tldTiers(), _flat(0));
        vm.prank(handleController);
        vm.expectRevert(
            abi.encodeWithSelector(IArcNSPriceOracle.NotNamespaceTokenizer.selector, HANDLE, handleController)
        );
        oracle.recordTokenize(HANDLE);
        // A TLD namespace has no tokenizer: nobody can bump it (address(0) is never msg.sender).
        vm.prank(arcController);
        vm.expectRevert(abi.encodeWithSelector(IArcNSPriceOracle.NotNamespaceTokenizer.selector, ARC, arcController));
        oracle.recordTokenize(ARC);
        vm.prank(tokenizer);
        vm.expectEmit(true, false, false, true);
        emit IArcNSPriceOracle.TokenizeRecorded(HANDLE, 1);
        oracle.recordTokenize(HANDLE);
        assertEq(oracle.namespaceInfo(HANDLE).tokenized, 1);
    }

    function test_per_namespace_isolation_tiers_and_volume() public {
        _init(ARC, arcController, address(0), _tldTiers(), _flat(0));
        _init(CIRCLE, circleController, address(0), _tldTiers(), _flat(0));
        uint256 arcBefore = oracle.quote(ARC, "nike");

        // Changing `.circle` tiers leaves the `.arc` quote unchanged.
        vm.prank(admin);
        oracle.setTiers(CIRCLE, _flat(1e18));
        assertEq(oracle.quote(CIRCLE, "nike"), 0.25e18);
        assertEq(oracle.quote(ARC, "nike"), arcBefore);

        // `.arc` sales do not move the `.circle` volume ramp.
        _sell(ARC, arcController, STEP);
        assertEq(oracle.volumeBps(ARC), 6250);
        assertEq(oracle.volumeBps(CIRCLE), 5000);
        assertEq(oracle.namespaceInfo(CIRCLE).totalSold, 0);
        assertEq(oracle.quote(CIRCLE, "nike"), 0.25e18);
    }

    function test_launch_ts_is_per_namespace() public {
        _init(ARC, arcController, address(0), _tldTiers(), _flat(0));
        vm.prank(admin);
        oracle.initNamespace(CIRCLE, circleController, address(0), uint64(LAUNCH + 2 * Q), _tldTiers(), _flat(0));
        vm.warp(LAUNCH + 2 * Q);
        assertEq(oracle.timeBps(ARC), 7500);
        assertEq(oracle.timeBps(CIRCLE), 5000);
    }

    function test_counters_never_decrement_across_tier_and_controller_changes() public {
        _init(ARC, arcController, address(0), _tldTiers(), _flat(0));
        _sell(ARC, arcController, 3);
        vm.startPrank(admin);
        oracle.setTiers(ARC, _flat(1e18));
        oracle.setController(ARC, circleController, address(0));
        vm.stopPrank();
        assertEq(oracle.namespaceInfo(ARC).totalSold, 3);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    function testFuzz_price_monotonic_in_time_and_volume(uint256 ceiling, uint64 t1, uint64 t2, uint64 s1, uint64 s2)
        public
        view
    {
        ceiling = bound(ceiling, 0, type(uint128).max);
        if (t1 > t2) (t1, t2) = (t2, t1);
        if (s1 > s2) (s1, s2) = (s2, s1);
        uint256 p1 = _priceNow(ceiling, LAUNCH, LAUNCH + uint256(t1), s1);
        uint256 p2 = _priceNow(ceiling, LAUNCH, LAUNCH + uint256(t2), s2);
        assertLe(p1, p2);
    }

    function testFuzz_price_never_exceeds_ceiling(uint256 ceiling, uint256 now_, uint64 sold) public view {
        ceiling = bound(ceiling, 0, type(uint128).max);
        uint256 p = _priceNow(ceiling, LAUNCH, now_, sold);
        assertLe(p, ceiling);
        // and never below the 25 % early-bird floor (integer division floors once).
        assertGe(p, ceiling / 4);
    }

    function testFuzz_quote_matches_pure_twin(uint256 ceiling, uint32 dt, uint16 sold) public {
        ceiling = bound(ceiling, 0, type(uint96).max);
        sold = uint16(bound(sold, 0, 2100));
        _init(ARC, arcController, address(0), _flat(ceiling), _flat(0));
        _sell(ARC, arcController, sold);
        vm.warp(LAUNCH + dt);
        assertEq(oracle.quote(ARC, "nike"), _priceNow(ceiling, LAUNCH, LAUNCH + dt, sold));
    }
}
