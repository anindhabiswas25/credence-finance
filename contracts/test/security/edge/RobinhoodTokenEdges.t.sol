// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClockFixture} from "../../utils/ClockFixture.sol";
import {FeedHealth, MarketKind} from "../../../src/libraries/Types.sol";
import {TokenProbe} from "../../../src/libraries/TokenProbe.sol";
import {CredenceStockToken} from "../../../src/testnet/CredenceStockToken.sol";
import {ComplianceRegistry} from "../../../src/testnet/ComplianceRegistry.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockRobinhoodStock, MockAccessControlsRegistry} from "../../mocks/MockRobinhoodStock.sol";

contract TokenProbeHarness {
    function blocked(address token, address who) external view returns (bool) {
        return TokenProbe.blocked(token, who);
    }
}

/// @title A real Robinhood Stock Token as collateral (matrix rows E-R-*, `docs/qa/edge-cases.md`; ADR-0120), against a
///        behavioural copy of the `Stock` implementation on Robinhood Chain testnet: no `frozen` / `canHold` /
///        `sharesPerToken`, a pause (the token's or its registry's) and a registry blocklist instead.
contract RobinhoodTokenEdgesTest is ClockFixture {
    bytes32 internal constant RHTSLA = keccak256("RHTSLA:XNAS");
    MockAccessControlsRegistry internal reg;
    MockRobinhoodStock internal rh;
    TokenProbeHarness internal probe;
    address internal alice = makeAddr("alice");
    address internal eve = makeAddr("eve");

    function setUp() public {
        setUpStack();
        reg = new MockAccessControlsRegistry();
        rh = new MockRobinhoodStock("Tesla", "TSLA", address(reg));
        probe = new TokenProbeHarness();
        vm.prank(timelock);
        oracle.setAssetConfig(
            RHTSLA, address(feedA), address(feedB), address(0), address(rh), MarketKind.EQUITY, 250_000e18
        );
        vm.warp(sessions[0].extOpen - 1);
        vm.prank(timelock);
        clock.listAsset(RHTSLA, XNYS, MarketKind.EQUITY);
    }

    function _frozen() internal view returns (bool) {
        FeedHealth memory h = oracle.feedHealth(RHTSLA);
        return h.issuerFrozen;
    }

    /// E-R-01: listing reads the ERC-8056 multiplier (the token has no `sharesPerToken`); the issuer probe reads
    ///         `paused()` (no `frozen()`): not frozen normally, frozen while the token or the whole registry is paused.
    function test_E_R01_listingAndIssuerPause() public {
        assertEq(oracle.sharesPerToken(RHTSLA), 1e18);
        assertFalse(_frozen(), "a live Stock Token is not frozen (before ADR-0120: HALTED forever)");
        rh.pause();
        assertTrue(_frozen(), "token pause");
        rh.unpause();
        reg.setPaused(true);
        assertTrue(_frozen(), "registry-wide pause");
        reg.setPaused(false);
        assertFalse(_frozen());
    }

    /// E-R-02: the holder check used by the auction house and the solver venue: the registry blocklist for a Stock
    ///         Token, `canHold` for ours, open for a plain ERC-20.
    function test_E_R02_holderCheckAcrossTokenKinds() public {
        assertFalse(probe.blocked(address(rh), alice));
        reg.setBlocked(eve, true);
        assertTrue(probe.blocked(address(rh), eve), "blocklisted bidder refused before it can win a lot");
        assertFalse(probe.blocked(address(new MockERC20("x", "x", 18)), eve), "open token");
        ComplianceRegistry cr = new ComplianceRegistry(address(this));
        CredenceStockToken ours = new CredenceStockToken("t", "t", issuer, address(cr));
        assertTrue(probe.blocked(address(ours), eve), "our compliance: not allowlisted");
        cr.setAllowed(eve, true);
        assertFalse(probe.blocked(address(ours), eve));
    }

    /// E-R-03: the Stock Token's own multiplier update (`updateMultiplier(m, at)`) drives the same sync as ours: a
    ///         dividend step is cached, a scheduled split is a due corporate action.
    function test_E_R03_stockTokenMultiplierUpdates() public {
        rh.updateMultiplier(1.01e18);
        oracle.syncMultiplier(RHTSLA);
        assertEq(oracle.sharesPerToken(RHTSLA), 1.01e18);
        rh.updateMultiplier(2.02e18, block.timestamp + 12 hours);
        (,,,, bool due) = oracle.multiplierState(RHTSLA);
        assertTrue(due, "a 2:1 split within MULTIPLIER_LEAD");
        assertTrue(oracle.syncMultiplier(RHTSLA), "still due: not cached before it takes effect");
        assertEq(oracle.sharesPerToken(RHTSLA), 1.01e18);
    }

    /// E-R-04: transfer rules the market inherits: a paused token blocks every collateral move (so the oracle halts
    ///         the asset, E-R-01), and a blocked holder can't move its tokens in or out; `adminBurn` can take the
    ///         market's own balance (an issuer trust assumption, ADR-0120).
    function test_E_R04_transferRules() public {
        rh.mint(alice, 10e18);
        vm.prank(alice);
        assertTrue(rh.transfer(address(this), 1e18));
        rh.pause();
        vm.prank(alice);
        vm.expectRevert(MockRobinhoodStock.IsPaused.selector);
        rh.transfer(address(this), 1e18);
        rh.unpause();
        reg.setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockRobinhoodStock.Blocked.selector, alice));
        rh.transfer(address(this), 1e18);
        rh.adminBurn(address(this), 1e18);
        assertEq(rh.balanceOf(address(this)), 0);
    }
}
