// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @dev Plain ERC-721 standing in for a per-TLD BaseRegistrar (tokenId = labelhash).
contract MockTldRegistrar is ERC721 {
    constructor(string memory tld) ERC721(tld, tld) {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function burn(uint256 tokenId) external {
        _burn(tokenId);
    }
}
