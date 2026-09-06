# Invariant suite — targets

Source of truth: `docs/security/threat-model.md` §3 (INV-1…INV-10). This directory is wired into CI
by `forge test --match-path 'test/invariant/*'` (profile `ci`: 1000 runs × depth 128, see
`foundry.toml`). `Scaffold.invariant.t.sol` is the M0 placeholder that keeps the job green; each row
below names the WP that replaces it with a real handler-driven invariant.

| ID | Invariant | Contracts | Lands in |
|---|---|---|---|
| INV-1 | `∀ registered label: ownerOf(tokenId) == registryOwner(node)` (`.arc`), and there is exactly one owner source. | C4 BaseRegistrar, C3 ENSRegistry, C1 HandleRegistry | WP-110, WP-105 |
| INV-2 | `∀ record: resolve() returns it ⇔ record.epoch == name.epoch`. | C7 ArcNSResolver, C1 | WP-112 |
| INV-3 | Any `Transfer` event on a name increments `epoch` by exactly 1 and clears listing, offers-acceptance eligibility, recovery, and approvals. | C1 `_update`, C10 market | WP-105, WP-119 |
| INV-4 | `marketplace.balance == Σ live bids + Σ live offers + Σ withdrawable`. | C10 ArcNSMarket | WP-120, WP-123 |
| INV-5 | No `Sold`/`Settled` event while `locked \|\| recoveryPending`. | C10, C1 | WP-123, WP-125 |
| INV-6 | `endsAt` never decreases. | C10 auctions | WP-121 |
| INV-7 | Before `GenesisSealed`, every `Transfer(from=0)` has `to == treasury`; after, `GENESIS_ROLE` holder set is empty. | C2 HandleController, C5 TldRegistrarController | WP-139 |
| INV-8 | Deployer holds no role after the deploy bundle; `ADMIN` is only the timelock. | all `AccessControl` contracts, deploy scripts | WP-113 (fork dry-run assertion) |
| INV-9 | No commitment younger than `minCommitmentAge` or older than `maxCommitmentAge` can be revealed. | C2, C5 | WP-105, WP-111 |
| INV-10 | `HandleNormalize.isCanonical` (Solidity) ≡ `handle_normalize::is_canonical` (Rust) ≡ WASM on the fixture corpus. | `src/lib/HandleNormalize.sol` | **M0**: `test/unit/HandleCorpus.t.sol` + `sdk/test/fixtures.json` (WP-102/103); Rust↔Solidity CI conformance job in WP-505 |

Conventions for the real suites (WP-123 peer-review checklist):

- One handler contract per subject (`targetContract`), bounded actors (`targetSender`), `fail_on_revert = false` in the default profile; a run that only reverts is a broken handler — assert call-success counters in `invariant_*`.
- Ghost variables live in the handler; invariants read ghosts + on-chain state only.
- Every invariant test is named `invariant_INV<n>_<short>` so the CI log maps 1:1 onto the table above.
