// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IArcNSPriceOracle} from "../../../src/interfaces/IArcNSPriceOracle.sol";
import {HandleNormalize} from "../../../src/lib/HandleNormalize.sol";

/// @dev Minimal `IArcNSPriceOracle` for registry/controller tests: fixed quotes per namespace,
///      write-only-increment counters, controller/tokenizer gating. Curve maths is out of scope here
///      (the real oracle has its own suite); `quote` / `quoteTokenize` revert on non-canonical labels
///      like the real one.
contract MockOracle is IArcNSPriceOracle {
    struct Ns {
        address controller;
        address tokenizer;
        uint64 launchTs;
        uint64 totalSold;
        uint64 tokenized;
        bool initialised;
        uint256 priceWei;
        uint256 tokenizePriceWei;
    }

    mapping(bytes32 => Ns) internal _ns;
    uint256 public recordSaleCalls;
    uint256 public recordTokenizeCalls;
    mapping(address => TokenPriceConfig) internal _paymentTokens;

    // ---- test helpers -----------------------------------------------------------------------------

    function init(bytes32 namespaceId, address controller, address tokenizer, uint256 priceWei, uint256 tokenizeWei)
        external
    {
        Ns storage n = _ns[namespaceId];
        n.controller = controller;
        n.tokenizer = tokenizer;
        n.launchTs = uint64(block.timestamp);
        n.initialised = true;
        n.priceWei = priceWei;
        n.tokenizePriceWei = tokenizeWei;
        emit NamespaceInitialised(namespaceId, controller, tokenizer, uint64(block.timestamp));
    }

    function setPrice(bytes32 namespaceId, uint256 priceWei) external {
        _ns[namespaceId].priceWei = priceWei;
    }

    function setTokenizePrice(bytes32 namespaceId, uint256 priceWei) external {
        _ns[namespaceId].tokenizePriceWei = priceWei;
    }

    function totalSold(bytes32 namespaceId) external view returns (uint64) {
        return _ns[namespaceId].totalSold;
    }

    function tokenized(bytes32 namespaceId) external view returns (uint64) {
        return _ns[namespaceId].tokenized;
    }

    // ---- curve constants ---------------------------------------------------------------------------

    function START_BPS() external pure returns (uint16) {
        return 5000;
    }

    function STEP_BPS() external pure returns (uint16) {
        return 1250;
    }

    function STEP_COUNT() external pure returns (uint32) {
        return 500;
    }

    function STEP_SECS() external pure returns (uint32) {
        return 91 days;
    }

    // ---- pure helpers ------------------------------------------------------------------------------

    function tierIndex(uint256 len) external pure returns (uint256) {
        return len == 0 ? 0 : (len > 10 ? 9 : len - 1);
    }

    function rampBps(uint256 stepsElapsed) external pure returns (uint256) {
        uint256 bps = 5000 + 1250 * stepsElapsed;
        return bps > 10_000 ? 10_000 : bps;
    }

    function computePrice(uint256 ceilingWei, uint256 timeBps_, uint256 volumeBps_) external pure returns (uint256) {
        return ceilingWei * timeBps_ * volumeBps_ / 1e8;
    }

    // ---- views -------------------------------------------------------------------------------------

    function quote(bytes32 namespaceId, string calldata label) external view returns (uint256) {
        if (!HandleNormalize.isCanonical(label)) revert NotCanonicalLabel(label);
        Ns storage n = _ns[namespaceId];
        if (!n.initialised) revert NamespaceNotInitialised(namespaceId);
        return n.priceWei;
    }

    function quoteInToken(bytes32 namespaceId, string calldata label, address paymentToken)
        external
        view
        returns (uint256 price, bool supported)
    {
        if (!HandleNormalize.isCanonical(label)) revert NotCanonicalLabel(label);
        Ns storage n = _ns[namespaceId];
        if (!n.initialised) revert NamespaceNotInitialised(namespaceId);
        TokenPriceConfig storage cfg = _paymentTokens[paymentToken];
        if (!cfg.supported) return (0, false);
        return (n.priceWei * cfg.rateWad / 1e18, true);
    }

    function quoteTokenize(bytes32 namespaceId, string calldata label) external view returns (uint256) {
        if (!HandleNormalize.isCanonical(label)) revert NotCanonicalLabel(label);
        Ns storage n = _ns[namespaceId];
        if (!n.initialised) revert NamespaceNotInitialised(namespaceId);
        return n.tokenizePriceWei;
    }

    function timeBps(bytes32) external pure returns (uint256) {
        return 10_000;
    }

    function volumeBps(bytes32) external pure returns (uint256) {
        return 10_000;
    }

    function tokenizeVolumeBps(bytes32) external pure returns (uint256) {
        return 10_000;
    }

    function tiers(bytes32) external pure returns (uint256[10] memory t) {
        return t;
    }

    function tokenizeTiers(bytes32) external pure returns (uint256[10] memory t) {
        return t;
    }

    function namespaceInfo(bytes32 namespaceId) external view returns (NamespaceInfo memory) {
        Ns storage n = _ns[namespaceId];
        return NamespaceInfo({
            controller: n.controller,
            tokenizer: n.tokenizer,
            launchTs: n.launchTs,
            totalSold: n.totalSold,
            tokenized: n.tokenized,
            initialised: n.initialised
        });
    }

    // ---- counters ----------------------------------------------------------------------------------

    function recordSale(bytes32 namespaceId) external {
        Ns storage n = _ns[namespaceId];
        if (!n.initialised) revert NamespaceNotInitialised(namespaceId);
        if (msg.sender != n.controller) revert NotNamespaceController(namespaceId, msg.sender);
        n.totalSold += 1;
        recordSaleCalls++;
        emit SaleRecorded(namespaceId, n.totalSold);
    }

    function recordTokenize(bytes32 namespaceId) external {
        Ns storage n = _ns[namespaceId];
        if (!n.initialised) revert NamespaceNotInitialised(namespaceId);
        if (msg.sender != n.tokenizer) revert NotNamespaceTokenizer(namespaceId, msg.sender);
        n.tokenized += 1;
        recordTokenizeCalls++;
        emit TokenizeRecorded(namespaceId, n.tokenized);
    }

    // ---- governance (unused by these suites) -------------------------------------------------------

    function initNamespace(
        bytes32 namespaceId,
        address controller,
        address tokenizer,
        uint64 launchTs,
        uint256[10] calldata,
        uint256[10] calldata
    ) external {
        Ns storage n = _ns[namespaceId];
        if (n.initialised) revert NamespaceAlreadyInitialised(namespaceId);
        n.controller = controller;
        n.tokenizer = tokenizer;
        n.launchTs = launchTs;
        n.initialised = true;
        emit NamespaceInitialised(namespaceId, controller, tokenizer, launchTs);
    }

    function setTiers(bytes32 namespaceId, uint256[10] calldata ceilingWei) external {
        emit TiersUpdated(namespaceId, ceilingWei);
    }

    function setTokenizeTiers(bytes32 namespaceId, uint256[10] calldata ceilingWei) external {
        emit TokenizeTiersUpdated(namespaceId, ceilingWei);
    }

    function setController(bytes32 namespaceId, address controller, address tokenizer) external {
        _ns[namespaceId].controller = controller;
        _ns[namespaceId].tokenizer = tokenizer;
        emit ControllerChanged(namespaceId, controller, tokenizer);
    }

    function setPaymentToken(address paymentToken, bool supported, uint256 rateWad) external {
        if (paymentToken == address(0)) revert PaymentTokenZeroAddress();
        if (supported && rateWad == 0) revert PaymentTokenRateZero();
        uint256 storedRate = supported ? rateWad : 0;
        _paymentTokens[paymentToken] = TokenPriceConfig({supported: supported, rateWad: storedRate});
        emit PaymentTokenSet(paymentToken, supported, storedRate);
    }

    function paymentTokenConfig(address paymentToken) external view returns (bool supported, uint256 rateWad) {
        TokenPriceConfig storage cfg = _paymentTokens[paymentToken];
        return (cfg.supported, cfg.rateWad);
    }
}
