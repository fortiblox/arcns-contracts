# arcns-contracts

The on-chain contracts behind [ArcNS](https://arcns.io) — `@handle`, `.arc`
and `.circle` name resolution on [Arc](https://docs.arc.io), Circle's
stablecoin L1.

**This is a public, read-only mirror.** Development happens on a private,
self-hosted Forgejo instance; this repository is synced from `contracts/`
in that monorepo on every push to `main`, so anyone can read and audit the
exact source deployed on-chain, without needing access to the rest of the
stack (the app, API, indexer, or any other infrastructure — none of which
lives here). Issues and PRs opened here aren't monitored; see
[docs.arcns.io](https://docs.arcns.io) for how to reach the team.

ArcNS is built and operated by FortiBlox Labs, an independent team. It is
not built, run, or endorsed by Circle or the Arc Foundation.

## What's here

- `src/` — the contracts themselves: `HandleRegistry` (the `@handle`
  namespace, soulbound ERC-721 until tokenized), `TldRegistrar`/
  `TldDirectory` (`.arc`/`.circle`, a verbatim ENS-compatible registrar),
  registration controllers (commit-reveal and a newer single-transaction
  path), `ArcNSResolver`, `ArcNSMarket` (listings/offers/auctions), and
  supporting parity modules (gifting, locks, attestations).
- `test/` — the Foundry test suite (unit, fuzz, invariant).
- `script/` — deploy and governance-grant scripts, each documenting exactly
  what it does and does not touch (most contract role/permission changes on
  ArcNS go through a timelocked multisig, never a bare EOA).
- `abi/` — curated ABI exports, verified against source on every CI run
  (a mismatch fails the build).
- `deployments/` — the address book for every chain ArcNS is deployed to,
  plus the bytecode hash of every deployed contract, so you can confirm what
  you read here is what's actually live.
- `SECURITY-NOTES.md` — static-analysis (Slither) findings, triaged with a
  stated reason for every one that isn't a fix.

## Verifying a deployment

`deployments/<chainId>.json` records the bytecode hash of every contract
the deploy pipeline is willing to publish an address for — the build
refuses to write an address whose on-chain bytecode doesn't match. Compare
`keccak256` of a deployed contract's code against that file, or just read
the source and the Foundry config (`foundry.toml`: exact compiler version,
optimizer settings, EVM target) and reproduce the build yourself.

## Status

Arc **testnet** only (chain id `5042002`) as of this writing. Nothing
deployed here has monetary value; testnet state may be reset. A mainnet
deployment is a separate, deliberate milestone — see
[docs.arcns.io](https://docs.arcns.io) for current status.

## License

MIT — see [LICENSE](LICENSE).
