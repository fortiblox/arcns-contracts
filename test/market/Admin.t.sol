// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {MarketFixture} from "./MarketFixture.sol";
import {ArcNSMarket} from "../../src/market/ArcNSMarket.sol";
import {IArcNSMarket} from "../../src/interfaces/IArcNSMarket.sol";

/// @notice Constructor, admin config, allow-list and pause tests (WP-119).
contract ArcNSMarketAdminTest is MarketFixture {
    function test_constructor_emits_initial_config_and_grants_roles() public {
        vm.expectEmit(true, true, true, true);
        emit IArcNSMarket.MarketConfigUpdated(_defaultConfig());
        ArcNSMarket m = new ArcNSMarket(
            ArcNSMarket.Init({
                admin: admin,
                pauser: pauser,
                treasury: treasury,
                nameLocks: address(nameLocks),
                config: _defaultConfig()
            })
        );
        assertTrue(m.hasRole(m.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(m.hasRole(m.PAUSER_ROLE(), pauser));
        assertEq(m.treasury(), treasury);
        assertEq(m.nameLocks(), address(nameLocks));
        assertEq(m.MIN_AUCTION_DURATION(), 600);
        assertEq(m.MAX_AUCTION_DURATION(), 30 days);
    }

    function test_constructor_allows_zero_nameLocks() public {
        ArcNSMarket m = new ArcNSMarket(
            ArcNSMarket.Init({
                admin: admin, pauser: pauser, treasury: treasury, nameLocks: address(0), config: _defaultConfig()
            })
        );
        assertEq(m.nameLocks(), address(0));
        assertFalse(m.isLocked(address(registry), aliceHandleId));
    }

    function test_constructor_zero_address_reverts() public {
        vm.expectRevert(IArcNSMarket.ZeroAddress.selector);
        new ArcNSMarket(
            ArcNSMarket.Init({
                admin: address(0), pauser: pauser, treasury: treasury, nameLocks: address(0), config: _defaultConfig()
            })
        );
        vm.expectRevert(IArcNSMarket.ZeroAddress.selector);
        new ArcNSMarket(
            ArcNSMarket.Init({
                admin: admin, pauser: address(0), treasury: treasury, nameLocks: address(0), config: _defaultConfig()
            })
        );
        vm.expectRevert(IArcNSMarket.ZeroAddress.selector);
        new ArcNSMarket(
            ArcNSMarket.Init({
                admin: admin, pauser: pauser, treasury: address(0), nameLocks: address(0), config: _defaultConfig()
            })
        );
    }

    function test_constructor_rejects_bad_config() public {
        IArcNSMarket.MarketConfig memory cfg = _defaultConfig();
        cfg.feeBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.FeeBpsTooHigh.selector, 10_001));
        new ArcNSMarket(
            ArcNSMarket.Init({admin: admin, pauser: pauser, treasury: treasury, nameLocks: address(0), config: cfg})
        );

        cfg = _defaultConfig();
        cfg.antiSnipeWindow = 400;
        cfg.antiSnipeExtend = 300;
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.AntiSnipeExtendTooShort.selector, 400, 300));
        new ArcNSMarket(
            ArcNSMarket.Init({admin: admin, pauser: pauser, treasury: treasury, nameLocks: address(0), config: cfg})
        );
    }

    function test_receive_and_fallback_revert() public {
        vm.expectRevert(IArcNSMarket.ValueNotAccepted.selector);
        (bool ok,) = address(market).call{value: 1 ether}("");
        ok; // silence unused warning; expectRevert already asserts the revert happened
        vm.expectRevert(IArcNSMarket.ValueNotAccepted.selector);
        (ok,) = address(market).call{value: 1 ether}(hex"deadbeef");
    }

    // ---- setCollectionAllowed ---------------------------------------------------------------------

    function test_setCollectionAllowed_admin_only() public {
        bytes32 adminRole = market.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        market.setCollectionAllowed(address(tld), false);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.CollectionAllowed(address(tld), false);
        market.setCollectionAllowed(address(tld), false);
        assertFalse(market.isCollectionAllowed(address(tld)));
    }

    function test_setCollectionAllowed_zero_address_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IArcNSMarket.ZeroAddress.selector);
        market.setCollectionAllowed(address(0), true);
    }

    // ---- setMarketConfig ----------------------------------------------------------------------------

    function test_setMarketConfig_admin_only_and_validated() public {
        IArcNSMarket.MarketConfig memory cfg = _defaultConfig();
        cfg.feeBps = 500;

        bytes32 adminRole = market.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        market.setMarketConfig(cfg);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(market));
        emit IArcNSMarket.MarketConfigUpdated(cfg);
        market.setMarketConfig(cfg);
        assertEq(market.marketConfig().feeBps, 500);

        IArcNSMarket.MarketConfig memory bad = _defaultConfig();
        bad.feeBps = 10_001;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IArcNSMarket.FeeBpsTooHigh.selector, 10_001));
        market.setMarketConfig(bad);
    }

    // ---- pause / unpause ------------------------------------------------------------------------

    function test_pause_pauser_only_unpause_admin_only() public {
        bytes32 pauserRole = market.PAUSER_ROLE();
        bytes32 adminRole = market.DEFAULT_ADMIN_ROLE();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, pauserRole)
        );
        market.pause();

        vm.prank(pauser);
        market.pause();
        assertTrue(market.paused());

        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, adminRole)
        );
        market.unpause();

        vm.prank(admin);
        market.unpause();
        assertFalse(market.paused());
    }

    function test_pause_blocks_only_new_actions() public {
        _approveMarket(address(registry), seller);
        vm.prank(pauser);
        market.pause();

        vm.prank(seller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.list(address(registry), aliceHandleId, 1e18, uint40(block.timestamp + 1 days));

        vm.prank(seller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.startAuction(address(registry), aliceHandleId, 1e18, 1 days);

        vm.prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.placeOffer{value: 1e18}(address(registry), aliceHandleId, uint40(block.timestamp + 1 days));

        // Unpause, list + auction so we can prove cancel/withdraw/settle still work while paused.
        vm.prank(admin);
        market.unpause();
        _list(address(registry), aliceHandleId, seller, 1e18, uint40(block.timestamp + 1 days));

        vm.prank(pauser);
        market.pause();

        // cancelListing always works
        vm.prank(seller);
        market.cancelListing(address(registry), aliceHandleId);

        // withdraw always works (nothing to withdraw here, but must not revert on pause)
        vm.prank(seller);
        vm.expectRevert(IArcNSMarket.NothingToWithdraw.selector);
        market.withdraw();
    }
}
