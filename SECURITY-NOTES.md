# SECURITY-NOTES — static-analysis triage (WP-117)

Gate: `contracts/ci/slither.sh` runs slither **0.11.3** over `src/` only (`slither.config.json`: `filter_paths`
= `lib/|test/|script/`, `fail_on: medium`, optimisation detectors off) and prints `SLITHER_CLEAN` /
`SLITHER_FAILED`. The verbatim libraries carry their upstream audits and are excluded. Every High/Medium
finding must be fixed in code or triaged here with a call-path reason and an inline
`// slither-disable-next-line <detector>` directly above the flagged statement (same discipline as the OSV
allowlist). Run 2026-09-07 on the M1 tree: **0 High, 0 Medium**, 33 Low, 27 Informational.

Addendum, WP #7772 (`HandleControllerV2`/`TldRegistrarControllerV2`, 2026-09-12): one new Medium
(`reentrancy-eth`, triaged inline below) plus the same Low/Informational classes already accepted above
(`timestamp`, `reentrancy-benign`/`reentrancy-events`, `calls-loop`, `low-level-calls`) recurring on the
two new contracts for the identical, already-reviewed reasons — commit-reveal age comparisons, the
registrar/oracle calls preceding the treasury push under `nonReentrant`, the bounded genesis-batch loop,
and the deliberate `call{value:}` pull-ledger pattern. No new Low/Informational class was introduced.

## Medium findings fixed in code

| Detector | Where | Resolution |
|---|---|---|
| `uninitialized-local` (5) | `HandleRegistry._update.reason`, `HandleController.registerReservedBatch.minted`, `TldRegistrarController.registerReservedBatch.minted`, `PrimaryNameLib.parse.node`, `ExtendedResolverV._decodeName.offset` | explicit initialisers (`= REASON_MINT`, `= 0`, `= bytes32(0)`); behaviour unchanged |

## Medium findings triaged inline (false positives with a stated reason)

| Detector | Where | Why it is not a defect |
|---|---|---|
| `locked-ether` (1, WP-125 `NameGifts.sol`) | `NameGifts.receive`/`NameGifts.fallback` (both `payable`, both unconditionally `revert ValueNotAccepted()`) | `NameGifts` custodies only NFTs (never ether) and, unlike `Vouchers.sol`/`ArcNSMarket.sol`, has no `withdraw()` — those two contracts avoid this same detector only because each has an unrelated pull-ledger `withdraw()` elsewhere in the contract, not because their `receive()`/`fallback()` differ from `NameGifts`'s (all three revert unconditionally, byte for byte). Slither's `locked-ether` check is satisfied by the mere presence of *some* function that can move ether out, regardless of whether the flagged payable function itself could ever actually receive any — it cannot see that `revert ValueNotAccepted()` makes the two flagged functions structurally unable to receive ether in the first place, so no `withdraw()` is needed and none was added. |
| `incorrect-equality` (2) | `HandleController._consumeCommitment`, `TldRegistrarController._consumeCommitment`: `commitmentTimestamp == 0` | `0` is the "never committed" sentinel written by `delete commitments[c]`; it is compared against a stored value, never a computed one. Verbatim ENS `ETHRegistrarController` v1.7.0 logic. |
| `unused-return` (2) | `TldRegistrarController._registerWithResolver`: `multicallWithNodeCheck` (returns `bytes[]`), `setNameForAddr` (returns the reverse node) | The return payloads carry no decision-relevant data for the controller (node check reverts on mismatch; the reverse node is derivable from `msg.sender`). ENS v1.7.0 discards both as well. |
| `arbitrary-send-erc20` (3, #7611) | `ArcNSMarket.buy` (`transferFrom(l.seller, msg.sender, tokenId)`), `ArcNSMarket.settleAuction` (`transferFrom(a.seller, a.highestBidder, tokenId)`), `ArcNSMarket._tryBuyOne` (`transferFrom(l.seller, msg.sender, tokenId)`, called only from `batchBuy`) | `l.seller`/`a.seller`/`a.highestBidder` are read from validated `Listing`/`Auction` storage, gated by `if (l.seller == address(0)) revert NotListed(...)` / `if (a.seller == address(0)) revert NoActiveAuction(...)` before any of the three functions reaches the transfer, and each additionally re-verifies current `ownerOf`/epoch/lock state against that same `seller` immediately before the call (SR-30/T-MKT-1). `_tryBuyOne` is the same guarded pattern as `buy`, just reached through `batchBuy`'s loop instead of directly. Never arbitrary caller input — slither's detector cannot see the guards a few lines above. (Slither's own wiki page for this check is titled "arbitrary-from-in-transferfrom"; the CLI/disable-comment id is `arbitrary-send-erc20`.) |
| `reentrancy-no-eth` (1, M3, #7611) | `ArcNSMarket.batchBuy`: `withdrawable[msg.sender] += remaining` (unspent-value refund) is written after the per-item loop, which makes external calls via `_tryBuyOne`'s `transferFrom` | `batchBuy` carries `nonReentrant` (transient) over the ENTIRE call, including the loop and this final credit, so no reentrant call can observe or act on intermediate state — the class of bug this detector exists to catch is already structurally impossible here, not merely mitigated. The write also cannot be hoisted before the loop: `remaining` (how much of `msg.value` was never charged to a successful item) is only known once every item has been attempted, since each item's success/failure — and therefore whether it consumes value — depends on live-state re-validation (`EpochGuard.stillValid`, lock, price, expiry, and now, per the #7611 approval-revocation fix, the `transferFrom` outcome itself) performed inside that same loop. Moving it earlier would require a full two-pass rewrite (validate and price every item first, then transfer) — a materially larger and riskier restructuring of the core settlement loop for a path that is already reentrancy-safe by construction. Same reasoning class as the `reentrancy-benign`/`reentrancy-events` row below, one severity notch up because slither's `no-eth` variant additionally flags the *value* of the write, not just its timing relative to events. |
| `unused-return` (1, M3) | `AttestationRegistry.attest`: `(signer, err,) = ECDSA.tryRecover(digest, signature)` | The discarded third tuple element is this OZ `tryRecover` overload's recovered-digest-length slot, not a second error signal. `err` — the actual thing that needs checking — IS checked on the very next line (`if (err != ECDSA.RecoverError.NoError) revert InvalidSignature()`). |
| `reentrancy-eth` (1, WP #7772) | `TldRegistrarControllerV2._settle`: `withdrawable[msg.sender] += change` (overpayment credit) is written after TWO external treasury `.call{value:}` sites (one per `integrator == address(0)` branch) | Same reasoning class as the `reentrancy-benign`/`reentrancy-events` row below, bumped a severity notch by slither because the integrator split adds a second call site in the other branch (V1's single-branch `_settle` only ever trips the Low-severity variants). Every caller of `_settle` (`register`/`registerWithProof`/`registerWithIntegrator`/`registerWithProofAndIntegrator`) carries `nonReentrant` (transient) over the entire call, so a reentrant call from the treasury mid-push into any register overload or `withdraw()` reverts `ReentrancyGuardReentrantCall` before it can observe or act on this write — proven directly by `test/tld/TldRegistrarControllerV2.t.sol::test_reentrancy_blocked_on_register_via_malicious_treasury` (a malicious treasury mock attempts exactly this reentry and is rejected). |

## Low findings (accepted, reviewed per class)

| Detector | Count | Class verdict |
|---|---|---|
| `timestamp` | 14 | Commit-reveal ages, unlock/recovery timelocks (7-day floors) and the 91-day price ramp compare `block.timestamp` with `>=`/`<=` at 1-second granularity; Arc timestamps are proposer wall-clock at 1 s granularity (threat-model §0), never used as uniqueness/epoch source (SR-12 uses the `epoch` counter). |
| `reentrancy-benign` / `reentrancy-events` | 8 | Registration paths call the registry/oracle/resolver (ours) before the treasury push and events; `nonReentrant` (transient) guards `register`/`withdraw`, the registry has no callbacks (`_mint`, not `_safeMint`), and state is finalised before the only untrusted external interaction (the treasury Safe push, which must revert the tx on failure by design — onchain-design §6). |
| `calls-loop` | 7 | `registerReservedBatch` loops over ≤ 250 labels calling our own registry/resolver; `TldMetadata.tokenURI` iterates the directory's TLD rows (2–3). Bounded by calldata and by governance. |
| `missing-zero-check` | 2 | `ArcNSResolver` constructor `reverseRegistrar` and `TldRegistrar` `metadata` are wired by the deploy script and asserted post-deploy (`VerifyRoles`, integration test); a zero value would only make the corresponding view revert, not create a privilege. |
| `shadowing-local` | 2 | `IArcNSPriceOracle.tiers(namespaceId)` parameter name equals the mapping name in the implementation; cosmetic. |

## Informational (27)

`naming-convention` (interface-mandated camelCase immutables/constants), `low-level-calls` (the treasury pushes
and the pull-ledger `withdraw` — deliberate `call{value:}`), `assembly` (`HandleNormalize.seedBytes`,
`ExtendedResolverV` revert bubbling), `dead-code`, `too-many-digits` (tier constants in tests), one
`cyclomatic-complexity` (`HandleRegistry._update`, the deliberate single choke point).

## Other static checks

- No `delegatecall`, `selfdestruct` or proxy pattern in `src/` (SR-60): `grep -rn "delegatecall\|selfdestruct" src` → empty (CI grep in `contracts.yml`, devops lane).
- `whenNotPaused` appears only on `HandleController.register`, `TldRegistrarController.register`, and `ArcNSMarket.{list,placeOffer,startAuction,placeBid}` (SR-62/SR-35 M3: same "pause blocks only new activity" principle; `ci/static-checks.py`'s `SR62_ALLOWED` was extended to include `market/ArcNSMarket.sol`).
- Contract sizes (`forge build --sizes`, osaka, 24,576 B limit): `ArcNSResolver` 23,140 B runtime with `Ed25519` and `PrimaryNameLib` as linked public libraries; every other contract < 18 KB.
