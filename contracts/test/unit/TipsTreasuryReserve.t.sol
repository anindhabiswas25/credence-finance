// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {KeeperJob} from "../../src/libraries/Types.sol";
import {ICredenceErrors} from "../../src/libraries/Errors.sol";
import {KeeperTips} from "../../src/core/KeeperTips.sol";
import {Treasury} from "../../src/core/Treasury.sol";
import {ProtocolReserve} from "../../src/core/ProtocolReserve.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev A token whose transfer to `blocked` reverts (a blocklisted keeper).
contract BlockingToken is MockERC20 {
    address public blocked;

    constructor() MockERC20("USDC", "USDC", 6) {}

    function block_(address a) external {
        blocked = a;
    }

    function transfer(address to, uint256 v) public override returns (bool) {
        require(to != blocked, "blocked");
        return super.transfer(to, v);
    }
}

/// @dev Market stand-in for the reserve target.
contract BorrowsStub {
    uint256 internal b;
    bool public broken;

    function set(uint256 b_, bool br) external {
        b = b_;
        broken = br;
    }

    function totalBorrowsAll() external view returns (uint256) {
        require(!broken, "broken");
        return b;
    }
}

contract TipsTreasuryReserveTest is Test {
    address timelock = makeAddr("timelock");
    address payer = makeAddr("market");
    address keeper = makeAddr("keeper");
    BlockingToken usdc;
    KeeperTips tips;
    Treasury treasury;
    ProtocolReserve reserve;

    function setUp() public {
        usdc = new BlockingToken();
        tips = new KeeperTips(timelock, address(usdc));
        treasury = new Treasury(timelock, address(usdc), address(tips));
        reserve = new ProtocolReserve(timelock, address(usdc), address(treasury));
        address[] memory p = new address[](1);
        p[0] = payer;
        tips.initializeWiring(p);
    }

    // ───────────── KeeperTips ─────────────

    function test_tipsDefaultsAndPay() public {
        assertEq(tips.tipFor(KeeperJob.ENFORCE_BELL), 2e6);
        assertEq(tips.tipFor(KeeperJob.SETTLE), 1e6);
        assertEq(tips.tipFor(KeeperJob.EPOCH), 1e6);
        vm.prank(payer);
        assertEq(tips.pay(keeper, KeeperJob.FLAG), 0, "empty budget pays nothing, never reverts");
        usdc.mint(address(tips), 10e6);
        assertEq(tips.budget(), 10e6);
        vm.prank(payer);
        assertEq(tips.pay(keeper, KeeperJob.FLAG), 2e6);
        assertEq(usdc.balanceOf(keeper), 2e6);
        vm.prank(payer);
        assertEq(tips.pay(address(0), KeeperJob.FLAG), 0);
        vm.prank(payer);
        assertEq(tips.pay(keeper, 99), 0, "unknown job");
        usdc.block_(keeper);
        vm.prank(payer);
        assertEq(tips.pay(keeper, KeeperJob.FLAG), 0, "a reverting transfer is skipped");
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        tips.pay(keeper, KeeperJob.FLAG);
    }

    function test_tipsGovernance() public {
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        tips.setTip(KeeperJob.FLAG, 5e6);
        vm.startPrank(timelock);
        tips.setTip(KeeperJob.FLAG, 5e6);
        tips.setPayer(keeper, true);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        tips.setPayer(address(0), true);
        vm.stopPrank();
        assertEq(tips.tipFor(KeeperJob.FLAG), 5e6);
        assertTrue(tips.isPayer(keeper));
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        tips.setPayer(keeper, false);
        address[] memory p = new address[](0);
        vm.expectRevert(ICredenceErrors.AlreadyWired.selector);
        tips.initializeWiring(p);
        vm.prank(timelock);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        tips.initializeWiring(p);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new KeeperTips(address(0), address(usdc));
        assertEq(tips.token(), address(usdc));
    }

    // ───────────── Treasury ─────────────

    function test_treasury() public {
        usdc.mint(address(treasury), 100e6);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        treasury.fundTips(1);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        treasury.withdraw(address(usdc), keeper, 1);
        vm.startPrank(timelock);
        treasury.fundTips(30e6);
        treasury.withdraw(address(usdc), keeper, 20e6);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        treasury.withdraw(address(usdc), address(0), 1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(tips)), 30e6);
        assertEq(usdc.balanceOf(keeper), 20e6);
        assertEq(treasury.tips(), address(tips));
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new Treasury(timelock, address(0), address(tips));
    }

    // ───────────── ProtocolReserve ─────────────

    function test_reserveTargetOverflowAndCover() public {
        BorrowsStub m = new BorrowsStub();
        assertEq(reserve.targetSize(), 0, "no market yet");
        reserve.initializeWiring(address(m));
        m.set(1_000e6, false);
        assertEq(reserve.targetSize(), 50e6, "5% of borrows");
        vm.prank(timelock);
        reserve.setTargetSize(80e6);
        assertEq(reserve.targetSize(), 80e6, "the floor wins");
        usdc.mint(address(this), 100e6);
        usdc.approve(address(reserve), 100e6);
        reserve.fund(0);
        reserve.fund(100e6);
        assertEq(reserve.balance(), 80e6);
        assertEq(usdc.balanceOf(address(treasury)), 20e6, "above the target to the treasury");
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        reserve.cover(1);
        vm.prank(address(m));
        assertEq(reserve.cover(100e6), 80e6, "pays min(s, balance)");
        vm.prank(address(m));
        assertEq(reserve.cover(1), 0);
        vm.prank(timelock);
        reserve.setTargetBps(1000);
        assertEq(reserve.targetBps(), 1000);
        vm.prank(timelock);
        vm.expectRevert(ICredenceErrors.InvalidParam.selector);
        reserve.setTargetBps(10_001);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        reserve.setTargetBps(1);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        reserve.setTargetSize(1);
        m.set(0, true); // a failing market view: the floor still applies
        assertEq(reserve.targetSize(), 80e6);
    }

    function test_reserveWiring() public {
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        reserve.initializeWiring(address(0));
        vm.prank(timelock);
        vm.expectRevert(ICredenceErrors.Unauthorized.selector);
        reserve.initializeWiring(payer);
        reserve.initializeWiring(payer);
        vm.expectRevert(ICredenceErrors.AlreadyWired.selector);
        reserve.initializeWiring(payer);
        assertEq(reserve.market(), payer);
        assertEq(reserve.treasury(), address(treasury));
        assertEq(reserve.token(), address(usdc));
        assertEq(reserve.timelock(), timelock);
        vm.expectRevert(ICredenceErrors.ZeroAddress.selector);
        new ProtocolReserve(timelock, address(usdc), address(0));
    }
}
