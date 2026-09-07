// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IArcNSMarket} from "../../../src/interfaces/IArcNSMarket.sol";

/// @notice T-MKT-3 test double: a contract that reverts on receiving native value (a bidder/seller
///         "blocklisted for SELFDESTRUCT-adjacent reasons", or simply a wallet that reverts on
///         `receive()`). Every payout in `ArcNSMarket` is pull-based (SR-31), so this contract must
///         never be able to block a higher bid, a sale, or a settlement by being outbid, sold to, or
///         refunded — it can only ever fail to `withdraw()` its own credited balance.
contract RevertingBidder {
    error NopeNotAccepted();

    receive() external payable {
        revert NopeNotAccepted();
    }

    function approveAll(address collection, address operator) external {
        IERC721(collection).setApprovalForAll(operator, true);
    }

    function list(IArcNSMarket market, address collection, uint256 tokenId, uint256 price, uint40 expiresAt) external {
        market.list(collection, tokenId, price, expiresAt);
    }

    function startAuction(IArcNSMarket market, address collection, uint256 tokenId, uint256 reserve, uint32 duration)
        external
    {
        market.startAuction(collection, tokenId, reserve, duration);
    }

    function bid(IArcNSMarket market, address collection, uint256 tokenId, uint256 amount) external {
        market.placeBid{value: amount}(collection, tokenId);
    }

    function placeOffer(IArcNSMarket market, address collection, uint256 tokenId, uint256 amount, uint40 expiresAt)
        external
    {
        market.placeOffer{value: amount}(collection, tokenId, expiresAt);
    }

    function withdraw(IArcNSMarket market) external {
        market.withdraw();
    }
}
