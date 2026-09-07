// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IArcNSPriceOracle — the X1 stacked curve per namespace (onchain-design §6, pricing.md §4)
/// @notice One shared oracle; state keyed by `namespaceId` (`HANDLE_ROOT`, `namehash("arc")`,
///         `namehash("circle")`, …). `price = ceiling[tier(len)] × timeBps/1e4 × volumeBps/1e4`.
///         Both ramps start at 5,000 bps, step 1,250 bps, cap 10,000; time step = 91 days from
///         `launchTs`, volume step = every 500 paid sales. Counters never decrement. Units: native wei
///         (1e18 = 1 USDC).
///
///         Genesis MUST NOT touch `totalSold` (CEO decision 6a): `recordSale` is called only by the
///         namespace controller on a paid registration, never on `registerReservedBatch`.
interface IArcNSPriceOracle {
    struct NamespaceInfo {
        address controller; // the only caller of recordSale (per namespace)
        address tokenizer; // the only caller of recordTokenize (HandleRegistry for `@handle`)
        uint64 launchTs;
        uint64 totalSold;
        uint64 tokenized;
        bool initialised;
    }

    event NamespaceInitialised(bytes32 indexed namespaceId, address controller, address tokenizer, uint64 launchTs);
    event TiersUpdated(bytes32 indexed namespaceId, uint256[10] ceilingWei);
    event TokenizeTiersUpdated(bytes32 indexed namespaceId, uint256[10] ceilingWei);
    event SaleRecorded(bytes32 indexed namespaceId, uint64 totalSold);
    event TokenizeRecorded(bytes32 indexed namespaceId, uint64 tokenized);
    event ControllerChanged(bytes32 indexed namespaceId, address controller, address tokenizer);

    error NamespaceNotInitialised(bytes32 namespaceId);
    error NamespaceAlreadyInitialised(bytes32 namespaceId);
    error NotNamespaceController(bytes32 namespaceId, address caller);
    error NotNamespaceTokenizer(bytes32 namespaceId, address caller);
    error NotCanonicalLabel(string label);

    // ---- curve constants (immutable by design so nobody can shorten the early bird retroactively)
    function START_BPS() external pure returns (uint16);
    function STEP_BPS() external pure returns (uint16);
    function STEP_COUNT() external pure returns (uint32);
    function STEP_SECS() external pure returns (uint32);

    // ---- pure helpers (X1 `tier_index`, `ramp_bps`, `compute_price` twins)
    function tierIndex(uint256 len) external pure returns (uint256);
    function rampBps(uint256 stepsElapsed) external pure returns (uint256);
    function computePrice(uint256 ceilingWei, uint256 timeBps, uint256 volumeBps) external pure returns (uint256);

    // ---- views
    function quote(bytes32 namespaceId, string calldata label) external view returns (uint256 priceWei);
    function quoteTokenize(bytes32 namespaceId, string calldata label) external view returns (uint256 priceWei);
    function timeBps(bytes32 namespaceId) external view returns (uint256);
    function volumeBps(bytes32 namespaceId) external view returns (uint256);
    function tokenizeVolumeBps(bytes32 namespaceId) external view returns (uint256);
    function tiers(bytes32 namespaceId) external view returns (uint256[10] memory);
    function tokenizeTiers(bytes32 namespaceId) external view returns (uint256[10] memory);
    function namespaceInfo(bytes32 namespaceId) external view returns (NamespaceInfo memory);

    // ---- counters (write-only-increment, restricted to the namespace's controller / tokenizer)
    function recordSale(bytes32 namespaceId) external;
    function recordTokenize(bytes32 namespaceId) external;

    // ---- governance (DEFAULT_ADMIN_ROLE = timelock)
    function initNamespace(
        bytes32 namespaceId,
        address controller,
        address tokenizer,
        uint64 launchTs,
        uint256[10] calldata ceilingWei,
        uint256[10] calldata tokenizeCeilingWei
    ) external;
    function setTiers(bytes32 namespaceId, uint256[10] calldata ceilingWei) external;
    function setTokenizeTiers(bytes32 namespaceId, uint256[10] calldata ceilingWei) external;
    function setController(bytes32 namespaceId, address controller, address tokenizer) external;
}
