// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IArcNSMarket} from "../../src/interfaces/IArcNSMarket.sol";
import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {MarketDeployLib} from "../../script/lib/MarketDeployLib.sol";
import {MockOracle} from "../handle/mocks/MockOracle.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @dev `MarketDeployLib`'s functions are `internal` (inlined, no new EVM call frame), so
///      `vm.expectRevert` — which needs an actual call-depth boundary to attach to — cannot observe a
///      revert thrown directly from a library call made in the test body. This harness gives the two
///      revert-path tests below a real external call to attach `vm.expectRevert` to; it is never used
///      for the success-path tests, which call the library directly under `vm.startPrank`/`stopPrank`
///      so `msg.sender` stays `deployer` throughout every external call the library itself makes.
contract MarketDeployHarness {
    function deploy(MarketDeployLib.Params memory p) external returns (MarketDeployLib.Book memory) {
        return MarketDeployLib.deployMarketStack(p);
    }
}

/// @notice WP-124: local (no network, no broadcast) exercise of `MarketDeployLib.deployMarketStack` —
///         the same wiring logic `script/DeployMarket.s.sol` runs against a live chain — against a
///         real `HandleRegistry` (MARKET_ROLE path) and a `MockERC721` standing in for a TLD
///         registrar (no MARKET_ROLE concept). Proves the deploy library's role handoff (INV-8
///         parity) and collection allow-listing before any live deploy happens.
contract MarketDeployTest is Test {
    HandleRegistry internal registry;
    MockOracle internal oracle;
    MockERC721 internal tldStandIn;

    address internal deployer = makeAddr("deployer");
    address internal timelock = makeAddr("timelock");
    address internal pauser = makeAddr("pauser");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        oracle = new MockOracle();
        // HandleRegistry's own DEFAULT_ADMIN_ROLE starts on `deployer` here (mirroring the real
        // DeployAll.s.sol window where the deployer briefly holds admin to wire MARKET_ROLE before
        // handing off to the timelock) so `MarketDeployLib` can grant MARKET_ROLE from that role.
        registry = new HandleRegistry(deployer, treasury, IArcNSPriceOracle(address(oracle)), 7 days);
        tldStandIn = new MockERC721("Mock TLD", "MTLD");
    }

    function _params() internal view returns (MarketDeployLib.Params memory p) {
        address[] memory collections = new address[](2);
        collections[0] = address(registry);
        collections[1] = address(tldStandIn);
        bool[] memory grantMarketRole = new bool[](2);
        grantMarketRole[0] = true;
        grantMarketRole[1] = false;

        p = MarketDeployLib.Params({
            deployer: deployer,
            timelock: timelock,
            pauser: pauser,
            treasury: treasury,
            collections: collections,
            grantMarketRole: grantMarketRole,
            config: IArcNSMarket.MarketConfig({
                feeBps: 200, minBidIncrementBps: 500, antiSnipeWindow: 300, antiSnipeExtend: 300, minPrice: 0.01 ether
            }),
            unlockTimelockSecs: 7 days
        });
    }

    function test_deployMarketStack_wiresRolesAndAllowlist() public {
        MarketDeployLib.Params memory p = _params();

        // `startPrank`/`stopPrank`, not a single-shot `prank`: `deployMarketStack` is an `internal`
        // library function (inlined into this test, no new call frame), so it makes MANY external
        // calls (several `new X()` CREATEs, then `grantRole`/`renounceRole`) that all need `deployer`
        // as `msg.sender` — a one-shot `vm.prank` would only cover the first of them.
        vm.startPrank(deployer);
        MarketDeployLib.Book memory b = MarketDeployLib.deployMarketStack(p);
        vm.stopPrank();

        // Collections allow-listed on the market.
        assertTrue(b.market.isCollectionAllowed(address(registry)), "handle registry not allowed");
        assertTrue(b.market.isCollectionAllowed(address(tldStandIn)), "tld stand-in not allowed");

        // MARKET_ROLE granted only where requested.
        assertTrue(b.market.hasRole(ArcNSConstants.MARKET_ROLE, address(0)) == false, "sanity: role not default-true");
        assertTrue(
            registry.hasRole(ArcNSConstants.MARKET_ROLE, address(b.market)), "MARKET_ROLE not granted on registry"
        );

        // Handoff: deployer holds no admin role anywhere; timelock holds it everywhere it exists.
        MarketDeployLib.assertHandoff(b, p);

        // Every parity module deployed and reachable.
        assertTrue(address(b.nameLocks).code.length > 0, "NameLocks not deployed");
        assertTrue(address(b.recordDelegate).code.length > 0, "RecordDelegate not deployed");
        assertTrue(address(b.textRecords).code.length > 0, "TextRecords not deployed");
        assertTrue(address(b.attestations).code.length > 0, "AttestationRegistry not deployed");
        assertTrue(address(b.integrators).code.length > 0, "IntegratorRegistry not deployed");
        assertTrue(address(b.vouchers).code.length > 0, "Vouchers not deployed");

        // Market points at the deployed NameLocks (WP-125 wiring).
        assertEq(b.market.nameLocks(), address(b.nameLocks), "market not wired to NameLocks");

        // Config landed as configured.
        IArcNSMarket.MarketConfig memory cfg = b.market.marketConfig();
        assertEq(cfg.feeBps, 200);
        assertEq(cfg.minBidIncrementBps, 500);
    }

    function test_deployMarketStack_revertsOnZeroGovernanceAddress() public {
        MarketDeployLib.Params memory p = _params();
        p.timelock = address(0);
        MarketDeployHarness harness = new MarketDeployHarness();
        vm.expectRevert(bytes("MarketDeployLib: zero addr"));
        harness.deploy(p);
    }

    function test_deployMarketStack_revertsOnLengthMismatch() public {
        MarketDeployLib.Params memory p = _params();
        address[] memory oneCollection = new address[](1);
        oneCollection[0] = address(registry);
        p.collections = oneCollection;
        MarketDeployHarness harness = new MarketDeployHarness();
        vm.expectRevert(bytes("MarketDeployLib: length mismatch"));
        harness.deploy(p);
    }

    /// @dev The market's own initial admin is the deployer (set inside `deployMarketStack`, then
    ///      handed off to the timelock in the same call) — proves the deployer window is transient,
    ///      never externally observable as a completed deploy with the deployer still holding admin.
    function test_deployMarketStack_deployerNeverEndsWithAdmin() public {
        MarketDeployLib.Params memory p = _params();
        vm.startPrank(deployer);
        MarketDeployLib.Book memory b = MarketDeployLib.deployMarketStack(p);
        vm.stopPrank();
        bytes32 adminRole = b.market.DEFAULT_ADMIN_ROLE();
        assertFalse(b.market.hasRole(adminRole, deployer));
        assertTrue(b.market.hasRole(adminRole, timelock));
    }
}
