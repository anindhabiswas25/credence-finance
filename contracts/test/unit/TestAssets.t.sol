// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {ICollateralTokenEvents, INavFundEvents, IFaucetEvents} from "../../src/libraries/Events.sol";
import {ComplianceRegistry} from "../../src/testnet/ComplianceRegistry.sol";
import {CredenceStockToken} from "../../src/testnet/CredenceStockToken.sol";
import {CredenceTreasuryFund} from "../../src/testnet/CredenceTreasuryFund.sol";
import {Faucet} from "../../src/testnet/Faucet.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract TestAssetsTest is Test, ICollateralTokenEvents, INavFundEvents, IFaucetEvents {
    address issuer = makeAddr("issuer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address reserve = makeAddr("reserve");
    ComplianceRegistry reg;
    CredenceStockToken stock;
    CredenceTreasuryFund fund;
    MockERC20 usdc;
    Faucet faucet;

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new ComplianceRegistry(issuer);
        stock = new CredenceStockToken("Credence Test NVIDIA", "tNVDA", issuer, address(0));
        usdc = new MockERC20("USDC", "USDC", 6);
        fund = new CredenceTreasuryFund(
            "Credence Test T-Bill", "tTBILL", issuer, address(reg), address(usdc), reserve, 1e18
        );
        faucet = new Faucet(address(this));
    }

    // ───────────── ComplianceRegistry ─────────────

    function test_registry() public {
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new ComplianceRegistry(address(0));
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        reg.setAllowed(alice, true);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        reg.setOperator(bob, true);
        vm.startPrank(issuer);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        reg.setOperator(address(0), true);
        reg.setOperator(bob, true);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        reg.transferOwnership(address(0));
        vm.stopPrank();
        vm.startPrank(bob);
        reg.setAllowed(alice, true);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        reg.setAllowed(address(0), true);
        address[] memory batch = new address[](2);
        batch[0] = bob;
        batch[1] = reserve;
        reg.setAllowedBatch(batch, true);
        vm.stopPrank();
        assertTrue(reg.isAllowed(alice) && reg.isAllowed(bob) && reg.canHold(reserve));
        assertTrue(reg.canTransfer(alice, bob));
        assertTrue(reg.canTransfer(address(0), alice)); // mint
        assertTrue(reg.canTransfer(alice, address(0))); // burn
        assertFalse(reg.canTransfer(alice, makeAddr("stranger")));
        vm.prank(issuer);
        reg.transferOwnership(alice);
        assertEq(reg.owner(), alice);
        assertTrue(reg.isOperator(bob));
    }

    // ───────────── CredenceStockToken ─────────────

    function test_stockIssuerAndMinter() public {
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new CredenceStockToken("x", "x", address(0), address(0));
        assertEq(stock.issuer(), issuer);
        assertEq(stock.decimals(), 18);
        assertEq(stock.sharesPerToken(), 1e18);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        stock.mint(alice, 1);
        vm.prank(issuer);
        stock.mint(alice, 100e18);
        vm.prank(issuer);
        stock.setMinter(address(faucet), 60e18);
        vm.startPrank(address(faucet));
        stock.mint(bob, 50e18);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        stock.mint(bob, 11e18); // over the cap
        vm.stopPrank();
        assertEq(stock.minterMinted(address(faucet)), 50e18);
        vm.startPrank(issuer);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        stock.setMinter(address(0), 1);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        stock.transferIssuer(address(0));
        stock.transferIssuer(bob);
        vm.stopPrank();
        assertEq(stock.issuer(), bob);
        vm.prank(issuer);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        stock.setFrozen(true);
    }

    function test_stockRatioFreezeCompliance() public {
        vm.startPrank(issuer);
        stock.mint(alice, 10e18);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        stock.setSharesPerToken(0);
        vm.expectEmit(false, false, false, true);
        emit RatioChanged(1e18, 2e18);
        stock.setSharesPerToken(2e18);
        stock.setFrozen(true);
        vm.stopPrank();
        assertEq(stock.sharesPerToken(), 2e18);
        vm.prank(alice);
        vm.expectRevert(ICredenceErrors.TokenFrozen.selector);
        stock.transfer(bob, 1);
        vm.prank(issuer);
        stock.setFrozen(false);
        assertTrue(stock.canHold(bob), "open token");
        vm.prank(issuer);
        stock.setCompliance(address(reg));
        assertFalse(stock.canHold(bob));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TransferNotAllowed.selector, alice, bob));
        stock.transfer(bob, 1);
        vm.startPrank(issuer);
        reg.setAllowed(alice, true);
        reg.setAllowed(bob, true);
        vm.stopPrank();
        vm.prank(alice);
        stock.transfer(bob, 1);
        assertEq(stock.balanceOf(bob), 1);
        assertEq(stock.compliance(), address(reg));
    }

    // ───────────── CredenceTreasuryFund ─────────────

    function _fundSetup() internal {
        vm.startPrank(issuer);
        reg.setAllowed(alice, true);
        reg.setAllowed(bob, true);
        fund.mint(alice, 1000e18);
        vm.stopPrank();
        usdc.mint(reserve, 10_000_000e6);
        vm.prank(reserve);
        usdc.approve(address(fund), type(uint256).max);
    }

    function test_fundConstructorAndViews() public {
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new CredenceTreasuryFund("x", "x", issuer, address(0), address(usdc), reserve, 1e18);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        new CredenceTreasuryFund("x", "x", issuer, address(reg), address(usdc), reserve, 0);
        (uint256 nav, uint40 at) = fund.navPerShare();
        assertEq(nav, 1e18);
        assertEq(at, 1_800_000_000);
        assertEq(fund.sharesPerToken(), 1e18);
        assertEq(fund.asset(), address(usdc));
        assertEq(fund.issuer(), issuer);
        assertEq(fund.decimals(), 18);
        vm.prank(issuer);
        fund.publishNav(1.0001e18);
        (nav,) = fund.navPerShare();
        assertEq(nav, 1.0001e18);
        vm.prank(issuer);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        fund.publishNav(0);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        fund.publishNav(1e18);
    }

    function test_fundAllowlist() public {
        _fundSetup();
        address stranger = makeAddr("stranger");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.TransferNotAllowed.selector, alice, stranger));
        fund.transfer(stranger, 1);
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.TransferNotAllowed.selector, address(0), stranger)
        );
        fund.mint(stranger, 1);
        vm.prank(alice);
        fund.transfer(bob, 1e18);
        vm.prank(issuer);
        fund.setFrozen(true);
        vm.prank(alice);
        vm.expectRevert(ICredenceErrors.TokenFrozen.selector);
        fund.transfer(bob, 1);
        assertFalse(fund.canHold(stranger));
    }

    function test_fundRedemptionFlow() public {
        _fundSetup();
        vm.prank(issuer);
        fund.publishNav(1.02e18);
        vm.expectEmit(true, true, true, true);
        emit RedeemRequest(bob, alice, 1, alice, 100e18);
        vm.prank(alice);
        uint256 id = fund.requestRedeem(100e18, bob, alice);
        assertEq(id, 1);
        assertEq(fund.balanceOf(address(fund)), 100e18, "shares escrowed");
        assertEq(fund.pendingRedeemRequest(id, bob), 100e18);
        assertEq(fund.pendingRedeemRequest(id, alice), 0);
        assertEq(fund.claimableRedeemRequest(id, bob), 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.RequestNotClaimable.selector, id));
        fund.redeem(id, bob, bob);

        vm.prank(issuer);
        uint256 assets = fund.fulfillRedeem(id);
        assertEq(assets, 102e6, "100 shares at NAV 1.02 = 102 USDC");
        assertEq(fund.totalSupply(), 900e18, "escrow burned");
        assertEq(fund.claimableRedeemRequest(id, bob), 100e18);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.RequestNotFound.selector, id));
        fund.fulfillRedeem(id);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NotRequestOwner.selector, id));
        fund.redeem(id, alice, bob);
        vm.prank(bob);
        assertEq(fund.redeem(id, bob, bob), 102e6);
        assertEq(usdc.balanceOf(bob), 102e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.RequestNotClaimable.selector, id));
        fund.redeem(id, bob, bob);
    }

    function test_fundRequestRules() public {
        _fundSetup();
        vm.startPrank(alice);
        vm.expectRevert(ICredenceErrors.ZeroAmount.selector);
        fund.requestRedeem(0, alice, alice);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        fund.requestRedeem(1, address(0), alice);
        fund.approve(bob, 5e18);
        vm.stopPrank();
        vm.prank(bob); // an approved operator may request for the owner
        fund.requestRedeem(5e18, bob, alice);
        vm.prank(bob);
        vm.expectRevert(); // allowance spent
        fund.requestRedeem(1, bob, alice);

        vm.prank(issuer);
        fund.setRedemptionsGated(true);
        assertTrue(fund.redemptionsGated());
        vm.prank(alice);
        vm.expectRevert(ICredenceErrors.RedemptionsGated.selector);
        fund.requestRedeem(1e18, alice, alice);
        vm.prank(issuer);
        vm.expectRevert(ICredenceErrors.RedemptionsGated.selector);
        fund.fulfillRedeem(1);

        vm.prank(issuer);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        fund.setReserveWallet(address(0));
        vm.prank(issuer);
        fund.setReserveWallet(bob);
        assertEq(fund.reserveWallet(), bob);
    }

    // ───────────── Faucet ─────────────

    function test_faucet() public {
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new Faucet(address(0));
        vm.prank(issuer);
        stock.setMinter(address(faucet), type(uint128).max);
        vm.prank(alice);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        faucet.configure(address(stock), 50e18, false);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        faucet.configure(address(0), 50e18, false);
        vm.expectRevert(
            abi.encodeWithSelector(ICredenceErrors.FaucetTokenNotConfigured.selector, address(stock))
        );
        faucet.drip(address(stock));
        faucet.configure(address(stock), 50e18, false);
        assertEq(faucet.dripAmount(address(stock)), 50e18);

        vm.expectEmit(true, true, false, true);
        emit Dripped(alice, address(stock), 50e18);
        vm.prank(alice);
        faucet.drip(address(stock));
        assertEq(stock.balanceOf(alice), 50e18);
        uint40 next = faucet.nextDripAt(alice, address(stock));
        assertEq(next, 1_800_000_000 + 24 hours);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.FaucetCooldown.selector, alice, next));
        faucet.drip(address(stock));
        vm.warp(next);
        vm.prank(alice);
        faucet.drip(address(stock));
        assertEq(stock.balanceOf(alice), 100e18);
        assertEq(faucet.nextDripAt(bob, address(stock)), 0);

        vm.prank(alice);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        faucet.transferOwnership(alice);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        faucet.transferOwnership(address(0));
        faucet.transferOwnership(bob);
        assertEq(faucet.owner(), bob);
    }

    function test_faucetAllowlistedFund() public {
        vm.prank(issuer);
        fund.setMinter(address(faucet), type(uint128).max);
        faucet.configure(address(fund), 100_000e18, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICredenceErrors.NotAllowlisted.selector, alice));
        faucet.drip(address(fund));
        vm.prank(issuer);
        reg.setAllowed(alice, true);
        vm.prank(alice);
        faucet.drip(address(fund));
        assertEq(fund.balanceOf(alice), 100_000e18);
    }

    /// @dev 24-hour limit per (address, token): a second drip inside the window always reverts.
    function testFuzz_faucetCooldown(uint32 wait) public {
        vm.prank(issuer);
        stock.setMinter(address(faucet), type(uint128).max);
        faucet.configure(address(stock), 1e18, false);
        vm.prank(alice);
        faucet.drip(address(stock));
        vm.warp(1_800_000_000 + uint256(wait));
        vm.prank(alice);
        if (wait < 24 hours) vm.expectRevert();
        faucet.drip(address(stock));
    }
}
