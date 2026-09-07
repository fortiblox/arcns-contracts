// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ITldDirectory} from "../../../src/interfaces/ITldDirectory.sol";

/// @dev ITldDirectory with plain setters (no timelock / transition rules): enough for the resolver's reads.
contract MockTldDirectory is ITldDirectory {
    mapping(bytes32 => Tld) internal _rows;
    mapping(address => bytes32) internal _controllerTld;
    bytes32[] internal _nodes;

    function get(bytes32 tldNode) external view returns (Tld memory) {
        return _rows[tldNode];
    }

    function statusOf(bytes32 tldNode) public view returns (TldStatus) {
        return _rows[tldNode].status;
    }

    function registrarOf(bytes32 tldNode) external view returns (address) {
        return _rows[tldNode].registrar;
    }

    function controllerOf(bytes32 tldNode) external view returns (address) {
        return _rows[tldNode].controller;
    }

    function isController(address who) external view returns (bool) {
        return _controllerTld[who] != bytes32(0);
    }

    function tldNodeOfController(address controller) external view returns (bytes32) {
        return _controllerTld[controller];
    }

    function registrationsOpen(bytes32 tldNode) external view returns (bool) {
        return _rows[tldNode].status == TldStatus.Active;
    }

    function resolvable(bytes32 tldNode) public view returns (bool) {
        Tld storage t = _rows[tldNode];
        if (t.status == TldStatus.Active || t.status == TldStatus.RegistrationsPaused) return true;
        if (t.status == TldStatus.Sunset) return block.timestamp < t.sunsetAt;
        return false;
    }

    function tldNodes() external view returns (bytes32[] memory) {
        return _nodes;
    }

    function count() external view returns (uint256) {
        return _nodes.length;
    }

    function add(bytes32 tldNode, string calldata label, address registrar, address controller, bytes32 namespaceId)
        external
    {
        if (_rows[tldNode].status != TldStatus.Unknown) revert TldExists(tldNode);
        _rows[tldNode] = Tld({
            registrar: registrar,
            controller: controller,
            namespaceId: namespaceId,
            status: TldStatus.Active,
            sunsetAt: 0,
            migrationTarget: address(0),
            refundPool: address(0),
            label: label
        });
        _controllerTld[controller] = tldNode;
        _nodes.push(tldNode);
        emit TldAdded(tldNode, label, registrar, controller, namespaceId);
    }

    function pause(bytes32 tldNode) external {
        _rows[tldNode].status = TldStatus.RegistrationsPaused;
    }

    function unpause(bytes32 tldNode) external {
        _rows[tldNode].status = TldStatus.Active;
    }

    function sunset(bytes32 tldNode, uint64 sunsetAt, address migrationTarget, address refundPool) external {
        Tld storage t = _rows[tldNode];
        t.status = TldStatus.Sunset;
        t.sunsetAt = sunsetAt;
        t.migrationTarget = migrationTarget;
        t.refundPool = refundPool;
        emit TldStatusChanged(tldNode, uint8(TldStatus.Sunset), sunsetAt, migrationTarget, refundPool);
    }

    function retire(bytes32 tldNode) external {
        _rows[tldNode].status = TldStatus.Retired;
        emit TldStatusChanged(tldNode, uint8(TldStatus.Retired), _rows[tldNode].sunsetAt, address(0), address(0));
    }

    function setController(bytes32 tldNode, address controller) external {
        address previous = _rows[tldNode].controller;
        delete _controllerTld[previous];
        _rows[tldNode].controller = controller;
        _controllerTld[controller] = tldNode;
        emit TldControllerChanged(tldNode, previous, controller);
    }
}
