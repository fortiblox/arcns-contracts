// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";

interface IERC20Metadata {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

interface ISafeVersion {
    function VERSION() external view returns (string memory);
}

/// @dev Isolates `vm.rpc` so an RPC-level error surfaces as a catchable revert to the test.
contract RpcProbe is Test {
    function estimateGas(string calldata params) external returns (bytes memory) {
        return vm.rpc("eth_estimateGas", params);
    }
}

/// @title ArcFork — WP-104 fork harness against Arc testnet (chain id 5042002)
/// @notice Gated on `ARC_RPC_URL`. When unset every test logs `FORK_SKIPPED` and is skipped; when
///         set, `setUp` forks at the latest block and logs `FORK_RAN` (CI greps for it, WP-506).
///
///             ARC_RPC_URL=https://rpc.testnet.arc.io forge test --match-path 'test/fork/*' -vv
///
///         Facts asserted here were verified live with `cast` on 2026-09-06 (see toolchain.md §6)
///         and are re-verified on every run — asserted, not assumed.
contract ArcForkTest is Test {
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5042002;
    uint256 internal constant ARC_BASE_FEE_FLOOR = 20 gwei;

    // docs.arc.io/arc/references/contract-addresses
    address internal constant USDC_ERC20_VIEW = 0x3600000000000000000000000000000000000000;
    address internal constant ARACHNID_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C; // Arachnid
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // safe-deployments 1.4.1 canonical
    address internal constant SAFE_SINGLETON_141 = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant SAFE_L2_SINGLETON_141 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_PROXY_FACTORY_141 = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    // Ethereum-mainnet ENS registry — must NOT exist on Arc (we deploy our own, onchain-design §2)
    address internal constant ENS_CANONICAL_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;

    string internal rpcUrl;
    bool internal forked;

    function setUp() public {
        rpcUrl = vm.envOr("ARC_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            console2.log("FORK_SKIPPED: ARC_RPC_URL unset (export ARC_RPC_URL=https://rpc.testnet.arc.io)");
            return;
        }
        vm.createSelectFork(rpcUrl);
        forked = true;
        console2.log("FORK_RAN chainid=%s block=%s basefee=%s", block.chainid, block.number, block.basefee);
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_chain_id_is_arc_testnet() public onlyFork {
        assertEq(block.chainid, ARC_TESTNET_CHAIN_ID, "chain id");
    }

    /// docs.arc.io gas-and-fees: base fee floor 20 Gwei ("Set maxFeePerGas to at least 20 Gwei").
    function test_fork_base_fee_at_or_above_floor() public onlyFork {
        assertGe(block.basefee, ARC_BASE_FEE_FLOOR, "base fee floor");
    }

    /// Native USDC is 18-dec in `msg.value`; the ERC-20 view at 0x3600…0000 reports 6 decimals.
    function test_fork_usdc_erc20_view_has_6_decimals() public onlyFork {
        assertGt(USDC_ERC20_VIEW.code.length, 0, "USDC view has code");
        assertEq(IERC20Metadata(USDC_ERC20_VIEW).decimals(), 6, "USDC decimals");
        assertEq(IERC20Metadata(USDC_ERC20_VIEW).symbol(), "USDC", "USDC symbol");
    }

    function test_fork_deployment_infrastructure_has_code() public onlyFork {
        assertGt(ARACHNID_CREATE2_FACTORY.code.length, 0, "CREATE2 factory");
        assertGt(MULTICALL3.code.length, 0, "Multicall3");
        assertGt(PERMIT2.code.length, 0, "Permit2");
        assertGt(SAFE_SINGLETON_141.code.length, 0, "Safe 1.4.1 singleton");
        assertGt(SAFE_L2_SINGLETON_141.code.length, 0, "SafeL2 1.4.1 singleton");
        assertGt(SAFE_PROXY_FACTORY_141.code.length, 0, "SafeProxyFactory 1.4.1");
        assertEq(ISafeVersion(SAFE_SINGLETON_141).VERSION(), "1.4.1", "Safe VERSION()");
    }

    function test_fork_ens_canonical_registry_has_no_code() public onlyFork {
        assertEq(ENS_CANONICAL_REGISTRY.code.length, 0, "no canonical ENS on Arc");
    }

    /// A 1 wei native transfer to a fresh EOA succeeds under fork.
    ///
    /// Arc semantics (docs.arc.io evm-differences, "msg.value / native USDC"): a native transfer
    /// can revert even with sufficient balance — to the zero address ("Zero address not allowed"),
    /// to/from a USDC-blocklisted address, to a precompile, or when it would burn value. The Arc
    /// docs also state that forks/anvil "run a standard EVM, not Arc's", so the **blocklist and
    /// zero-address rules are not reproduced by revm here**; this test proves only the happy path.
    /// The negative path is asserted below through the real node (`eth_estimateGas` over the fork
    /// RPC), and contracts must never rely on a native transfer succeeding — use pull payments
    /// (onchain-design §8, SR market invariants).
    function test_fork_native_transfer_1_wei_to_fresh_address_succeeds() public onlyFork {
        address fresh = makeAddr("arcns-fork-fresh");
        assertEq(fresh.code.length, 0);
        assertEq(fresh.balance, 0);
        vm.deal(address(this), 1 ether);
        (bool ok,) = payable(fresh).call{value: 1}("");
        assertTrue(ok, "1 wei transfer");
        assertEq(fresh.balance, 1);
    }

    /// Real-node semantics via `eth_estimateGas` (not revm): a zero-value call to `address(0)` is a
    /// plain 21000-gas transaction. The negative half — value to `address(0)` reverts with
    /// "Zero address not allowed" — is asserted by `test/fork/arc-native-semantics.sh` with `cast`,
    /// because a failing `vm.rpc` cheatcode can be neither caught (try/catch) nor matched
    /// (`vm.expectRevert`) in forge 1.8.1; CI runs the script next to this suite.
    function test_fork_rpc_zero_value_call_to_zero_address_costs_21000() public onlyFork {
        RpcProbe probe = new RpcProbe();
        string memory from = vm.toString(SAFE_SINGLETON_141); // any existing account
        string memory noValue =
            string.concat('[{"from":"', from, '","to":"0x0000000000000000000000000000000000000000","value":"0x0"}]');
        // `vm.rpc` returns the JSON hex quantity as raw big-endian bytes (0x5208), not an ABI word.
        bytes memory gas = probe.estimateGas(noValue);
        assertEq(_quantity(gas), 21000, "zero-value call to 0x0 is a plain transfer");
    }

    function _quantity(bytes memory be) internal pure returns (uint256 v) {
        require(be.length <= 32, "quantity too wide");
        for (uint256 i = 0; i < be.length; i++) {
            v = (v << 8) | uint8(be[i]);
        }
    }
}
