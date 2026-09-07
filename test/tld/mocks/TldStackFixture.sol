// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

// Verbatim ens-contracts v1.7.0 (OZ 4.9.3 through the context remapping).
import {ENSRegistry} from "@ensdomains/ens-contracts/registry/ENSRegistry.sol";
import {Root} from "@ensdomains/ens-contracts/root/Root.sol";
import {ReverseRegistrar} from "@ensdomains/ens-contracts/reverseRegistrar/ReverseRegistrar.sol";

import {ArcNSPriceOracle} from "../../../src/pricing/ArcNSPriceOracle.sol";
import {TldDirectory} from "../../../src/tld/TldDirectory.sol";
import {TldMetadata} from "../../../src/tld/TldMetadata.sol";
import {TldRegistrar} from "../../../src/tld/TldRegistrar.sol";
import {TldRegistrarController} from "../../../src/tld/TldRegistrarController.sol";
import {ITldRegistrarController} from "../../../src/interfaces/ITldRegistrarController.sol";
import {HandleNormalize} from "../../../src/lib/HandleNormalize.sol";
import {MockResolver} from "./MockResolver.sol";

/// @notice The full TLD stack: ONE ENSRegistry / Root / ReverseRegistrar / TldDirectory /
///         ArcNSPriceOracle / TldMetadata / MockResolver, plus one `(TldRegistrar, Controller)` pair
///         per TLD created by `_addTld(label)` — the exact sequence `script/AddTld.s.sol` mirrors
///         (onchain-design §2: "TLDs are data").
abstract contract TldStackFixture is Test {
    struct Pair {
        TldRegistrar registrar;
        TldRegistrarController controller;
        bytes32 node;
        string label;
    }

    uint256 internal constant WARP = 1_757_000_000;
    uint256 internal constant MIN_AGE = 60;
    uint256 internal constant MAX_AGE = 24 hours;
    uint256 internal constant USDC = 1e18;

    address internal admin = makeAddr("timelock");
    address internal pauser = makeAddr("adminSafe");
    address internal genesis = makeAddr("genesisAdmin");
    address internal treasury = makeAddr("treasurySafe");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    ENSRegistry internal registry;
    Root internal root;
    ReverseRegistrar internal reverse;
    TldDirectory internal directory;
    ArcNSPriceOracle internal oracle;
    MockResolver internal resolver;
    TldMetadata internal metadata;

    Pair internal arc;
    Pair internal circle;

    /// @dev pricing.md §3 Model A `.arc` ceilings (USDC × 1e18): handle table × 0.5.
    function _tldTiers() internal pure returns (uint256[10] memory t) {
        uint256[10] memory usdc = [uint256(50_000), 5000, 500, 100, 20, 10, 10, 10, 10, 5];
        for (uint256 i = 0; i < 10; i++) {
            t[i] = usdc[i] * USDC;
        }
    }

    function _zeroTiers() internal pure returns (uint256[10] memory t) {}

    /// @dev Shared contracts, deployed once. Real ENS deploy order: `addr.reverse` is owned by the
    ///      ReverseRegistrar before anything claims a reverse record; the ENS root is handed to `Root`.
    function _deployShared() internal {
        vm.warp(WARP);
        registry = new ENSRegistry();
        root = new Root(registry);
        reverse = new ReverseRegistrar(registry);
        registry.setSubnodeOwner(bytes32(0), keccak256("reverse"), address(this));
        registry.setSubnodeOwner(HandleNormalize.tldNode("reverse"), keccak256("addr"), address(reverse));
        registry.setOwner(bytes32(0), address(root));
        root.setController(address(this), true);

        directory = new TldDirectory(admin, pauser);
        oracle = new ArcNSPriceOracle(admin);
        resolver = new MockResolver(registry, directory, address(reverse));
        metadata = new TldMetadata(directory);
        reverse.setDefaultResolver(address(resolver));
    }

    /// @dev `script/AddTld.s.sol` pattern: deploy the pair, hand the TLD node to the registrar, wire
    ///      the controller, register the row and the oracle namespace. No shared contract changes.
    function _addTld(string memory label) internal returns (Pair memory p) {
        bytes32 node = HandleNormalize.tldNode(label);
        TldRegistrar reg = new TldRegistrar(registry, node, label, address(metadata), address(this));
        TldRegistrarController ctl = new TldRegistrarController(
            TldRegistrarController.Init({
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
                minCommitmentAge: MIN_AGE,
                maxCommitmentAge: MAX_AGE,
                tld: label
            })
        );
        root.setSubnodeOwner(keccak256(bytes(label)), address(reg));
        reg.addController(address(ctl));
        reg.transferOwnership(admin);
        reverse.setController(address(ctl), true);

        vm.startPrank(admin);
        directory.add(node, label, address(reg), address(ctl), node);
        oracle.initNamespace(node, address(ctl), address(0), uint64(WARP), _tldTiers(), _zeroTiers());
        vm.stopPrank();

        p = Pair({registrar: reg, controller: ctl, node: node, label: label});
    }

    /// @dev Reserve `labels` in `p` and seal it (genesis role renounced inside `sealGenesis`).
    function _genesis(Pair memory p, string[] memory labels, bytes32 merkleRoot) internal {
        vm.startPrank(genesis);
        if (labels.length > 0) p.controller.registerReservedBatch(labels);
        p.controller.sealGenesis(merkleRoot);
        vm.stopPrank();
    }

    function _seal(Pair memory p) internal {
        _genesis(p, new string[](0), bytes32(0));
    }

    function _labelhash(string memory label) internal pure returns (bytes32) {
        return keccak256(bytes(label));
    }

    function _node(Pair memory p, string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(p.node, _labelhash(label)));
    }

    function _registration(string memory label, address owner, bytes32 secret, address res, bool reverseRecord)
        internal
        pure
        returns (ITldRegistrarController.Registration memory r)
    {
        r.label = label;
        r.owner = owner;
        r.secret = secret;
        r.resolver = res;
        r.data = new bytes[](0);
        r.reverseRecord = reverseRecord;
    }

    /// @dev commit as `who`, then warp past `minCommitmentAge`.
    function _commitAndWait(Pair memory p, ITldRegistrarController.Registration memory r, address who)
        internal
        returns (bytes32 commitment)
    {
        commitment = p.controller.makeCommitment(r);
        vm.prank(who);
        p.controller.commit(commitment);
        vm.warp(block.timestamp + MIN_AGE);
    }

    /// @dev Full happy path as `who`: commit, wait, register at the quoted price.
    function _register(Pair memory p, ITldRegistrarController.Registration memory r, address who)
        internal
        returns (uint256 price)
    {
        _commitAndWait(p, r, who);
        price = p.controller.quote(r.label);
        vm.deal(who, who.balance + price);
        vm.prank(who);
        p.controller.register{value: price}(r, price);
    }
}
