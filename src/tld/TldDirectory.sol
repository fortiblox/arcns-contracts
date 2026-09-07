// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {ITldDirectory} from "../interfaces/ITldDirectory.sol";
import {ArcNSConstants} from "../lib/ArcNSConstants.sol";

/// @title TldDirectory — C3a, the on-chain "TLDs are data" table (onchain-design §2 C3a, §3.5)
/// @notice One row per `tldNode = namehash(label)`. `DEFAULT_ADMIN_ROLE` (the timelock) writes
///         everything except `pause`, which `PAUSER_ROLE` (the Admin Safe, no delay) may also call
///         (SR-09 a, SR-62). Every transition is scoped to one row: `.arc` and `.circle` never read
///         or write each other's state.
///
///         Lifecycle: Unknown → Active (add) ⇄ RegistrationsPaused (pause / unpause) → Sunset
///         (sunset, extend-only `sunsetAt`) → Retired (retire, only once `sunsetAt` has passed).
contract TldDirectory is AccessControl, ITldDirectory {
    /// @notice May pause registrations of one TLD without a timelock delay.
    bytes32 public constant PAUSER_ROLE = ArcNSConstants.PAUSER_ROLE;

    /// @notice Thrown by `add` when `namespaceId != tldNode` (M1 invariant: the oracle namespace is the node).
    error NamespaceIdMismatch(bytes32 tldNode, bytes32 namespaceId);
    /// @notice Thrown when a controller address is already bound to another TLD row.
    error ControllerInUse(address controller, bytes32 tldNode);

    mapping(bytes32 tldNode => Tld) private _tlds;
    mapping(address controller => bytes32 tldNode) private _tldOfController;
    bytes32[] private _nodes;

    /// @param admin holder of `DEFAULT_ADMIN_ROLE` (the timelock).
    /// @param pauser holder of `PAUSER_ROLE` (the Admin Safe).
    constructor(address admin, address pauser) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ITldDirectory
    function get(bytes32 tldNode) external view returns (Tld memory) {
        return _tlds[tldNode];
    }

    /// @inheritdoc ITldDirectory
    function statusOf(bytes32 tldNode) public view returns (TldStatus) {
        return _tlds[tldNode].status;
    }

    /// @inheritdoc ITldDirectory
    function registrarOf(bytes32 tldNode) external view returns (address) {
        return _tlds[tldNode].registrar;
    }

    /// @inheritdoc ITldDirectory
    function controllerOf(bytes32 tldNode) external view returns (address) {
        return _tlds[tldNode].controller;
    }

    /// @inheritdoc ITldDirectory
    function isController(address who) external view returns (bool) {
        return _tldOfController[who] != bytes32(0);
    }

    /// @inheritdoc ITldDirectory
    function tldNodeOfController(address controller) external view returns (bytes32) {
        return _tldOfController[controller];
    }

    /// @inheritdoc ITldDirectory
    function registrationsOpen(bytes32 tldNode) external view returns (bool) {
        return _tlds[tldNode].status == TldStatus.Active;
    }

    /// @inheritdoc ITldDirectory
    function resolvable(bytes32 tldNode) external view returns (bool) {
        Tld storage t = _tlds[tldNode];
        if (t.status == TldStatus.Active || t.status == TldStatus.RegistrationsPaused) return true;
        return t.status == TldStatus.Sunset && block.timestamp < t.sunsetAt;
    }

    /// @inheritdoc ITldDirectory
    function tldNodes() external view returns (bytes32[] memory) {
        return _nodes;
    }

    /// @inheritdoc ITldDirectory
    function count() external view returns (uint256) {
        return _nodes.length;
    }

    // ---------------------------------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ITldDirectory
    function add(bytes32 tldNode, string calldata label, address registrar, address controller, bytes32 namespaceId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        Tld storage t = _tlds[tldNode];
        if (t.status != TldStatus.Unknown) revert TldExists(tldNode);
        if (registrar == address(0) || controller == address(0)) revert ZeroAddress();
        if (keccak256(abi.encodePacked(bytes32(0), keccak256(bytes(label)))) != tldNode) {
            revert LabelNodeMismatch(label, tldNode);
        }
        if (namespaceId != tldNode) revert NamespaceIdMismatch(tldNode, namespaceId);
        if (_tldOfController[controller] != bytes32(0)) {
            revert ControllerInUse(controller, _tldOfController[controller]);
        }

        t.registrar = registrar;
        t.controller = controller;
        t.namespaceId = namespaceId;
        t.status = TldStatus.Active;
        t.label = label;
        _tldOfController[controller] = tldNode;
        _nodes.push(tldNode);

        emit TldAdded(tldNode, label, registrar, controller, namespaceId);
        emit TldStatusChanged(tldNode, uint8(TldStatus.Active), 0, address(0), address(0));
    }

    /// @inheritdoc ITldDirectory
    function pause(bytes32 tldNode) external {
        if (!hasRole(PAUSER_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, PAUSER_ROLE);
        }
        Tld storage t = _requireKnown(tldNode);
        if (t.status != TldStatus.Active) {
            revert InvalidTransition(tldNode, uint8(t.status), uint8(TldStatus.RegistrationsPaused));
        }
        t.status = TldStatus.RegistrationsPaused;
        emit TldStatusChanged(tldNode, uint8(TldStatus.RegistrationsPaused), 0, address(0), address(0));
    }

    /// @inheritdoc ITldDirectory
    function unpause(bytes32 tldNode) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Tld storage t = _requireKnown(tldNode);
        if (t.status != TldStatus.RegistrationsPaused) {
            revert InvalidTransition(tldNode, uint8(t.status), uint8(TldStatus.Active));
        }
        t.status = TldStatus.Active;
        emit TldStatusChanged(tldNode, uint8(TldStatus.Active), 0, address(0), address(0));
    }

    /// @inheritdoc ITldDirectory
    /// @dev First sunset: from Active or RegistrationsPaused with `sunsetAt` in the future (a date
    ///      not after `now` is reported as `SunsetNotExtendOnly(now, sunsetAt)`). Already Sunset:
    ///      `sunsetAt` may only move later (SR-09 b). `migrationTarget` / `refundPool` are recorded
    ///      as given (zero is allowed in M1; M3 wires the holder hooks).
    function sunset(bytes32 tldNode, uint64 sunsetAt, address migrationTarget, address refundPool)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        Tld storage t = _requireKnown(tldNode);
        if (t.status == TldStatus.Active || t.status == TldStatus.RegistrationsPaused) {
            if (sunsetAt <= block.timestamp) revert SunsetNotExtendOnly(uint64(block.timestamp), sunsetAt);
        } else if (t.status == TldStatus.Sunset) {
            if (sunsetAt < t.sunsetAt) revert SunsetNotExtendOnly(t.sunsetAt, sunsetAt);
        } else {
            revert InvalidTransition(tldNode, uint8(t.status), uint8(TldStatus.Sunset));
        }
        t.status = TldStatus.Sunset;
        t.sunsetAt = sunsetAt;
        t.migrationTarget = migrationTarget;
        t.refundPool = refundPool;
        emit TldStatusChanged(tldNode, uint8(TldStatus.Sunset), sunsetAt, migrationTarget, refundPool);
    }

    /// @inheritdoc ITldDirectory
    function retire(bytes32 tldNode) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Tld storage t = _requireKnown(tldNode);
        if (t.status != TldStatus.Sunset) revert InvalidTransition(tldNode, uint8(t.status), uint8(TldStatus.Retired));
        if (block.timestamp < t.sunsetAt) revert SunsetNotReached(t.sunsetAt, uint64(block.timestamp));
        t.status = TldStatus.Retired;
        emit TldStatusChanged(tldNode, uint8(TldStatus.Retired), t.sunsetAt, t.migrationTarget, t.refundPool);
    }

    /// @inheritdoc ITldDirectory
    function setController(bytes32 tldNode, address controller) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Tld storage t = _requireKnown(tldNode);
        if (controller == address(0)) revert ZeroAddress();
        bytes32 bound = _tldOfController[controller];
        if (bound != bytes32(0) && bound != tldNode) revert ControllerInUse(controller, bound);
        address previous = t.controller;
        delete _tldOfController[previous];
        _tldOfController[controller] = tldNode;
        t.controller = controller;
        emit TldControllerChanged(tldNode, previous, controller);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _requireKnown(bytes32 tldNode) private view returns (Tld storage t) {
        t = _tlds[tldNode];
        if (t.status == TldStatus.Unknown) revert TldUnknown(tldNode);
    }
}
