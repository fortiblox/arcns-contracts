// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Vanilla OZ ERC-721 stand-in for a TLD registrar (no `epochOf`/`isLocked`, unlike
///         `HandleRegistry`) — exercises `EpochGuard`'s degrade-gracefully path (owner-address
///         precision only, epoch sentinel 0) and the `INameLocks`-only lock path in market tests.
contract MockERC721 is ERC721 {
    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}
