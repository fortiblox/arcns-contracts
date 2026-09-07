// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ITldDirectory — the on-chain "TLDs are data" table (onchain-design §2 C3a, §3.5 lifecycle)
/// @notice One row per TLD node. Written only by governance (DEFAULT_ADMIN_ROLE = timelock) except
///         `pause`, which PAUSER_ROLE (the Admin Safe, no delay) may call. Read by controllers
///         (registration gate), the resolver (Retired ⇒ empty), the market (M3) and the SDK.
interface ITldDirectory {
    enum TldStatus {
        Unknown, // row does not exist
        Active,
        RegistrationsPaused,
        Sunset,
        Retired
    }

    struct Tld {
        address registrar; // C4 (BaseRegistrarImplementation subclass), tokenId = labelhash
        address controller; // C5 TldRegistrarController for this TLD
        bytes32 namespaceId; // oracle namespace (== tldNode)
        TldStatus status;
        uint64 sunsetAt; // set with Sunset; extend-only
        address migrationTarget; // controller that accepts migrateIn (M3, WP-142)
        address refundPool; // per-TLD RefundPool (M3, WP-142)
        string label; // "arc", "circle"
    }

    event TldAdded(bytes32 indexed tldNode, string label, address registrar, address controller, bytes32 namespaceId);
    event TldStatusChanged(
        bytes32 indexed tldNode, uint8 status, uint64 sunsetAt, address migrationTarget, address refundPool
    );
    event TldControllerChanged(bytes32 indexed tldNode, address previousController, address newController);

    error TldExists(bytes32 tldNode);
    error TldUnknown(bytes32 tldNode);
    error InvalidTransition(bytes32 tldNode, uint8 from, uint8 to);
    error SunsetNotExtendOnly(uint64 current, uint64 proposed);
    error SunsetNotReached(uint64 sunsetAt, uint64 now_);
    error ZeroAddress();
    error LabelNodeMismatch(string label, bytes32 tldNode);

    function get(bytes32 tldNode) external view returns (Tld memory);
    function statusOf(bytes32 tldNode) external view returns (TldStatus);
    function registrarOf(bytes32 tldNode) external view returns (address);
    function controllerOf(bytes32 tldNode) external view returns (address);
    function isController(address who) external view returns (bool);
    function tldNodeOfController(address controller) external view returns (bytes32);
    /// @notice true iff `register` is allowed (status == Active).
    function registrationsOpen(bytes32 tldNode) external view returns (bool);
    /// @notice true iff names under this TLD still resolve: Active, RegistrationsPaused, or Sunset
    ///         before `sunsetAt`. Retired and Sunset-past-`sunsetAt` return false (SR-09 b).
    function resolvable(bytes32 tldNode) external view returns (bool);
    function tldNodes() external view returns (bytes32[] memory);
    function count() external view returns (uint256);

    function add(bytes32 tldNode, string calldata label, address registrar, address controller, bytes32 namespaceId)
        external;
    function pause(bytes32 tldNode) external; // PAUSER_ROLE or admin: Active -> RegistrationsPaused
    function unpause(bytes32 tldNode) external; // admin only: RegistrationsPaused -> Active
    function sunset(bytes32 tldNode, uint64 sunsetAt, address migrationTarget, address refundPool) external; // admin
    function retire(bytes32 tldNode) external; // admin, only after sunsetAt
    function setController(bytes32 tldNode, address controller) external; // admin (registrar swap)
}
