// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IArcNSPriceOracle} from "../interfaces/IArcNSPriceOracle.sol";
import {HandleNormalize} from "../lib/HandleNormalize.sol";

/// @title ArcNSPriceOracle — C6, the X1 stacked (time × volume) curve, one namespace per `namespaceId`
/// @notice Byte-for-byte port of `x1-handles/programs/x1-handles/src/lib.rs` (`ramp_bps`,
///         `quarters_elapsed`, `compute_price`, `price_now`, `nft_mint_price_now`, `tier_index`)
///         with `u128` arithmetic replaced by `uint256` (onchain-design §6, pricing.md §1/§4).
///
///         `price = ceiling[tierIndex(len)] × timeBps/1e4 × volumeBps/1e4`. Both ramps start at
///         `START_BPS` (50 %), rise `STEP_BPS` (12.5 pp) per step and cap at 100 %. Time steps are
///         `STEP_SECS` (91 days) since `launchTs`; volume steps are every `STEP_COUNT` (500) paid
///         sales. The ramp constants are compile-time constants so nobody — not even the timelock —
///         can shorten the early bird retroactively. Counters only ever increase (X1 invariant).
///
///         Genesis MUST NOT touch `totalSold` (pricing.md §8, CEO decision 6a): `recordSale` is
///         callable only by the namespace controller, which calls it solely on a paid registration.
contract ArcNSPriceOracle is AccessControl, IArcNSPriceOracle {
    /// @inheritdoc IArcNSPriceOracle
    uint16 public constant START_BPS = 5000;
    /// @inheritdoc IArcNSPriceOracle
    uint16 public constant STEP_BPS = 1250;
    /// @inheritdoc IArcNSPriceOracle
    uint32 public constant STEP_COUNT = 500;
    /// @inheritdoc IArcNSPriceOracle
    uint32 public constant STEP_SECS = 91 days;

    /// @dev Full price in basis points.
    uint256 private constant FULL_BPS = 10_000;
    /// @dev Number of steps after which a ramp is saturated: (10000 - 5000) / 1250 = 4.
    uint256 private constant SATURATION_STEPS = (FULL_BPS - START_BPS) / STEP_BPS;

    mapping(bytes32 namespaceId => NamespaceInfo) private _info;
    mapping(bytes32 namespaceId => uint256[10]) private _tiers;
    mapping(bytes32 namespaceId => uint256[10]) private _tokenizeTiers;

    /// @param admin holder of `DEFAULT_ADMIN_ROLE` (the timelock).
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---------------------------------------------------------------------------------------------
    // Pure helpers (X1 twins)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSPriceOracle
    /// @dev X1 `tier_index`: `len.clamp(1, 10) - 1`. Degenerate `0` maps to band 0, never out of bounds.
    function tierIndex(uint256 len) public pure returns (uint256) {
        if (len < 1) len = 1;
        if (len > 10) len = 10;
        return len - 1;
    }

    /// @inheritdoc IArcNSPriceOracle
    /// @dev X1 `ramp_bps`: `min(START + STEP × steps, 10000)`. Saturates without overflow for any input.
    function rampBps(uint256 stepsElapsed) public pure returns (uint256) {
        if (stepsElapsed >= SATURATION_STEPS) return FULL_BPS;
        return uint256(START_BPS) + uint256(STEP_BPS) * stepsElapsed;
    }

    /// @inheritdoc IArcNSPriceOracle
    /// @dev X1 `compute_price` in uint256: `ceiling × timeBps × volumeBps / 1e4 / 1e4`.
    ///      A `type(uint64).max` ceiling at both ramps 100 % returns exactly the ceiling.
    function computePrice(uint256 ceilingWei, uint256 timeBps_, uint256 volumeBps_) public pure returns (uint256) {
        return ceilingWei * timeBps_ * volumeBps_ / FULL_BPS / FULL_BPS;
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSPriceOracle
    function quote(bytes32 namespaceId, string calldata label) external view returns (uint256 priceWei) {
        NamespaceInfo storage n = _requireInitialised(namespaceId);
        if (!HandleNormalize.isCanonical(label)) revert NotCanonicalLabel(label);
        uint256 ceiling = _tiers[namespaceId][tierIndex(bytes(label).length)];
        return computePrice(ceiling, _timeBps(n), rampBps(uint256(n.totalSold) / STEP_COUNT));
    }

    /// @inheritdoc IArcNSPriceOracle
    /// @dev X1 `nft_mint_price_now`: same time ramp, own tier table, own volume counter.
    function quoteTokenize(bytes32 namespaceId, string calldata label) external view returns (uint256 priceWei) {
        NamespaceInfo storage n = _requireInitialised(namespaceId);
        if (!HandleNormalize.isCanonical(label)) revert NotCanonicalLabel(label);
        uint256 ceiling = _tokenizeTiers[namespaceId][tierIndex(bytes(label).length)];
        return computePrice(ceiling, _timeBps(n), rampBps(uint256(n.tokenized) / STEP_COUNT));
    }

    /// @inheritdoc IArcNSPriceOracle
    function timeBps(bytes32 namespaceId) external view returns (uint256) {
        return _timeBps(_info[namespaceId]);
    }

    /// @inheritdoc IArcNSPriceOracle
    function volumeBps(bytes32 namespaceId) external view returns (uint256) {
        return rampBps(uint256(_info[namespaceId].totalSold) / STEP_COUNT);
    }

    /// @inheritdoc IArcNSPriceOracle
    function tokenizeVolumeBps(bytes32 namespaceId) external view returns (uint256) {
        return rampBps(uint256(_info[namespaceId].tokenized) / STEP_COUNT);
    }

    /// @inheritdoc IArcNSPriceOracle
    function tiers(bytes32 namespaceId) external view returns (uint256[10] memory) {
        return _tiers[namespaceId];
    }

    /// @inheritdoc IArcNSPriceOracle
    function tokenizeTiers(bytes32 namespaceId) external view returns (uint256[10] memory) {
        return _tokenizeTiers[namespaceId];
    }

    /// @inheritdoc IArcNSPriceOracle
    function namespaceInfo(bytes32 namespaceId) external view returns (NamespaceInfo memory) {
        return _info[namespaceId];
    }

    // ---------------------------------------------------------------------------------------------
    // Counters (write-only-increment)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSPriceOracle
    function recordSale(bytes32 namespaceId) external {
        NamespaceInfo storage n = _requireInitialised(namespaceId);
        if (msg.sender != n.controller) revert NotNamespaceController(namespaceId, msg.sender);
        n.totalSold += 1;
        emit SaleRecorded(namespaceId, n.totalSold);
    }

    /// @inheritdoc IArcNSPriceOracle
    function recordTokenize(bytes32 namespaceId) external {
        NamespaceInfo storage n = _requireInitialised(namespaceId);
        if (msg.sender != n.tokenizer) revert NotNamespaceTokenizer(namespaceId, msg.sender);
        n.tokenized += 1;
        emit TokenizeRecorded(namespaceId, n.tokenized);
    }

    // ---------------------------------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IArcNSPriceOracle
    function initNamespace(
        bytes32 namespaceId,
        address controller,
        address tokenizer,
        uint64 launchTs,
        uint256[10] calldata ceilingWei,
        uint256[10] calldata tokenizeCeilingWei
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        NamespaceInfo storage n = _info[namespaceId];
        if (n.initialised) revert NamespaceAlreadyInitialised(namespaceId);
        n.controller = controller;
        n.tokenizer = tokenizer;
        n.launchTs = launchTs;
        n.initialised = true;
        _tiers[namespaceId] = ceilingWei;
        _tokenizeTiers[namespaceId] = tokenizeCeilingWei;
        emit NamespaceInitialised(namespaceId, controller, tokenizer, launchTs);
        emit TiersUpdated(namespaceId, ceilingWei);
        emit TokenizeTiersUpdated(namespaceId, tokenizeCeilingWei);
    }

    /// @inheritdoc IArcNSPriceOracle
    function setTiers(bytes32 namespaceId, uint256[10] calldata ceilingWei) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireInitialised(namespaceId);
        _tiers[namespaceId] = ceilingWei;
        emit TiersUpdated(namespaceId, ceilingWei);
    }

    /// @inheritdoc IArcNSPriceOracle
    function setTokenizeTiers(bytes32 namespaceId, uint256[10] calldata ceilingWei)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _requireInitialised(namespaceId);
        _tokenizeTiers[namespaceId] = ceilingWei;
        emit TokenizeTiersUpdated(namespaceId, ceilingWei);
    }

    /// @inheritdoc IArcNSPriceOracle
    function setController(bytes32 namespaceId, address controller, address tokenizer)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        NamespaceInfo storage n = _requireInitialised(namespaceId);
        n.controller = controller;
        n.tokenizer = tokenizer;
        emit ControllerChanged(namespaceId, controller, tokenizer);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev X1 `quarters_elapsed`: saturates at 0 when the clock is before `launchTs`.
    function _timeBps(NamespaceInfo storage n) private view returns (uint256) {
        uint256 launch = n.launchTs;
        uint256 steps = block.timestamp < launch ? 0 : (block.timestamp - launch) / STEP_SECS;
        return rampBps(steps);
    }

    function _requireInitialised(bytes32 namespaceId) private view returns (NamespaceInfo storage n) {
        n = _info[namespaceId];
        if (!n.initialised) revert NamespaceNotInitialised(namespaceId);
    }
}
