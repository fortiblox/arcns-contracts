# Invariant suite — targets

Source of truth: `docs/security/threat-model.md` §3 (INV-1…INV-10). This directory is wired into CI
by `forge test --match-path 'test/invariant/*'` (profile `ci`: 1000 runs × depth 128, see
`foundry.toml`). Each row below names the suite that implements it.

| ID | Invariant | Contracts | Status (M1) |
|---|---|---|---|
| INV-1 | `∀ registered label: ownerOf(tokenId) == registryOwner(node)` (`.arc`), and there is exactly one owner source. | C4 TldRegistrar, C3 ENSRegistry | `Tld.invariant.t.sol` `invariant_INV1_registrar_owner_is_the_only_authority` — the verbatim ENS registrar lets a raw ERC-721 transfer leave the registry owner behind until `reclaim`; the handler tracks that as a ghost, so every divergence is explained by a pending `reclaim` and the resolver's authority is always `ownerOf` |
| INV-2 | `∀ record: resolve() returns it ⇔ record.epoch == name.epoch`. | C7 ArcNSResolver, C1 | `Resolver.invariant.t.sol` `invariant_INV2_records_readable_iff_written_under_current_version` |
| INV-3 | Any `Transfer` event on a name increments `epoch` by exactly 1 and clears listing, offers-acceptance eligibility, recovery, and approvals. | C1 `_update` | `HandleRegistry.invariant.t.sol` `invariant_INV3_epoch_increments_by_one_per_transfer`, `invariant_INV3_recovery_cleared_after_transfer` (listings/offers: market, M3) |
| INV-4 | `marketplace.balance == Σ live bids + Σ live offers + Σ withdrawable`. | C10 ArcNSMarket | M3 (WP-120/123) — no market contract in M1 |
| INV-5 | No `Sold`/`Settled` event while `locked \|\| recoveryPending`. | C10, C1 | M1 half: `invariant_INV5_locked_handles_never_move` (no `Transfer` while locked); market half M3 |
| INV-6 | `endsAt` never decreases. | C10 auctions | M3 (WP-121) |
| INV-7 | Before `GenesisSealed`, every `Transfer(from=0)` has `to == treasury`; after, `GENESIS_ROLE` holder set is empty. | C2 HandleController, C5 TldRegistrarController | `HandleController.invariant.t.sol` and `Tld.invariant.t.sol` `invariant_INV7_*` |
| INV-8 | Deployer holds no role after the deploy bundle; `ADMIN` is only the timelock. | all `AccessControl` contracts, deploy scripts | `test/integration/FullStack.t.sol` `test_INV8_handoff_leaves_deployer_without_roles`; `script/VerifyRoles.s.sol` prints `ROLES_VERIFIED` on the live chain |
| INV-9 | No commitment younger than `minCommitmentAge` or older than `maxCommitmentAge` can be revealed. | C2, C5 | `invariant_INV9_no_reveal_outside_commitment_window` in both controller suites |
| INV-10 | `HandleNormalize.isCanonical` (Solidity) ≡ `handle_normalize::is_canonical` (Rust) ≡ WASM on the fixture corpus. | `src/lib/HandleNormalize.sol` | M0: `test/unit/HandleCorpus.t.sol` + `sdk/test/fixtures.json`; `Scaffold.invariant.t.sol` keeps the local half |

Oracle extras (`Oracle.invariant.t.sol`): counters never decrease; quote always within 25–100 % of the ceiling. TLD extra: `.circle`-only handler calls never change `.arc` storage.

Conventions for the real suites (WP-123 peer-review checklist):

- One handler contract per subject (`targetContract`), bounded actors (`targetSender`), `fail_on_revert = false` in the default profile; a run that only reverts is a broken handler — assert call-success counters in `invariant_*`.
- Ghost variables live in the handler; invariants read ghosts + on-chain state only.
- Every invariant test is named `invariant_INV<n>_<short>` so the CI log maps 1:1 onto the table above.
