# SECURITY-NOTES — static-analysis triage (WP-117)

Gate: `contracts/ci/slither.sh` runs slither **0.11.3** over `src/` only (`slither.config.json`: `filter_paths`
= `lib/|test/|script/`, `fail_on: medium`, optimisation detectors off) and prints `SLITHER_CLEAN` /
`SLITHER_FAILED`. The verbatim libraries carry their upstream audits and are excluded. Every High/Medium
finding must be fixed in code or triaged here with a call-path reason and an inline
`// slither-disable-next-line <detector>` directly above the flagged statement (same discipline as the OSV
allowlist). Run 2026-09-07 on the M1 tree: **0 High, 0 Medium**, 33 Low, 27 Informational.

## Medium findings fixed in code

| Detector | Where | Resolution |
|---|---|---|
| `uninitialized-local` (5) | `HandleRegistry._update.reason`, `HandleController.registerReservedBatch.minted`, `TldRegistrarController.registerReservedBatch.minted`, `PrimaryNameLib.parse.node`, `ExtendedResolverV._decodeName.offset` | explicit initialisers (`= REASON_MINT`, `= 0`, `= bytes32(0)`); behaviour unchanged |

## Medium findings triaged inline (false positives with a stated reason)

| Detector | Where | Why it is not a defect |
|---|---|---|
| `incorrect-equality` (2) | `HandleController._consumeCommitment`, `TldRegistrarController._consumeCommitment`: `commitmentTimestamp == 0` | `0` is the "never committed" sentinel written by `delete commitments[c]`; it is compared against a stored value, never a computed one. Verbatim ENS `ETHRegistrarController` v1.7.0 logic. |
| `unused-return` (2) | `TldRegistrarController._registerWithResolver`: `multicallWithNodeCheck` (returns `bytes[]`), `setNameForAddr` (returns the reverse node) | The return payloads carry no decision-relevant data for the controller (node check reverts on mismatch; the reverse node is derivable from `msg.sender`). ENS v1.7.0 discards both as well. |

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
- `whenNotPaused` appears only on `HandleController.register` and `TldRegistrarController.register` (SR-62).
- Contract sizes (`forge build --sizes`, osaka, 24,576 B limit): `ArcNSResolver` 23,140 B runtime with `Ed25519` and `PrimaryNameLib` as linked public libraries; every other contract < 18 KB.
