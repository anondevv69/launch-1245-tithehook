// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TitheToken} from "../src/TitheToken.sol";

contract TitheTokenTest is Test {
    TitheToken internal token;

    function setUp() public {
        token = new TitheToken();
    }

    function test_initialSupplyAndMetadata() public view {
        assertEq(token.name(), "Tithe Demo");
        assertEq(token.symbol(), "TDEMO");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferAndAllowance(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        address holder = makeAddr("holder");
        address recipient = makeAddr("recipient");
        token.transfer(holder, amount);
        assertEq(token.balanceOf(holder), amount);
        vm.prank(holder);
        token.approve(address(this), amount);
        token.transferFrom(holder, recipient, amount);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.allowance(holder, address(this)), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_failuresDoNotChangeSupply() public {
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.prank(makeAddr("empty"));
        vm.expectRevert();
        token.transfer(address(this), 1);
        vm.expectRevert();
        token.transferFrom(makeAddr("other"), address(this), 1);
        (bool success,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(success);
        (success,) = address(token).call(abi.encodeWithSignature("transferOwnership(address)", address(this)));
        assertFalse(success);
        assertEq(token.totalSupply(), 1e27);
    }
}
