// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {FeedHealth} from "../../src/libraries/Types.sol";

/// @dev The OracleAdapter functions the AssetClock calls, with settable answers and failure switches.
contract MockOracle {
    FeedHealth internal h;
    uint256 public closeP;
    uint40 public closeT;
    uint256 public haltP;
    uint40 public haltT;
    bool public openOk;
    uint256 public openP;
    bool public openFallback;
    uint256 public lastSpt;
    bool public revertHealth;
    bool public revertClose;
    bool public revertHalt;
    bool public revertOpen;
    uint256 public openCalls;
    uint256 public burnGas; // feedHealth burns this much gas first (gas-griefing tests, ADR-0109)

    function setHealth(FeedHealth memory x) external {
        h = x;
    }

    function setClose(uint256 p, uint40 t) external {
        closeP = p;
        closeT = t;
    }

    function setHalt(uint256 p, uint40 t) external {
        haltP = p;
        haltT = t;
    }

    function setOpen(bool ok, uint256 p, bool fb) external {
        openOk = ok;
        openP = p;
        openFallback = fb;
    }

    function setReverts(bool health, bool close, bool halt, bool open) external {
        revertHealth = health;
        revertClose = close;
        revertHalt = halt;
        revertOpen = open;
    }

    function setBurn(uint256 g) external {
        burnGas = g;
    }

    function feedHealth(bytes32) external view returns (FeedHealth memory) {
        require(!revertHealth, "health");
        uint256 g0 = gasleft();
        while (burnGas != 0 && g0 - gasleft() < burnGas) {}
        return h;
    }

    function lastRegularClose(bytes32) external view returns (uint256, uint40) {
        require(!revertClose, "close");
        return (closeP, closeT);
    }

    function haltReferencePrice(bytes32) external view returns (uint256, uint40) {
        require(!revertHalt, "halt");
        return (haltP, haltT);
    }

    function openPrint(bytes32, uint40, uint40) external view returns (bool, uint256, bool) {
        require(!revertOpen, "open");
        return (openOk, openP, openFallback);
    }

    function setSharesPerToken(bytes32, uint256 v) external {
        require(v != 7, "cap"); // lets a test simulate the adapter rejecting a ratio
        lastSpt = v;
    }
}
