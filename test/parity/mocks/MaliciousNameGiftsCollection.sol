// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {NameGifts} from "../../../src/parity/NameGifts.sol";

/// @dev A hostile allow-listed collection whose `transferFrom` calls back into `NameGifts` before
///      completing the transfer — the only way to exercise `NameGifts`'s `nonReentrant` guards, since
///      neither real gift collection (`HandleRegistry`, `TldRegistrar`) ever invokes an
///      `onERC721Received`-style callback on a plain `transferFrom` (see the reentrancy test's own
///      NatSpec in `NameGifts.t.sol` for why). `nonReentrant` must turn the reentrant call below into
///      `ReentrancyGuardReentrantCall`, which — un-caught — bubbles straight back out through this
///      `transferFrom` and through the outer `NameGifts.claim`/`refund` call that triggered it.
contract MaliciousNameGiftsCollection is ERC721 {
    enum Reentry {
        None,
        Claim,
        Refund
    }

    NameGifts internal target;
    uint256 internal armedGiftId;
    Reentry internal reentry;

    constructor() ERC721("Evil", "EVIL") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function arm(NameGifts target_, uint256 giftId, Reentry reentry_) external {
        target = target_;
        armedGiftId = giftId;
        reentry = reentry_;
    }

    function transferFrom(address from, address to, uint256 tokenId) public override {
        if (reentry == Reentry.Claim) {
            reentry = Reentry.None; // one-shot: only the pull-from-escrow leg re-enters
            target.claim(armedGiftId);
        } else if (reentry == Reentry.Refund) {
            reentry = Reentry.None;
            target.refund(armedGiftId);
        }
        super.transferFrom(from, to, tokenId);
    }
}
