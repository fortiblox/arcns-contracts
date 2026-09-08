// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IArcNSMarket} from "../../src/interfaces/IArcNSMarket.sol";
import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {NameLocks} from "../../src/parity/NameLocks.sol";
import {TextRecords} from "../../src/parity/TextRecords.sol";
import {MarketDeployLib} from "../../script/lib/MarketDeployLib.sol";
import {Salts} from "../../script/lib/Salts.sol";
import {MockOracle} from "../handle/mocks/MockOracle.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @dev `MarketDeployLib`'s functions are `internal` (inlined, no new EVM call frame), so
///      `vm.expectRevert` — which needs an actual call-depth boundary to attach to — cannot observe a
///      revert thrown directly from a library call made in the test body. This harness gives the
///      revert-path tests below a real external call to attach `vm.expectRevert` to; it is never used
///      for the success-path tests, which call the library directly under `vm.startPrank`/`stopPrank`
///      so `msg.sender` stays `deployer` throughout every external call the library itself makes.
///
///      Calls `MarketDeployLib.validateParams` / `assertMarketRole` only — NOT the full
///      `deployMarketStack` — since the revert paths this harness exists for fire without any `new X()`.
///      Inlining the full `deployMarketStack` (which creates seven contracts) here previously put this
///      bare pass-through harness at 45,128 bytes runtime, well over the EIP-170 24,576-byte limit and
///      failing `forge build --sizes` in CI; calling only the small functions keeps its own bytecode tiny
///      because Solidity only inlines the code actually reachable from this contract's entrypoints.
contract MarketDeployHarness {
    function validate(MarketDeployLib.Params memory p) external pure {
        MarketDeployLib.validateParams(p);
    }

    function assertMarketRole(MarketDeployLib.Book memory b, MarketDeployLib.Params memory p) external view {
        MarketDeployLib.assertMarketRole(b, p);
    }
}

/// @notice WP-124 / WP-7632 phase 1: local (no network, no broadcast) exercise of
///         `MarketDeployLib.deployMarketStack` — the same wiring logic `script/DeployMarket.s.sol` runs
///         against a live chain — against a real `HandleRegistry` whose `DEFAULT_ADMIN_ROLE` is held by
///         the timelock (the LIVE role state after the WP-113 handoff, i.e. the deployer can NOT grant
///         `MARKET_ROLE` there) and a `MockERC721` standing in for a TLD registrar (no MARKET_ROLE
///         concept). Proves the deploy library's role handoff (INV-8 parity), collection allow-listing
///         and CREATE2 resumability before any live deploy happens, and that the phase-1 assertions no
///         longer depend on the MARKET_ROLE grant (phase 2).
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
        // Live state after WP-113: the TIMELOCK holds HandleRegistry's DEFAULT_ADMIN_ROLE, the deployer
        // holds nothing there (verified 2026-09-08 on Arc testnet, WP-7632). Phase 1 must complete
        // without ever touching MARKET_ROLE on this contract.
        registry = new HandleRegistry(timelock, treasury, IArcNSPriceOracle(address(oracle)), 7 days);
        tldStandIn = new MockERC721("Mock TLD", "MTLD");
    }

    function _params() internal view returns (MarketDeployLib.Params memory p) {
        address[] memory collections = new address[](2);
        collections[0] = address(registry);
        collections[1] = address(tldStandIn);
        bool[] memory needsMarketRole = new bool[](2);
        needsMarketRole[0] = true;
        needsMarketRole[1] = false;

        p = MarketDeployLib.Params({
            deployer: deployer,
            create2Deployer: deployer, // in-process: CREATE2 derives from the pranked sender, no factory routing
            timelock: timelock,
            pauser: pauser,
            treasury: treasury,
            collections: collections,
            needsMarketRole: needsMarketRole,
            config: IArcNSMarket.MarketConfig({
                feeBps: 200, minBidIncrementBps: 500, antiSnipeWindow: 300, antiSnipeExtend: 300, minPrice: 0.01 ether
            }),
            unlockTimelockSecs: 7 days
        });
    }

    function _deploy(MarketDeployLib.Params memory p) internal returns (MarketDeployLib.Book memory b) {
        // `startPrank`/`stopPrank`, not a single-shot `prank`: `deployMarketStack` is an `internal`
        // library function (inlined into this test, no new call frame), so it makes MANY external
        // calls (several `new X()` CREATEs, then `grantRole`/`renounceRole`) that all need `deployer`
        // as `msg.sender` — a one-shot `vm.prank` would only cover the first of them.
        vm.startPrank(deployer);
        b = MarketDeployLib.deployMarketStack(p);
        vm.stopPrank();
    }

    function test_deployMarketStack_wiresRolesAndAllowlist() public {
        MarketDeployLib.Params memory p = _params();
        MarketDeployLib.Book memory b = _deploy(p);

        // Collections allow-listed on the market.
        assertTrue(b.market.isCollectionAllowed(address(registry)), "handle registry not allowed");
        assertTrue(b.market.isCollectionAllowed(address(tldStandIn)), "tld stand-in not allowed");

        // MARKET_ROLE is NOT granted by phase 1 (the deployer cannot; governance does it in phase 2) —
        // and the phase-1 handoff assertion must pass regardless.
        assertFalse(registry.hasRole(ArcNSConstants.MARKET_ROLE, address(b.market)), "phase 1 must not grant");
        assertFalse(registry.hasRole(ArcNSConstants.MARKET_ROLE, deployer), "deployer never gets MARKET_ROLE");
        MarketDeployLib.assertHandoff(b, p);
        address[] memory missing = MarketDeployLib.missingMarketRole(b, p);
        assertEq(missing.length, 1, "exactly the registry is pending");
        assertEq(missing[0], address(registry));

        // Every parity module deployed and reachable.
        assertTrue(address(b.nameLocks).code.length > 0, "NameLocks not deployed");
        assertTrue(address(b.recordDelegate).code.length > 0, "RecordDelegate not deployed");
        assertTrue(address(b.textRecords).code.length > 0, "TextRecords not deployed");
        assertTrue(address(b.attestations).code.length > 0, "AttestationRegistry not deployed");
        assertTrue(address(b.integrators).code.length > 0, "IntegratorRegistry not deployed");
        assertTrue(address(b.vouchers).code.length > 0, "Vouchers not deployed");

        // Market points at the deployed NameLocks (WP-125 wiring); pauser and treasury are the governance
        // addresses; config landed as configured.
        assertEq(b.market.nameLocks(), address(b.nameLocks), "market not wired to NameLocks");
        assertTrue(b.market.hasRole(ArcNSConstants.PAUSER_ROLE, pauser), "pauser role");
        assertEq(b.market.treasury(), treasury, "treasury");
        IArcNSMarket.MarketConfig memory cfg = b.market.marketConfig();
        assertEq(cfg.feeBps, 200);
        assertEq(cfg.minBidIncrementBps, 500);
    }

    /// @dev The phase-3 assertion (`assertMarketRole`) is what still demands the grant — and names the
    ///      collection + market precisely — until the timelock op has executed; afterwards it passes.
    function test_assertMarketRole_failsBeforeGovernanceGrant_passesAfter() public {
        MarketDeployLib.Params memory p = _params();
        MarketDeployLib.Book memory b = _deploy(p);
        MarketDeployHarness harness = new MarketDeployHarness();

        vm.expectRevert(
            bytes(
                string.concat(
                    "MARKET_ROLE not granted on ",
                    vm.toString(address(registry)),
                    " to ArcNSMarket ",
                    vm.toString(address(b.market))
                )
            )
        );
        harness.assertMarketRole(b, p);

        // Governance (the timelock is HandleRegistry's admin) grants it — the phase-2 payload's effect.
        vm.prank(timelock);
        registry.grantRole(ArcNSConstants.MARKET_ROLE, address(b.market));
        harness.assertMarketRole(b, p);
        assertEq(MarketDeployLib.missingMarketRole(b, p).length, 0);
    }

    /// @dev `predict` is the CREATE2 book the script prints before broadcasting; it must equal what the
    ///      deploy produces, for all seven contracts.
    function test_predict_matchesDeployedAddresses() public {
        MarketDeployLib.Params memory p = _params();
        MarketDeployLib.Book memory predicted = MarketDeployLib.predict(p);
        MarketDeployLib.Book memory b = _deploy(p);
        assertEq(address(predicted.market), address(b.market), "market");
        assertEq(address(predicted.nameLocks), address(b.nameLocks), "nameLocks");
        assertEq(address(predicted.recordDelegate), address(b.recordDelegate), "recordDelegate");
        assertEq(address(predicted.textRecords), address(b.textRecords), "textRecords");
        assertEq(address(predicted.attestations), address(b.attestations), "attestations");
        assertEq(address(predicted.integrators), address(b.integrators), "integrators");
        assertEq(address(predicted.vouchers), address(b.vouchers), "vouchers");
        // Sanity: the prediction really is the standard CREATE2 formula over the Salts.
        assertEq(
            address(predicted.textRecords),
            vm.computeCreate2Address(Salts.forName("TextRecords"), keccak256(type(TextRecords).creationCode), deployer),
            "create2 formula"
        );
    }

    /// @dev Rerun with identical params after a completed run: nothing is redeployed, nothing is
    ///      re-wired (the deployer no longer holds admin on the market), the same book comes back and the
    ///      handoff still holds — the script is safe to re-execute after a broken RPC/`--resume`.
    function test_deployMarketStack_rerunAfterCompletionIsIdempotent() public {
        MarketDeployLib.Params memory p = _params();
        MarketDeployLib.Book memory first = _deploy(p);
        MarketDeployLib.Book memory second = _deploy(p);
        assertEq(address(first.market), address(second.market));
        assertEq(address(first.nameLocks), address(second.nameLocks));
        assertEq(address(first.vouchers), address(second.vouchers));
        MarketDeployLib.assertHandoff(second, p);
    }

    /// @dev Resume after a crash mid-way: some contracts already exist at their CREATE2 addresses (here:
    ///      NameLocks and TextRecords were created by an earlier attempt that died before the market);
    ///      the rerun reuses them, deploys the rest, wires and hands off.
    function test_deployMarketStack_resumesPartialDeploy() public {
        MarketDeployLib.Params memory p = _params();
        vm.startPrank(deployer);
        NameLocks earlyLocks = new NameLocks{salt: Salts.forName("NameLocks")}(deployer, 7 days);
        new TextRecords{salt: Salts.forName("TextRecords")}();
        vm.stopPrank();

        MarketDeployLib.Book memory b = _deploy(p);
        assertEq(address(b.nameLocks), address(earlyLocks), "existing NameLocks reused");
        assertEq(b.market.nameLocks(), address(earlyLocks), "market wired to the reused NameLocks");
        MarketDeployLib.assertHandoff(b, p);
        // The reused NameLocks was handed off too (its admin was still the deployer).
        assertFalse(earlyLocks.hasRole(0x00, deployer));
        assertTrue(earlyLocks.hasRole(0x00, timelock));
    }

    function test_deployMarketStack_revertsOnZeroGovernanceAddress() public {
        MarketDeployLib.Params memory p = _params();
        p.timelock = address(0);
        MarketDeployHarness harness = new MarketDeployHarness();
        vm.expectRevert(bytes("MarketDeployLib: zero addr"));
        harness.validate(p);
    }

    function test_deployMarketStack_revertsOnLengthMismatch() public {
        MarketDeployLib.Params memory p = _params();
        address[] memory oneCollection = new address[](1);
        oneCollection[0] = address(registry);
        p.collections = oneCollection;
        MarketDeployHarness harness = new MarketDeployHarness();
        vm.expectRevert(bytes("MarketDeployLib: length mismatch"));
        harness.validate(p);
    }

    function test_deployMarketStack_revertsOnZeroDeployer() public {
        MarketDeployLib.Params memory p = _params();
        p.create2Deployer = address(0);
        MarketDeployHarness harness = new MarketDeployHarness();
        vm.expectRevert(bytes("MarketDeployLib: zero deployer"));
        harness.validate(p);
    }

    /// @dev The market's own initial admin is the deployer (set inside `deployMarketStack`, then
    ///      handed off to the timelock in the same call) — proves the deployer window is transient,
    ///      never externally observable as a completed deploy with the deployer still holding admin.
    function test_deployMarketStack_deployerNeverEndsWithAdmin() public {
        MarketDeployLib.Params memory p = _params();
        MarketDeployLib.Book memory b = _deploy(p);
        bytes32 adminRole = b.market.DEFAULT_ADMIN_ROLE();
        assertFalse(b.market.hasRole(adminRole, deployer));
        assertTrue(b.market.hasRole(adminRole, timelock));
    }
}
