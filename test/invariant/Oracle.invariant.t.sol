// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ArcNSPriceOracle} from "../../src/pricing/ArcNSPriceOracle.sol";
import {ArcNSConstants} from "../../src/lib/ArcNSConstants.sol";

/// @dev Drives the oracle: sales / tokenizes as the authorised callers (and as strangers), tier
///      updates as the admin, and time warps. Ghosts: last-seen counters, decrement count, and any
///      unauthorised write that slipped through.
contract OracleHandler is Test {
    ArcNSPriceOracle public immutable oracle;
    address public immutable admin;
    bytes32[2] public ns;
    address[2] public controllers;
    address[2] public tokenizers;

    uint256 public calls;
    uint256 public sales;
    uint256 public tokenizes;
    uint256 public tierUpdates;
    uint256 public warps;
    uint256 public unauthorisedAccepted;
    uint256 public decrements;
    mapping(bytes32 => uint64) public lastSold;
    mapping(bytes32 => uint64) public lastTokenized;

    constructor(
        ArcNSPriceOracle oracle_,
        address admin_,
        bytes32[2] memory ns_,
        address[2] memory controllers_,
        address[2] memory tokenizers_
    ) {
        oracle = oracle_;
        admin = admin_;
        ns = ns_;
        controllers = controllers_;
        tokenizers = tokenizers_;
    }

    function recordSale(uint8 i) external {
        calls++;
        i = i % 2;
        _snapshot(i);
        vm.prank(controllers[i]);
        oracle.recordSale(ns[i]);
        sales++;
        _check(i);
    }

    function recordTokenize(uint8 i) external {
        calls++;
        i = i % 2;
        _snapshot(i);
        vm.prank(tokenizers[i]);
        oracle.recordTokenize(ns[i]);
        tokenizes++;
        _check(i);
    }

    /// @dev A random caller (including the other namespace's controller) must never move a counter.
    function recordAsStranger(uint8 i, address who, bool sale) external {
        calls++;
        i = i % 2;
        if (who == controllers[i] || who == tokenizers[i]) return;
        _snapshot(i);
        vm.prank(who);
        bool ok;
        if (sale) {
            try oracle.recordSale(ns[i]) {
                ok = true;
            } catch {}
        } else {
            try oracle.recordTokenize(ns[i]) {
                ok = true;
            } catch {}
        }
        if (ok) unauthorisedAccepted++;
        _check(i);
    }

    function setTiers(uint8 i, uint256 seed, bool tokenize) external {
        calls++;
        i = i % 2;
        uint256[10] memory t;
        for (uint256 k = 0; k < 10; k++) {
            t[k] = bound(uint256(keccak256(abi.encode(seed, k))), 0, 1_000_000e18);
        }
        _snapshot(i);
        vm.prank(admin);
        if (tokenize) oracle.setTokenizeTiers(ns[i], t);
        else oracle.setTiers(ns[i], t);
        tierUpdates++;
        _check(i);
    }

    function warp(uint32 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(uint256(dt), 0, 400 days));
        warps++;
    }

    function _snapshot(uint8 i) internal {
        lastSold[ns[i]] = oracle.namespaceInfo(ns[i]).totalSold;
        lastTokenized[ns[i]] = oracle.namespaceInfo(ns[i]).tokenized;
    }

    function _check(uint8 i) internal {
        if (oracle.namespaceInfo(ns[i]).totalSold < lastSold[ns[i]]) decrements++;
        if (oracle.namespaceInfo(ns[i]).tokenized < lastTokenized[ns[i]]) decrements++;
        lastSold[ns[i]] = oracle.namespaceInfo(ns[i]).totalSold;
        lastTokenized[ns[i]] = oracle.namespaceInfo(ns[i]).tokenized;
    }
}

/// @notice C6 invariants (pricing.md §4, T-REG-7): counters never decrease, price stays within
///         [25 %, 100 %] of the tier ceiling, only the namespace's controller / tokenizer write.
contract OracleInvariantTest is Test {
    uint256 internal constant LAUNCH = 1_757_000_000;

    address internal admin = makeAddr("timelock");
    ArcNSPriceOracle internal oracle;
    OracleHandler internal handler;
    bytes32[2] internal ns;

    function setUp() public {
        vm.warp(LAUNCH);
        oracle = new ArcNSPriceOracle(admin);
        ns = [ArcNSConstants.ARC_NODE, ArcNSConstants.HANDLE_ROOT];
        address[2] memory controllers = [makeAddr("arcController"), makeAddr("handleController")];
        address[2] memory tokenizers = [makeAddr("arcTokenizer"), makeAddr("handleRegistry")];
        uint256[10] memory tiers =
            [uint256(50_000e18), 5000e18, 500e18, 100e18, 20e18, 10e18, 10e18, 10e18, 10e18, 5e18];
        uint256[10] memory tok = [uint256(80e18), 60e18, 40e18, 12e18, 4e18, 3e18, 3e18, 3e18, 3e18, 2e18];
        vm.startPrank(admin);
        for (uint256 i = 0; i < 2; i++) {
            oracle.initNamespace(ns[i], controllers[i], tokenizers[i], uint64(LAUNCH), tiers, tok);
        }
        vm.stopPrank();
        handler = new OracleHandler(oracle, admin, ns, controllers, tokenizers);
        targetContract(address(handler));
    }

    function _label(uint256 len) internal pure returns (string memory) {
        bytes memory b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = "a";
        }
        return string(b);
    }

    function invariant_counters_never_decrease() public view {
        assertEq(handler.decrements(), 0);
        assertEq(handler.unauthorisedAccepted(), 0);
        for (uint256 i = 0; i < 2; i++) {
            assertGe(oracle.namespaceInfo(ns[i]).totalSold, handler.lastSold(ns[i]));
            assertGe(oracle.namespaceInfo(ns[i]).tokenized, handler.lastTokenized(ns[i]));
        }
    }

    function invariant_price_within_25_to_100_pct_of_ceiling() public view {
        uint256[8] memory lens = [uint256(1), 2, 3, 4, 5, 6, 10, 32];
        for (uint256 i = 0; i < 2; i++) {
            assertGe(oracle.timeBps(ns[i]), 5000);
            assertLe(oracle.timeBps(ns[i]), 10_000);
            assertGe(oracle.volumeBps(ns[i]), 5000);
            assertLe(oracle.volumeBps(ns[i]), 10_000);
            uint256[10] memory tiers = oracle.tiers(ns[i]);
            uint256[10] memory tok = oracle.tokenizeTiers(ns[i]);
            for (uint256 k = 0; k < lens.length; k++) {
                string memory label = _label(lens[k]);
                uint256 c = tiers[oracle.tierIndex(lens[k])];
                uint256 p = oracle.quote(ns[i], label);
                assertLe(p, c);
                assertGe(p, c / 4);
                uint256 ct = tok[oracle.tierIndex(lens[k])];
                uint256 pt = oracle.quoteTokenize(ns[i], label);
                assertLe(pt, ct);
                assertGe(pt, ct / 4);
            }
        }
    }

    function invariant_call_counters_are_consistent() public view {
        assertGe(handler.calls(), handler.sales() + handler.tokenizes() + handler.tierUpdates() + handler.warps());
    }

    function afterInvariant() public view {
        // A run that only reverted is a broken handler: the authorised paths must have succeeded.
        if (handler.calls() >= 32) {
            assertGt(handler.sales() + handler.tokenizes(), 0, "no successful counter write in a full run");
        }
    }
}
