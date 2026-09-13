// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ITldRegistrarControllerV3 — WP #7773, additive no-resolver-only registrar controller
/// @notice One instance per TLD (`.arc`, `.circle`), same byte-identical-bytecode-different-`Init`
///         convention as `TldRegistrarController`/`TldRegistrarControllerV2`. `registerDirect` is the
///         ONLY registration entry point: a single-tx `registrar.register(id, owner, duration)` mint
///         with no commit-reveal step and no ENS/resolver/reverse-record side effects (`resolver ==
///         address(0)` branch of V2's `_register`, and only that branch — see
///         `TldRegistrarControllerV3.sol`'s own NatSpec for the full architectural rationale).
///
///         This is a strictly smaller surface than `ITldRegistrarController`: no `Registration`
///         struct (its `secret`/`resolver`/`data`/`reverseRecord` fields do not apply to a
///         resolver-less mint), no `commit`/`commitments`/`makeCommitment`, no
///         `minCommitmentAge`/`maxCommitmentAge`, no `registerWithProof`-style escape hatch (an active
///         allowlist always blocks `registerDirect` — see the contract-level NatSpec). Genesis,
///         launch-allowlist configuration, pause and the pull-payment withdraw ledger are unchanged
///         from V1/V2.
interface ITldRegistrarControllerV3 {
    // ENS v1.7.0-shaped event, verbatim signature (BENS `handleNameRegisteredByUnwrappedController`),
    // kept for indexer parity even though this controller never sets an ENS resolver record itself.
    event NameRegistered(
        string label,
        bytes32 indexed labelhash,
        address indexed owner,
        uint256 baseCost,
        uint256 premium,
        uint256 expires,
        bytes32 referrer
    );
    event ReservedRegistered(bytes32 indexed labelhash, string label);
    event GenesisSealed(bytes32 indexed tldNode, bytes32 merkleRoot, uint256 reservedCount);
    event TreasuryFee(bytes32 indexed labelhash, uint256 amount);
    event Credited(address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    /// @notice WP-144-style launch allowlist (re)configured. `root == 0` ⇒ no allowlist; otherwise
    ///         `registerDirect` is unconditionally refused (`AllowlistRequired`) until `sunset`.
    event AllowlistSet(bytes32 indexed root, uint64 sunset);

    error NameNotAvailable(string label);
    error NotCanonical(string label);
    error PriceChanged(uint256 quoted, uint256 maxPrice);
    error InsufficientValue(uint256 required, uint256 sent);
    error RegistrationsClosed(); // genesis not sealed yet, or directory status != Active, or paused
    error GenesisAlreadySealed();
    error TreasuryPaymentFailed(address treasury, uint256 amount);
    error NothingToWithdraw();
    error WithdrawFailed(address to, uint256 amount);
    error ValueNotAccepted();
    /// @notice The allowlist window is open. There is no proof-taking sibling of `registerDirect` — an
    ///         active allowlist permanently blocks this entry point until cleared or sunset.
    error AllowlistRequired();
    error AllowlistSunsetInvalid(uint64 sunset);

    function tld() external view returns (string memory);
    function tldNode() external view returns (bytes32);
    function namespaceId() external view returns (bytes32);
    function treasury() external view returns (address);
    function genesisSealed() external view returns (bool);
    function genesisRoot() external view returns (bytes32);
    function reservedCount() external view returns (uint256);
    function withdrawable(address who) external view returns (uint256);
    function paidWei(bytes32 labelhash) external view returns (uint256);
    function labelOf(bytes32 labelhash) external view returns (string memory);

    // ---- launch allowlist (admin = timelock, SR-62)
    function MAX_ALLOWLIST_WINDOW() external view returns (uint256);
    function allowlistRoot() external view returns (bytes32);
    function allowlistSunset() external view returns (uint64);
    function allowlistActive() external view returns (bool);
    /// @notice Proof check only — ignores whether the allowlist is active. Kept for off-chain tooling
    ///         parity with V1/V2 even though no on-chain caller ever supplies a proof to this contract.
    function isAllowlisted(address owner, bytes32[] calldata proof) external view returns (bool);
    function setAllowlist(bytes32 root, uint64 sunset) external;

    function valid(string calldata label) external pure returns (bool);
    function available(string calldata label) external view returns (bool);
    function quote(string calldata label) external view returns (uint256 priceWei);

    /// @notice Single-tx, no-resolver registration: mints `label` to `owner` on the shared
    ///         `TldRegistrar` for at most `maxPrice`. Reverts `AllowlistRequired` while the launch
    ///         allowlist is active (no proof-taking overload exists on this controller).
    function registerDirect(string calldata label, address owner, uint256 maxPrice) external payable;
    function withdraw() external;

    // ---- genesis (GENESIS_ROLE; renounced inside sealGenesis)
    function registerReservedBatch(string[] calldata labels) external;
    function sealGenesis(bytes32 merkleRoot) external;
}
