// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

// Verbatim ens-contracts v1.7.0 (compiled against OZ 4.9.3 / OZ 5.1.0 through the
// `lib/ens-contracts/:` context remappings in remappings.txt).
import {ENS} from "@ensdomains/ens-contracts/registry/ENS.sol";
import {ENSRegistry} from "@ensdomains/ens-contracts/registry/ENSRegistry.sol";
import {Root} from "@ensdomains/ens-contracts/root/Root.sol";
import {BaseRegistrarImplementation} from "@ensdomains/ens-contracts/ethregistrar/BaseRegistrarImplementation.sol";
import {ReverseRegistrar} from "@ensdomains/ens-contracts/reverseRegistrar/ReverseRegistrar.sol";
import {DefaultReverseRegistrar} from "@ensdomains/ens-contracts/reverseRegistrar/DefaultReverseRegistrar.sol";
import {UniversalResolver} from "@ensdomains/ens-contracts/universalResolver/UniversalResolver.sol";
import {GatewayProvider} from "@ensdomains/ens-contracts/ccipRead/GatewayProvider.sol";
import {AddrResolver} from "@ensdomains/ens-contracts/resolvers/profiles/AddrResolver.sol";
import {NameResolver} from "@ensdomains/ens-contracts/resolvers/profiles/NameResolver.sol";
import {TextResolver} from "@ensdomains/ens-contracts/resolvers/profiles/TextResolver.sol";
import {ContentHashResolver} from "@ensdomains/ens-contracts/resolvers/profiles/ContentHashResolver.sol";
import {ResolverBase} from "@ensdomains/ens-contracts/resolvers/ResolverBase.sol";
import {Multicallable} from "@ensdomains/ens-contracts/resolvers/Multicallable.sol";
import {NameCoder} from "@ensdomains/ens-contracts/utils/NameCoder.sol";

// Our OpenZeppelin 5.6.1 in the same compilation unit (proves the dual-OZ remapping).
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {HandleNormalize} from "../../src/lib/HandleNormalize.sol";

/// @dev Minimal OZ-5.6.1 consumer so the v5 sources are actually compiled and deployed here.
contract Oz561Probe is ERC721, AccessControl, ReentrancyGuardTransient {
    constructor() ERC721("probe", "P") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function supportsInterface(bytes4 id) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(id);
    }

    function guarded() external nonReentrant returns (bool) {
        return true;
    }
}

/// @dev Minimal resolver composed from the verbatim ENS profiles (what C7 will grow into).
contract EnsProfilesProbe is AddrResolver, NameResolver, TextResolver, ContentHashResolver, Multicallable {
    ENS internal immutable ens;

    constructor(ENS _ens) {
        ens = _ens;
    }

    function isAuthorised(bytes32 node) internal view override returns (bool) {
        return ens.owner(node) == msg.sender;
    }

    function supportsInterface(bytes4 id)
        public
        view
        override(AddrResolver, NameResolver, TextResolver, ContentHashResolver, Multicallable)
        returns (bool)
    {
        return super.supportsInterface(id);
    }
}

/// @notice WP-101 build proof: the verbatim ENS stack (OZ 4.9.3 + OZ 5.1.0 via context remappings)
///         and our OZ 5.6.1 compile and deploy in one `forge build`, and the ENS node math agrees
///         with `HandleNormalize`.
contract EnsCompileTest is Test {
    ENSRegistry internal registry;
    Root internal root;
    BaseRegistrarImplementation internal arcRegistrar;
    ReverseRegistrar internal reverse;

    function setUp() public {
        // BaseRegistrar.available() needs `expiries + GRACE_PERIOD < now`; forge's default timestamp is 1.
        vm.warp(1_757_000_000);
        registry = new ENSRegistry();
        root = new Root(registry);
        arcRegistrar = new BaseRegistrarImplementation(registry, HandleNormalize.ARC_NODE);
        reverse = new ReverseRegistrar(registry);
        // Real ENS deploy order: `addr.reverse` is owned by the ReverseRegistrar before anything
        // (UniversalResolver, resolvers) claims a reverse record in its constructor.
        registry.setSubnodeOwner(bytes32(0), keccak256("reverse"), address(this));
        registry.setSubnodeOwner(HandleNormalize.tldNode("reverse"), keccak256("addr"), address(reverse));
    }

    function test_ens_registry_deploys_and_root_is_deployer() public view {
        assertEq(registry.owner(bytes32(0)), address(this));
        assertEq(address(root.ens()), address(registry));
        assertEq(arcRegistrar.baseNode(), HandleNormalize.ARC_NODE);
    }

    function test_root_owns_tld_and_registrar_mints_labelhash_token() public {
        registry.setOwner(bytes32(0), address(root));
        root.setController(address(this), true);
        root.setSubnodeOwner(keccak256("arc"), address(arcRegistrar));
        assertEq(registry.owner(HandleNormalize.ARC_NODE), address(arcRegistrar));

        arcRegistrar.addController(address(this));
        uint256 id = uint256(HandleNormalize.labelhash("alice"));
        arcRegistrar.register(id, address(0xA11CE), 365 days);
        assertEq(arcRegistrar.ownerOf(id), address(0xA11CE));
        // C4 semantics: registry owner of alice.arc follows the ERC-721 mint
        assertEq(registry.owner(HandleNormalize.labelNode("alice", HandleNormalize.ARC_NODE)), address(0xA11CE));
    }

    function test_reverse_registrar_and_default_reverse_use_oz4_and_oz5() public {
        // ReverseRegistrar (OZ 4.9.3 Ownable) — deployer is owner
        assertEq(reverse.owner(), address(this));
        // DefaultReverseRegistrar imports @openzeppelin/contracts-v5 (OZ 5.1.0 Ownable)
        DefaultReverseRegistrar drr = new DefaultReverseRegistrar();
        assertEq(drr.owner(), address(this));
    }

    function test_universal_resolver_and_profiles_compile() public {
        string[] memory urls = new string[](1);
        urls[0] = "https://ccip.arcns.io/{sender}/{data}"; // placeholder gateway; C9 wiring is WP-112
        GatewayProvider gw = new GatewayProvider(address(this), urls);
        UniversalResolver ur = new UniversalResolver(address(this), registry, gw);
        assertEq(address(ur.registry()), address(registry));
        assertEq(address(ur.batchGatewayProvider()), address(gw));
        EnsProfilesProbe r = new EnsProfilesProbe(registry);
        // ENSIP-1 addr(bytes32) and ENSIP-9 addr(bytes32,uint256) interface ids
        assertTrue(r.supportsInterface(0x3b3b57de));
        assertTrue(r.supportsInterface(0xf1cb7e06));
        // NameCoder round-trip on a canonical name
        bytes memory dns = NameCoder.encode("alice.arc");
        bytes32 node = NameCoder.namehash(dns, 0);
        assertEq(node, HandleNormalize.labelNode("alice", HandleNormalize.ARC_NODE));
    }

    function test_oz_5_6_1_compiles_and_deploys() public {
        Oz561Probe p = new Oz561Probe();
        assertTrue(p.hasRole(p.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(p.guarded());
        assertTrue(p.supportsInterface(0x80ac58cd)); // ERC-721
    }
}
