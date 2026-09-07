// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IArcNSPriceOracle} from "../../src/interfaces/IArcNSPriceOracle.sol";

import {ArcNSMarket} from "../../src/market/ArcNSMarket.sol";
import {IArcNSMarket} from "../../src/interfaces/IArcNSMarket.sol";
import {HandleRegistry} from "../../src/handle/HandleRegistry.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";
import {MockOracle} from "../handle/mocks/MockOracle.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MockNameLocks} from "./mocks/MockNameLocks.sol";
import {RevertingBidder} from "./mocks/RevertingBidder.sol";

/// @notice Shared setup for `ArcNSMarket` (WP-119/120/121/122) tests: one `HandleRegistry` (C1, the
///         native-lock/epoch collection — `MARKET_ROLE` granted so `transferFrom` bypasses the
///         soulbound rule per HandleRegistry's `_update`) and one `MockERC721` (a TLD-registrar stand
///         in — no `epochOf`/`isLocked`, guarded only by the parity `MockNameLocks`).
abstract contract MarketFixture is Test {
    uint256 internal constant T0 = 1_800_000_000;
    uint16 internal constant FEE_BPS = 250; // 2.5%
    uint16 internal constant MIN_BID_INCREMENT_BPS = 500; // 5%
    uint32 internal constant ANTI_SNIPE_WINDOW = 300;
    uint32 internal constant ANTI_SNIPE_EXTEND = 300;
    uint96 internal constant MIN_PRICE = 1e12; // dust floor

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal treasury = makeAddr("treasury");
    address internal registrar = makeAddr("registrar");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal bidder1 = makeAddr("bidder1");
    address internal bidder2 = makeAddr("bidder2");
    address internal bidder3 = makeAddr("bidder3");
    address internal stranger = makeAddr("stranger");
    address internal offerer1 = makeAddr("offerer1");
    address internal offerer2 = makeAddr("offerer2");

    ArcNSMarket internal market;
    HandleRegistry internal registry;
    MockOracle internal oracle;
    MockERC721 internal tld;
    MockNameLocks internal nameLocks;
    RevertingBidder internal revertingBidder;

    uint256 internal aliceHandleId;
    uint256 internal constant TLD_TOKEN_ID = 1;

    function setUp() public virtual {
        vm.warp(T0);

        oracle = new MockOracle();
        registry = new HandleRegistry(admin, treasury, IArcNSPriceOracle(address(oracle)), 7 days);
        oracle.init(ArcNSConstants.HANDLE_ROOT, registrar, address(registry), 5e18, 2e18);

        tld = new MockERC721("Mock TLD", "MTLD");
        nameLocks = new MockNameLocks(admin);
        revertingBidder = new RevertingBidder();

        market = new ArcNSMarket(
            ArcNSMarket.Init({
                admin: admin,
                pauser: pauser,
                treasury: treasury,
                nameLocks: address(nameLocks),
                config: _defaultConfig()
            })
        );

        vm.startPrank(admin);
        registry.grantRole(ArcNSConstants.MARKET_ROLE, address(market));
        registry.grantRole(ArcNSConstants.REGISTRAR_ROLE, registrar);
        market.setCollectionAllowed(address(registry), true);
        market.setCollectionAllowed(address(tld), true);
        vm.stopPrank();

        vm.prank(registrar);
        aliceHandleId = registry.register("alice", seller, uint8(IHandleRegistry.HandleType.Human), false);

        tld.mint(seller, TLD_TOKEN_ID);

        vm.deal(seller, 1000e18);
        vm.deal(buyer, 1000e18);
        vm.deal(bidder1, 1000e18);
        vm.deal(bidder2, 1000e18);
        vm.deal(bidder3, 1000e18);
        vm.deal(stranger, 1000e18);
        vm.deal(offerer1, 1000e18);
        vm.deal(offerer2, 1000e18);
        vm.deal(address(revertingBidder), 1000e18);
    }

    function _defaultConfig() internal pure returns (IArcNSMarket.MarketConfig memory) {
        return IArcNSMarket.MarketConfig({
            feeBps: FEE_BPS,
            minBidIncrementBps: MIN_BID_INCREMENT_BPS,
            antiSnipeWindow: ANTI_SNIPE_WINDOW,
            antiSnipeExtend: ANTI_SNIPE_EXTEND,
            minPrice: MIN_PRICE
        });
    }

    /// @dev Approves the market as an operator for `who` on `collection`.
    function _approveMarket(address collection, address who) internal {
        vm.prank(who);
        IERC721(collection).setApprovalForAll(address(market), true);
    }

    function _list(address collection, uint256 tokenId, address seller_, uint256 price, uint40 expiresAt) internal {
        vm.prank(seller_);
        market.list(collection, tokenId, price, expiresAt);
    }

    function _startAuction(address collection, uint256 tokenId, address seller_, uint256 reserve, uint32 duration)
        internal
    {
        vm.prank(seller_);
        market.startAuction(collection, tokenId, reserve, duration);
    }
}
