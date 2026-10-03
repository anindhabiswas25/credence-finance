// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SeniorVault} from "../../src/core/SeniorVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RiskFixture} from "../utils/RiskFixture.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";

/// @title First-depositor and donation (inflation) attacks on the Senior Vault (§8.5: OZ virtual shares with a decimals
///        offset of 6 + 1e3 dead shares). QA-sec S4 item C; `profile.ci` runs 10,000 cases.
/// @notice The attacker makes the first deposit, donates straight to the vault, then a victim deposits. Properties:
///         (1) the attacker never profits; (2) the victim loses at most one share's worth plus one unit of rounding,
///         i.e. ≤ (a0 + donation) / 1e6 + 2 units: a $1M donation can skim at most ~$1 from a victim.
contract VaultInflationFuzz is Test {
    MockERC20 internal usdc;
    SeniorVault internal vault;
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        // no market is enabled: every deposit stays idle, which is where a donation lands
        vault = new SeniorVault(
            IERC20(address(usdc)), "v", "v", makeAddr("timelock"), makeAddr("market"), makeAddr("allocator")
        );
    }

    function _deposit(address who, uint256 a) internal returns (uint256 s) {
        usdc.mint(who, a);
        vm.startPrank(who);
        usdc.approve(address(vault), a);
        s = vault.deposit(a, who);
        vm.stopPrank();
    }

    function _redeemAll(address who) internal returns (uint256 got) {
        uint256 s = vault.balanceOf(who);
        if (s == 0) return 0;
        vm.prank(who);
        got = vault.redeem(s, who, who);
    }

    function testFuzz_firstDepositorDonation(uint256 a0, uint256 donation, uint256 v) public {
        a0 = bound(a0, 1, 1e12); // up to $1M
        donation = bound(donation, 0, 1e13); // up to $10M
        v = bound(v, 1, 1e13);
        _deposit(attacker, a0);
        assertEq(vault.balanceOf(address(0xdead)), 1e3, "dead shares");
        usdc.mint(address(vault), donation);
        uint256 vs = _deposit(victim, v);
        uint256 victimOut = _redeemAll(victim);
        uint256 attackerOut = _redeemAll(attacker);
        assertLe(attackerOut, a0 + donation, "the attacker never profits");
        assertLe(victimOut, v, "no one gets more than they put in");
        assertLe(v - victimOut, (a0 + donation) / 1e6 + 2, "victim loss bounded by one share");
        if (donation < v * 1e5) {
            assertGt(vs, 0, "a victim is never minted zero shares below a 1e5x donation");
        }
    }

    /// @dev The first deposit mints 1e3 dead shares out of the depositor's (1 unit mints 1e6).
    ///      Note (triage QA-L3): `deposit` *returns* a0 × 1e6, 1e3 more than the depositor received.
    function testFuzz_firstDepositMintsDeadShares(uint256 a0) public {
        a0 = bound(a0, 1, 1e15);
        _deposit(attacker, a0);
        assertEq(vault.balanceOf(attacker), a0 * 1e6 - 1e3);
        assertEq(vault.totalSupply(), a0 * 1e6);
    }

    /// @dev Round trips never create value (§7.2: shares minted down, assets paid out down).
    function testFuzz_roundTripNeverProfits(uint256 seed, uint256 a, uint256 donation) public {
        _deposit(makeAddr("seed"), bound(seed, 1, 1e13));
        usdc.mint(address(vault), bound(donation, 0, 1e13));
        a = bound(a, 1, 1e13);
        uint256 s = _deposit(victim, a);
        vm.prank(victim);
        uint256 back = vault.redeem(s, victim, victim);
        assertLe(back, a, "deposit then redeem");
        // mint (assets rounded up) then withdraw everything: never more than was paid
        uint256 want = bound(a, 1e6, 1e19);
        uint256 cost = vault.previewMint(want);
        usdc.mint(victim, cost);
        vm.startPrank(victim);
        usdc.approve(address(vault), cost);
        vault.mint(want, victim);
        uint256 maxOut = vault.maxWithdraw(victim);
        if (maxOut != 0) vault.withdraw(maxOut, victim, victim);
        vm.stopPrank();
        assertLe(maxOut, cost, "mint then withdraw returns at most what was paid");
    }
}

/// @title First-depositor and donation attacks on the Underwriter Pool (§8.6; shares = assets × (supply + S) /
///        (NAV + 1) with S = 10^(18 − loan decimals)). Paid out through the real withdrawal path (requestWithdraw →
///        settleEpoch → claimWithdraw).
/// @notice The pool has no dead shares (the guide's §15.1 control is "virtual plus dead shares"): these properties
///         show the 18-decimal shares over a 6-decimal asset keep the victim's rounding loss ≤ (a0 + donation) / 1e12
///         + 2 units, so the missing dead shares are not exploitable (triage QA-I1).
contract PoolInflationFuzz is RiskFixture {
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    function setUp() public {
        setUpRisk(); // Monday 09:00 ET, no underwriter yet, no epoch open
    }

    /// @dev claimWithdraw, or 0 when the holder's reserved assets round to nothing (it reverts NothingToClaim).
    function _claim(address who) internal returns (uint256) {
        vm.prank(who);
        try up.claimWithdraw(0) returns (uint256 x) {
            return x;
        } catch (bytes memory err) {
            assertEq(bytes4(err), ICredenceErrors.NothingToClaim.selector);
            return 0;
        }
    }

    function _mintsZero(uint256 v) internal view returns (bool) {
        return v * (up.totalSupply() + 1e12) < up.nav() + 1;
    }

    function _expectZeroMintReverts(uint256 v) internal {
        usdc.mint(victim, v);
        vm.startPrank(victim);
        usdc.approve(address(up), v);
        vm.expectRevert(ICredenceErrors.ZeroAmount.selector);
        up.deposit(v, victim);
        vm.stopPrank();
    }

    function _settleEpoch0AndClaim(address a, address b) internal returns (uint256 outA, uint256 outB) {
        vm.warp(_openAt(0, 1) + 10 minutes);
        up.settleEpoch(0);
        outA = _claim(a);
        outB = _claim(b);
    }

    function testFuzz_firstDepositorDonation(uint256 a0, uint256 donation, uint256 v) public {
        a0 = bound(a0, 1, 1e12);
        donation = bound(donation, 0, 1e13);
        v = bound(v, 1, 1e13);
        uint256 sa = _underwrite(attacker, a0);
        usdc.mint(address(up), donation);
        if (_mintsZero(v)) return _expectZeroMintReverts(v); // a dust deposit is refused, never minted 0 shares
        uint256 sv = _underwrite(victim, v);
        vm.prank(attacker);
        up.requestWithdraw(sa);
        vm.prank(victim);
        up.requestWithdraw(sv);
        (uint256 outA, uint256 outV) = _settleEpoch0AndClaim(attacker, victim);
        assertLe(outA, a0 + donation, "the attacker never profits");
        assertLe(outV, v, "no one gets more than they put in");
        assertLe(v - outV, (a0 + donation) / 1e12 + 2, "victim loss bounded by one share unit");
    }

    /// @dev Every underwriter left (supply 0) while the pool still holds value (e.g. income credited later): the next
    ///      depositor is minted at the virtual price and cannot lose to that orphaned NAV.
    function testFuzz_depositIntoEmptyPoolWithOrphanNav(uint256 orphan, uint256 v) public {
        orphan = bound(orphan, 1, 1e13);
        v = bound(v, 1, 1e13);
        usdc.mint(address(up), orphan);
        assertEq(up.totalSupply(), 0);
        if (_mintsZero(v)) return _expectZeroMintReverts(v);
        uint256 sv = _underwrite(victim, v);
        vm.prank(victim);
        up.requestWithdraw(sv);
        vm.warp(_openAt(0, 1) + 10 minutes);
        up.settleEpoch(0);
        uint256 out = _claim(victim);
        assertLe(out, v + orphan);
        assertLe(v - out, orphan / 1e12 + 2, "the depositor keeps its deposit, up to one share unit");
    }

    /// @dev Deposit → withdraw never creates value, whatever the prior NAV per share.
    function testFuzz_roundTripNeverProfits(uint256 seed, uint256 donation, uint256 v) public {
        _underwrite(uw1, bound(seed, 1, 1e13));
        usdc.mint(address(up), bound(donation, 0, 1e13));
        v = bound(v, 1, 1e13);
        if (_mintsZero(v)) return _expectZeroMintReverts(v);
        uint256 sv = _underwrite(victim, v);
        vm.prank(victim);
        up.requestWithdraw(sv);
        vm.warp(_openAt(0, 1) + 10 minutes);
        up.settleEpoch(0);
        assertLe(_claim(victim), v);
    }
}
