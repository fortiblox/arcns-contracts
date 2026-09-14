// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarketScriptBase} from "./MarketScriptBase.sol";

/// @title NameGiftsScriptBase — address-book plumbing shared by the three `NameGifts` deploy scripts
/// @notice Same three-phase shape `MarketScriptBase` gives `ArcNSMarket` (`docs/runbooks/market-deploy.md`),
///         scoped to a `.nameGifts` object instead of `.market`:
///
///           input book   `_bookPath()` (inherited): ARCNS_ADDRESS_BOOK if set, else
///                        `deployments/<chainId>.dry-run.json` (ARCNS_DRY_RUN=1) or
///                        `deployments/<chainId>.json`.
///           market book  `.market` (inherited `_readMarketBook`): `NameGifts` reuses the
///                        already-deployed WP-125 `NameLocks` module from here rather than deploying a
///                        second one.
///           nameGifts book  `.nameGifts`: read from the input book when phase 1 broadcast, else from
///                        `deployments/<chainId>.nameGifts-dry-run.json` (a rehearsed phase 1 wrote it
///                        there) — never from anywhere else.
///           live write   only a real `forge script --broadcast` / `--resume` with ARCNS_DRY_RUN unset
///                        may touch the input book (`_isLiveWrite()`, inherited).
abstract contract NameGiftsScriptBase is MarketScriptBase {
    function _nameGiftsDryRunPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".nameGifts-dry-run.json");
    }

    function _nameGiftsGrantPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".nameGifts-grant.json");
    }

    /// @dev Returns the JSON holding the `.nameGifts` object and the path it came from (for the logs).
    function _readNameGiftsBook(string memory bookJson, string memory bookPath)
        internal
        view
        returns (string memory json, string memory path)
    {
        if (vm.keyExistsJson(bookJson, ".nameGifts")) return (bookJson, bookPath);
        path = _nameGiftsDryRunPath();
        require(
            vm.exists(path),
            string.concat(
                "nameGifts address book missing: no .nameGifts in ", bookPath, " and no ", path, " (run phase 1 first)"
            )
        );
        return (vm.readFile(path), path);
    }
}
