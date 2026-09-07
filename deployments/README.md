# deployments/ — address books (data, not code)

`<chainId>.json` is written by `script/DeployAll.s.sol` at the end of a broadcast and is the single source of
truth for every consumer (SDK chain definition, indexer, API, docs site, `tools/*`). Fields: chain id, deploy
block/timestamp, deployer, Admin Safe, treasury, timelock (+ delay), oracle `launchTs`, commit-reveal ages,
compiler pins, `contracts{name: address}`, `bytecodeHashes{name: keccak256(runtime code)}`, the TLD table
(`label, node, namespaceId, registrar, controller, status`) and the path of the forge broadcast log holding
every creation tx hash. `5042002.json` = Arc testnet (WP-115, produced by the CEO's live run of the script);
`5042.json` = Arc mainnet (M4). `*.dry-run.json` files (fork rehearsals with `ARCNS_DRY_RUN=1`) are ignored.

Verification after any deploy: `forge script script/VerifyRoles.s.sol --rpc-url $ARC_RPC_URL` prints
`ROLES_VERIFIED`; `npm --prefix tools run verify-pricing` prints one `MATCH` per namespace;
`deploy/BUILD.md` explains how to compare `bytecodeHashes` with a local build.
